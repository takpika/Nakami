import Foundation
import CoreGraphics
import Compression

/// Apple's signed archives (.xip), e.g. the Xcode download: a xar holding "Metadata" and a pbzx-compressed cpio "Content".
enum XIP {
    static func isXIP(_ xar: Xar) -> Bool {
        xar.file("Content") != nil && xar.file("Metadata") != nil && !xar.files.contains { ($0.path as NSString).lastPathComponent == "PackageInfo" }
    }

    /// Walks the pbzx chunks of `Content` and hands each decoded piece to `body` until it returns false.
    /// Returns (bytes of compressed input consumed, reached the end).
    static func decode(_ r: Reader, at start: Int, length: Int, body: (UnsafeRawBufferPointer) -> Bool) -> (consumed: Int, finished: Bool) {
        guard r.ok(start, 12), r.be32(start) == 0x7062_7a78 else { return (0, false) }
        var o = start + 12
        let end = start + length
        var out = [UInt8](repeating: 0, count: 0)
        while o + 16 <= end {
            let usize = Int(clamping: r.be64(o)), clen = Int(clamping: r.be64(o + 8))
            o += 16
            guard usize > 0, usize <= 256 << 20, clen > 0, r.ok(o, clen) else { return (o - start, false) }
            var keepGoing = true
            r.data.withUnsafeBytes { src in
                let p = src.bindMemory(to: UInt8.self).baseAddress! + o
                if clen >= 6, p[0] == 0xfd, p[1] == 0x37, p[2] == 0x7a, p[3] == 0x58, p[4] == 0x5a {   // xz
                    if out.count < usize { out = [UInt8](repeating: 0, count: usize) }
                    let n = out.withUnsafeMutableBufferPointer { compression_decode_buffer($0.baseAddress!, usize, p, clen, nil, COMPRESSION_LZMA) }
                    if n == 0 { keepGoing = false; return }
                    out.withUnsafeBytes { keepGoing = body(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } else {   // stored
                    keepGoing = body(UnsafeRawBufferPointer(start: p, count: clen))
                }
            }
            o += clen
            if !keepGoing { return (o - start, false) }
        }
        return (o - start, true)
    }

    struct Scan {
        var entries = 0
        var files = 0
        var bytes = 0
        var first: [[String]] = []
        var top: [String] = []
        var captured: [String: Data] = [:]
        var finished = false
        var consumed = 0
    }

    /// Streams the cpio inside `Content`: names and sizes only, keeping just the few small files we want to read.
    static func scan(_ xar: Xar, content: Xar.File, budget: TimeInterval, wanted: (String) -> Bool, enough: ([String: Data]) -> Bool = { _ in false }) -> Scan {
        var s = Scan()
        let deadline = Date().addingTimeInterval(budget)
        var buf = [UInt8]()
        var pos = 0
        var skip = 0
        var capture: String?
        var done = false
        func oct(_ a: ArraySlice<UInt8>) -> Int { Int(String(decoding: a, as: Unicode.ASCII.self), radix: 8) ?? 0 }
        let r = decode(xar.r, at: xar.heap + content.offset, length: content.length) { chunk in
            if pos > 0 { buf.removeFirst(pos); pos = 0 }
            buf.append(contentsOf: chunk)
            while true {
                if skip > 0 {
                    let n = Swift.min(skip, buf.count - pos)
                    if let c = capture { s.captured[c, default: Data()].append(contentsOf: buf[pos..<(pos + n)]) }
                    pos += n
                    skip -= n
                    if skip > 0 { break }
                    if capture != nil, enough(s.captured) { done = true; return false }
                    capture = nil
                }
                guard buf.count - pos >= 76 else { break }
                guard buf[pos..<(pos + 6)].elementsEqual("070707".utf8) else { done = true; return false }
                let mode = oct(buf[(pos + 18)..<(pos + 24)])
                let nsize = oct(buf[(pos + 59)..<(pos + 65)]), fsize = oct(buf[(pos + 65)..<(pos + 76)])
                guard buf.count - pos >= 76 + nsize else { break }
                var name = String(decoding: buf[(pos + 76)..<(pos + 76 + Swift.max(0, nsize - 1))], as: UTF8.self)
                pos += 76 + nsize
                if name == "TRAILER!!!" { done = true; s.finished = true; return false }
                if name.hasPrefix("./") { name.removeFirst(2) }
                if !name.isEmpty, name != "." {
                    s.entries += 1
                    let isDir = mode & 0o170000 == 0o040000
                    if !isDir { s.files += 1; s.bytes += fsize }
                    if !name.contains("/"), !s.top.contains(name) { s.top.append(name) }
                    if s.first.count < 400 { s.first.append([name + (isDir ? "/" : ""), isDir ? "" : byteSize(fsize)]) }
                    if !isDir, fsize < 8 << 20, wanted(name) { capture = name; s.captured[name] = Data() }
                }
                skip = fsize
            }
            return Date() < deadline
        }
        s.consumed = r.consumed
        if r.finished && !done { s.finished = true }
        return s
    }

    static func report(url: URL, xar: Xar, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .xip, path: url.path, title: url.lastPathComponent)
        let meta = xar.file("Metadata").flatMap { xar.read($0, max: 4 << 20) }
            .flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] } ?? [:]
        let content = xar.file("Content")
        let sig = xar.signature()

        // Look inside: quick in the preview, longer in the app.
        var scan = Scan()
        if let content {
            // The archive lists every folder first and then the files in an order of its own, so where Info.plist
            // sits cannot be predicted: read until it turns up (or time runs out), then stop.
            scan = XIP.scan(xar, content: content, budget: opts.deep ? 150 : 1.2, wanted: { name in
                let parts = name.split(separator: "/")
                return parts.count == 3 && parts[1] == "Contents" && (parts[2] == "Info.plist" || parts[2] == "version.plist")
            }, enough: { $0.count >= 2 })
        }
        func plist(_ suffix: String) -> [String: Any]? {
            scan.captured.first { $0.key.hasSuffix(suffix) }.flatMap { (try? PropertyListSerialization.propertyList(from: $0.value, format: nil)) as? [String: Any] }
        }
        let info = plist("/Contents/Info.plist")
        let ver = plist("/Contents/version.plist")
        let top = scan.top.first
        let appName = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? top.map { ($0 as NSString).deletingPathExtension }
        var version = (info?["CFBundleShortVersionString"] as? String) ?? (ver?["CFBundleShortVersionString"] as? String)
        let build = (ver?["ProductBuildVersion"] as? String) ?? (info?["DTXcodeBuild"] as? String)
        var versionNote: String?
        if version == nil, let v = firstMatch(url.lastPathComponent, #"[_\- ]v?(\d+(?:\.\d+)+|\d+)(?=[_\-. ])"#) {
            version = v
            versionNote = L("ファイル名から", "from the file name")
        }

        rep.title = appName ?? rep.title
        rep.subtitle = L("Apple の署名付きアーカイブ (xip)", "Apple signed archive (xip)") + (version.map { " · " + L("バージョン ", "Version ") + $0 } ?? "")

        let leaf = sig.names.first ?? ""
        var origin: String
        var tone: Tone = .neutral
        if sig.certs.isEmpty { origin = L("署名なし", "Unsigned"); tone = .bad }
        else if sig.names.contains(where: { $0.hasPrefix("Apple Root CA") }) || leaf.contains("Software Update") || leaf.contains("Apple") { origin = L("Apple の署名", "Signed by Apple"); tone = .good }
        else if leaf.hasPrefix("Developer ID") { origin = "Developer ID"; tone = .good }
        else { origin = L("署名済み", "Signed"); tone = .warn }
        if sig.trusted == false { tone = .warn }
        rep.badges.append(Badge(text: origin, tone: tone))
        if !scan.finished, content != nil { rep.badges.append(Badge(text: L("中身は先頭だけ走査", "Contents partly scanned"), tone: .neutral)) }

        let unpacked = (meta["UncompressedSize"] as? NSNumber)?.intValue
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("署名付きアーカイブ (xip)", "Signed archive (xip)"))
        sum.add(L("中身", "Contains"), scan.top.isEmpty ? nil : scan.top.prefix(5).joined(separator: "\n"), mono: true)
        sum.add(L("バージョン", "Version"), (version.map { $0 + (build.map { " (\($0))" } ?? "") } ?? build).map { $0 + (versionNote.map { "（\($0)）" } ?? "") })
        sum.add(L("識別子", "Identifier"), info?["CFBundleIdentifier"] as? String, mono: true)
        sum.add(L("対応 OS", "Requires"), (info?["LSMinimumSystemVersion"] as? String).map { "macOS \($0) " + L("以降", "or later") })
        sum.add(L("入手元の判定", "Origin"), origin, tone: tone)
        sum.add(L("署名者", "Signed by"), sig.names.first)
        sum.add(L("サイズ", "Size"), byteSize(fileSize) + (unpacked.map { L("（展開後 ", " (unpacked ") + byteSize($0) + L("）", ")") } ?? ""))
        if scan.finished {
            sum.add(L("項目数", "Items"), "\(scan.entries)" + L(" 項目（ファイル \(scan.files) 個、\(byteSize(scan.bytes))）", " items (\(scan.files) files, \(byteSize(scan.bytes)))", " 個項目（\(scan.files) 個檔案，\(byteSize(scan.bytes))）"))
        } else if let content, scan.entries > 0 {
            let pct = content.length > 0 ? scan.consumed * 100 / content.length : 0
            sum.add(L("走査した範囲", "Scanned"), L("先頭の約 \(pct)%（\(scan.entries) 項目まで）", "first ~\(pct)% (\(scan.entries) items)", "前約 \(pct)%（至 \(scan.entries) 個項目）"))
        }
        rep.summary = sum

        var srows = [Row]()
        srows.add(L("判定", "Assessment"), origin, tone: tone)
        srows.add(L("署名者", "Signed by"), sig.names.first)
        if sig.names.count > 1 { srows.add(L("証明書チェーン", "Certificate chain"), sig.names.joined(separator: "\n← ")) }
        if let t = sig.signedAt { srows.add(L("署名日時", "Signed"), dateString(t)) }
        switch sig.trusted {
        case true?: srows.add(L("証明書の信頼", "Certificate trust"), L("信頼済みルートまで検証できました", "Chains to a trusted root"), tone: .good)
        case false?: srows.add(L("証明書の信頼", "Certificate trust"), L("検証できません", "Could not be verified") + (sig.trustError.map { "\n\($0)" } ?? ""), tone: .warn)
        default: break
        }
        rep.sections.append(ReportSection(id: "signature", title: L("署名", "Signature"), symbol: "checkmark.seal",
            blocks: [.rows(srows), .note(L("署名に含まれる証明書を表示しています。アーカイブ内容の照合は行っていません。", "Shows the certificates in the signature; the archive contents are not verified."))]))

        if !meta.isEmpty {
            rep.sections.append(ReportSection(id: "metadata", title: L("メタデータ", "Metadata"), symbol: "doc.text",
                blocks: [.table(TableData(columns: [L("キー", "Key"), L("値", "Value")], rows: meta.keys.sorted().map { [$0, describePlistValue(meta[$0]!)] }))]))
        }
        if let info, let sec = BundleAnalyzer.infoPlistSection(info) { rep.sections.append(sec) }
        if !scan.first.isEmpty {
            var blocks: [Block] = [.table(TableData(columns: [L("パス", "Path"), L("サイズ", "Size")], rows: scan.first, total: scan.finished ? scan.entries : nil))]
            if !scan.finished {
                blocks.append(.note(opts.deep
                    ? L("必要な情報が見つかった時点、または時間の上限（150 秒）で走査を止めています。", "Scanning stops once the needed files are found, or after 150 seconds.")
                    : L("プレビューでは先頭だけを読んでいます。Nakami で開くと、もっと先まで走査します。", "The preview only reads the beginning. Open in Nakami to scan further.")))
            }
            rep.sections.append(ReportSection(id: "contents", title: L("中身（先頭から）", "Contents (from the start)"), symbol: "doc.on.doc", blocks: blocks, count: scan.finished ? scan.entries : nil))
        }
        rep.sections.append(PKG.contentsSection(xar))
        return rep
    }
}
