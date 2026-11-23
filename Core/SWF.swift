import Foundation

/// Flash movies (.swf): header, what the movie contains, and what its scripts are able to do.
enum SWF {
    static func isSWF(_ r: Reader) -> Bool {
        guard r.count > 8, r.u8(1) == 0x57, r.u8(2) == 0x53, r.u8(3) > 0, r.u8(3) < 60 else { return false }   // "?WS"
        return [0x46, 0x43, 0x5a].contains(r.u8(0))
    }

    /// The movie's body (everything after the 8-byte header), unpacked.
    static func body(_ data: Data) -> (data: Data, compression: String)? {
        let r = Reader(data, little: true)
        let total = Int(r.u32(4))
        guard total >= 8, total < 1 << 30 else { return nil }
        switch r.u8(0) {
        case 0x46: return (data.subdata(in: (data.startIndex + 8)..<data.endIndex), "")
        case 0x43:
            guard let d = Inflate.zlib(data.subdata(in: (data.startIndex + 8)..<data.endIndex), max: total) else { return nil }
            return (d, "zlib")
        default:
            // LZMA: 4 bytes of packed size, 5 bytes of properties, then the stream. Rebuild the classic
            // ".lzma" framing (properties + 64-bit unpacked size), which the system can expand.
            guard data.count > 17 else { return nil }
            var framed = r.bytes(12, 5)
            var size = UInt64(total - 8).littleEndian
            withUnsafeBytes(of: &size) { framed.append(contentsOf: $0) }
            framed.append(data.subdata(in: (data.startIndex + 17)..<data.endIndex))
            guard let d = try? (framed as NSData).decompressed(using: .lzma) as Data else { return nil }
            return (d, "LZMA")
        }
    }

    static let products: [UInt32: String] = [1: "Macromedia Flex for J2EE", 2: "Macromedia Flex for .NET", 3: "Adobe Flex"]
    static func player(_ v: Int) -> String {
        switch v {
        case ...10: return "Flash Player \(v)"
        case 11...22: return "Flash Player \(["10.2", "10.3", "11.0", "11.1", "11.2", "11.3", "11.4", "11.5", "11.6", "11.7", "11.8", "11.9"][v - 11])"
        case 23...: return "Flash Player \(v - 11).0"
        default: return "?"
        }
    }

    /// What a script can reach, judged from the names it refers to.
    /// (ActionScript 3 stores a class name apart from its package, so the bare names are what appears.)
    static let abilities: [(needles: [String], ja: String, en: String)] = [
        (["URLLoader", "URLStream", "LoadVars", "loadVariables", "sendAndLoad", "HTTPService", "URLRequest"], "サーバーとの通信", "Talks to servers"),
        (["Socket", "XMLSocket", "SecureSocket", "DatagramSocket"], "ソケット通信", "Raw sockets"),
        (["ExternalInterface", "fscommand"], "ページの JavaScript の呼び出し", "Calls JavaScript in the page"),
        (["SharedObject"], "端末へのデータ保存 (SharedObject)", "Local storage (SharedObject)"),
        (["Camera"], "カメラ", "Camera"),
        (["Microphone"], "マイク", "Microphone"),
        (["FileReference", "FileReferenceList"], "ファイルの読み込みと保存", "File upload / download"),
        (["navigateToURL", "getURL"], "ほかのページを開く", "Opens other pages"),
        (["allowDomain", "allowInsecureDomain", "loadPolicyFile"], "ドメイン間の許可設定", "Cross-domain permissions"),
        (["NetStream", "NetConnection"], "動画・音声のストリーミング", "Media streaming"),
        (["Loader", "loadMovie", "loadMovieNum", "loadBytes"], "別の swf や画像の読み込み", "Loads other movies"),
        (["Clipboard", "setClipboard"], "クリップボード", "Clipboard"),
        (["Stage3D", "Context3D"], "3D 描画 (Stage3D)", "3D rendering (Stage3D)"),
        (["NativeApplication", "NativeProcess", "flash.filesystem"], "Adobe AIR の機能", "Adobe AIR APIs"),
        (["Geolocation"], "位置情報", "Location"),
        (["Accelerometer"], "加速度センサー", "Accelerometer"),
    ]

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        let h = Reader(data, little: true)
        guard isSWF(h) else { return nil }
        var rep = Report(kind: .unknown, path: url.path, title: url.lastPathComponent)
        let version = Int(h.u8(3)), total = Int(h.u32(4))
        let kind = L("Flash ムービー (swf)", "Flash movie (swf)")
        rep.kind = .pkg
        rep.subtitle = kind
        var sum = [Row(L("種類", "Kind"), kind)]
        guard let (bodyData, compression) = body(data) else {
            sum.add(L("形式のバージョン", "SWF version"), "\(version)")
            sum.add(L("中身の読み取り", "Reading the contents"), L("圧縮された中身を展開できませんでした", "The compressed contents could not be expanded"), tone: .warn)
            sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
            rep.summary = sum
            return rep
        }
        let r = Reader(bodyData, little: true)
        // Stage size: a bit-packed rectangle in twips (1/20 pixel).
        let nbits = Int(r.u8(0) >> 3)
        func bitsAt(_ bit: Int, _ n: Int) -> Int {
            var v = 0
            for i in 0..<n { let b = bit + i; v = v << 1 | Int((r.u8(b >> 3) >> UInt8(7 - (b & 7))) & 1) }
            if n > 0, v & (1 << (n - 1)) != 0 { v -= 1 << n }
            return v
        }
        let xmin = bitsAt(5, nbits), xmax = bitsAt(5 + nbits, nbits), ymin = bitsAt(5 + 2 * nbits, nbits), ymax = bitsAt(5 + 3 * nbits, nbits)
        var o = (5 + 4 * nbits + 7) / 8
        let fps = Double(r.u8(o + 1)) + Double(r.u8(o)) / 256
        let frames = Int(r.u16(o + 2))
        o += 4

        var counts = [String: Int]()
        var attrs: UInt8?
        var background: String?
        var metadata: String?
        var product: [Row] = []
        var documentClass: String?
        var symbols = [[String]]()
        var exports = [[String]]()
        var imports = [String]()
        var labels = [String]()
        var abcNames = [String]()
        var strings = Set<String>()
        var hasAS3 = false, hasAS12 = false, debugger = false, protected = false
        var scriptLimits: String?
        var binaryData = 0, binaryBytes = 0
        var tagCount = 0
        var urls = Set<String>()

        func note(_ s: String) {
            guard s.count >= 3, s.count < 300, strings.count < 60_000 else { return }
            strings.insert(s)
            if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("rtmp") {
                // XML namespaces look like URLs but are only names: leave them out.
                let ns = ["adobe.com/20", "adobe.com/AS3", "ns.adobe.com", "www.osmf.org/", "www.w3.org/", "purl.org/", "/internal", "macromedia.com/20"]
                if s.contains("."), !ns.contains(where: { s.contains($0) }) { urls.insert(s) }
            }
        }
        /// ActionScript 1/2 bytecode: collect the strings it pushes and the URLs it opens.
        func actions(_ start: Int, _ end: Int) {
            var p = start
            while p < end {
                let code = r.u8(p); p += 1
                if code == 0 { break }
                guard code >= 0x80 else { continue }
                let len = Int(r.u16(p)); p += 2
                guard p + len <= end else { break }
                if code == 0x83 { let u = r.cstr(p, max: len); note(u); if !u.isEmpty { urls.insert(u) }; strings.insert("getURL") }
                else if code == 0x88 {   // constant pool
                    var q = p + 2
                    while q < p + len { let s = r.cstr(q, max: p + len - q); note(s); q += s.utf8.count + 1 }
                } else if code == 0x96 {   // push
                    var q = p
                    while q < p + len {
                        let t = r.u8(q); q += 1
                        switch t {
                        case 0: let s = r.cstr(q, max: p + len - q); note(s); q += s.utf8.count + 1
                        case 1, 7: q += 4
                        case 4, 5, 8: q += 1
                        case 6: q += 8
                        case 9: q += 2
                        default: break
                        }
                    }
                }
                p += len
            }
        }
        /// ActionScript 3 bytecode (ABC): the string pool names every class and API it touches.
        func abc(_ start: Int, _ end: Int) {
            var p = start + 4
            func u30() -> Int {
                var v = 0, shift = 0
                while p < end, shift < 35 { let b = Int(r.u8(p)); p += 1; v |= (b & 0x7f) << shift; if b & 0x80 == 0 { break }; shift += 7 }
                return v
            }
            // Every count is checked against the bytes that are left: a damaged count must not spin the loop.
            let ints = u30(); guard ints <= end - p + 1 else { return }
            for _ in 1..<Swift.max(ints, 1) { _ = u30() }
            let uints = u30(); guard uints <= end - p + 1 else { return }
            for _ in 1..<Swift.max(uints, 1) { _ = u30() }
            let doubles = u30(); guard doubles <= (end - p) / 8 + 1 else { return }
            p += 8 * Swift.max(doubles - 1, 0)
            let count = u30()
            guard count <= end - p + 1, count < 2_000_000 else { return }
            for _ in 1..<Swift.max(count, 1) {
                let len = u30()
                guard len >= 0, p + len <= end else { return }
                if len >= 3, len < 300 { note(Reader.decode(r.bytes(p, len))) }
                p += len
            }
        }

        while r.ok(o, 2), tagCount < 2_000_000 {
            let head = Int(r.u16(o))
            let code = head >> 6
            var len = head & 0x3f
            o += 2
            if len == 0x3f { len = Int(r.u32(o)); o += 4 }
            guard len >= 0, r.ok(o, len) else { break }
            tagCount += 1
            switch code {
            case 0: o = r.count
            case 1: break
            case 69: attrs = r.u8(o)
            case 9: background = String(format: "#%02X%02X%02X", r.u8(o), r.u8(o + 1), r.u8(o + 2))
            case 77: metadata = r.cstr(o, max: len)
            case 41 where len >= 26:
                let p = products[r.u32(o)] ?? L("不明な製品 (\(r.u32(o)))", "Unknown product (\(r.u32(o)))", "未知產品 (\(r.u32(o)))")
                product.add(L("作成に使われた製品", "Built with"), "\(p) \(r.u8(o + 8)).\(r.u8(o + 9)) (build \(r.u32(o + 10)))")
                let ms = r.u64(o + 18)
                if ms > 0, ms < 4_102_444_800_000 { product.add(L("コンパイル日時", "Compiled"), dateString(Date(timeIntervalSince1970: Double(ms) / 1000))) }
            case 65: scriptLimits = L("再帰の深さ \(r.u16(o))、制限時間 \(r.u16(o + 2)) 秒", "recursion depth \(r.u16(o)), timeout \(r.u16(o + 2)) s", "遞迴深度 \(r.u16(o))、逾時 \(r.u16(o + 2)) 秒")
            case 82, 72:
                hasAS3 = true
                var start = o
                if code == 82 { let name = r.cstr(o + 4, max: len - 4); if !name.isEmpty, abcNames.count < 200 { abcNames.append(name) }; start = o + 4 + name.utf8.count + 1 }
                if opts.deep || strings.count < 30_000 { abc(start, o + len) }
            case 12, 59: hasAS12 = true; actions(code == 59 ? o + 2 : o, o + len)
            case 76, 56:
                var p = o + 2
                for _ in 0..<Int(r.u16(o)) {
                    guard p + 2 < o + len else { break }
                    let id = r.u16(p), name = r.cstr(p + 2, max: o + len - p - 2)
                    p += 2 + name.utf8.count + 1
                    if code == 76, id == 0 { documentClass = name }
                    else if code == 76 { if symbols.count < 3000 { symbols.append(["\(id)", name]) } }
                    else if exports.count < 3000 { exports.append(["\(id)", name]) }
                }
            case 57, 71: let u = r.cstr(o, max: len); if !u.isEmpty { imports.append(u); urls.insert(u) }
            case 58, 64: debugger = true
            case 24: protected = true
            case 87: binaryData += 1; binaryBytes += Swift.max(0, len - 6)
            case 43: if labels.count < 500 { labels.append(r.cstr(o, max: len)) }
            case 2, 22, 32, 83: counts["shape", default: 0] += 1
            case 6, 21, 35, 90, 20, 36: counts["image", default: 0] += 1
            case 14: counts["sound", default: 0] += 1
            case 18, 45: counts["stream", default: 0] += 1
            case 10, 48, 75, 91: counts["font", default: 0] += 1
            case 11, 33, 37: counts["text", default: 0] += 1
            case 39: counts["sprite", default: 0] += 1
            case 7, 34: counts["button", default: 0] += 1
            case 60: counts["video", default: 0] += 1
            case 46, 84: counts["morph", default: 0] += 1
            default: break
            }
            o += len
        }

        // ---- summary
        var title: String?, creatorTool: String?, description: String?, created: String?
        if let m = metadata {
            title = firstMatch(m, #"<dc:title>\s*(?:<rdf:Alt>\s*<rdf:li[^>]*>)?([^<]+)"#) ?? firstMatch(m, #"dc:title=["']([^"']+)"#)
            description = firstMatch(m, #"<dc:description>\s*(?:<rdf:Alt>\s*<rdf:li[^>]*>)?([^<]+)"#)
            creatorTool = firstMatch(m, #"<xmp:CreatorTool>([^<]+)"#) ?? firstMatch(m, #"xmp:CreatorTool=["']([^"']+)"#)
            created = firstMatch(m, #"<xmp:CreateDate>([^<]+)"#) ?? firstMatch(m, #"<dc:date>([^<]+)"#)
        }
        // Flex stamps the same placeholder into every movie it builds; that is not a title.
        if title?.hasPrefix("Adobe Flex") == true { title = nil; if description?.contains("adobe.com/products/flex") == true { description = nil } }
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { rep.title = t }
        let script = hasAS3 || (attrs.map { $0 & 0x08 != 0 } ?? false) ? "ActionScript 3" : hasAS12 ? "ActionScript 1 / 2" : nil
        if let s = script { rep.badges.append(Badge(text: s, tone: .info)) }
        if debugger { rep.badges.append(Badge(text: L("デバッグ可", "Debuggable"), tone: .warn)) }
        let w = Double(xmax - xmin) / 20, hgt = Double(ymax - ymin) / 20
        func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
        sum.add(L("説明", "Description"), description?.trimmingCharacters(in: .whitespacesAndNewlines))
        sum.add(L("画面の大きさ", "Stage size"), w > 0 && hgt > 0 ? "\(num(w)) × \(num(hgt))" + L(" ピクセル", " px") : L("指定なし（表示する側に合わせる）", "Not set (fits its container)"))
        sum.add(L("フレームレート", "Frame rate"), num(fps) + " fps")
        sum.add(L("フレーム数", "Frames"), "\(frames)" + (fps > 0 && frames > 1 ? L("（約 \(num((Double(frames) / fps * 10).rounded() / 10)) 秒）", " (about \(num((Double(frames) / fps * 10).rounded() / 10)) s)", "（約 \(num((Double(frames) / fps * 10).rounded() / 10)) 秒）") : ""))
        sum.add(L("形式のバージョン", "SWF version"), "\(version)" + L("（\(player(version)) 以降向け）", " (for \(player(version)) or later)", "（適用於 \(player(version)) 或以上版本）"))
        sum.add(L("スクリプト", "Scripting"), script ?? L("なし", "None"))
        sum.add(L("最初に動くクラス", "Document class"), documentClass, mono: true)
        sum.add(L("作成ソフト", "Creator tool"), creatorTool)
        sum.append(contentsOf: product)
        sum.add(L("作成日時", "Created"), created)
        sum.add(L("背景色", "Background"), background, mono: true)
        if let a = attrs {
            sum.add(L("ローカルで開いたとき", "When opened locally"), a & 0x01 != 0 ? L("ネットワークに接続できる（ローカルのファイルは読めない）", "May use the network (not local files)") : L("ローカルのファイルを読める（ネットワークには接続できない）", "May read local files (not the network)"))
            if a & 0x20 != 0 || a & 0x40 != 0 { sum.add(L("描画", "Rendering"), a & 0x20 != 0 ? L("GPU を使用", "GPU compositing") : L("直接描画", "Direct blit")) }
        }
        let can = abilities.filter { a in a.needles.contains { strings.contains($0) } }.map { L($0.ja, $0.en) }
        sum.add(L("スクリプトが使う機能", "What the scripts use"), can.joined(separator: "\n"))
        if protected { sum.add(L("読み込み保護", "Import protection"), L("あり（編集ソフトでの読み込みを禁止する印）", "Yes (asks authoring tools not to import it)")) }
        if debugger { sum.add(L("デバッガー", "Debugger"), L("接続を許可", "Allowed"), tone: .warn) }
        sum.add(L("スクリプトの制限", "Script limits"), scriptLimits)
        sum.add(L("埋め込みデータ", "Embedded binary data"), binaryData > 0 ? "\(binaryData)" + L(" 個、", " item(s), ") + byteSize(binaryBytes) : nil)
        sum.add(L("圧縮", "Compression"), compression.isEmpty ? L("なし", "None") : compression)
        sum.add(L("展開後のサイズ", "Unpacked size"), compression.isEmpty ? nil : byteSize(total))
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum

        // ---- sections
        let kinds: [(String, String)] = [("shape", L("図形", "Shapes")), ("image", L("画像", "Images")), ("sprite", L("ムービークリップ", "Movie clips")), ("button", L("ボタン", "Buttons")),
                                         ("text", L("テキスト", "Text fields")), ("font", L("フォント", "Fonts")), ("sound", L("効果音", "Sounds")), ("stream", L("ストリーミング音声", "Streaming sound blocks")),
                                         ("video", L("動画", "Videos")), ("morph", L("変形アニメーション", "Morph shapes"))]
        let crow = kinds.compactMap { k in counts[k.0].map { Row(k.1, "\($0)") } }
        if !crow.isEmpty {
            rep.sections.append(ReportSection(id: "contents", title: L("含まれる素材", "Contents"), symbol: "photo.on.rectangle", blocks: [.rows(crow + [Row(L("タグの総数", "Tags in total"), "\(tagCount)")])]))
        }
        if !urls.isEmpty {
            rep.sections.append(ReportSection(id: "urls", title: L("中に書かれている URL", "URLs Inside"), symbol: "link", blocks: [.text(urls.sorted().prefix(500).joined(separator: "\n"))], count: urls.count))
        }
        if !symbols.isEmpty || !exports.isEmpty || !abcNames.isEmpty {
            var blocks = [Block]()
            if !abcNames.isEmpty { blocks.append(.heading(L("スクリプトのまとまり", "Script blocks"))); blocks.append(.text(abcNames.joined(separator: "\n"))) }
            if !symbols.isEmpty { blocks.append(.heading(L("クラスに結び付いた素材", "Symbols linked to classes"))); blocks.append(.table(TableData(columns: ["ID", L("クラス", "Class")], rows: symbols))) }
            if !exports.isEmpty { blocks.append(.heading(L("書き出された素材", "Exported assets"))); blocks.append(.table(TableData(columns: ["ID", L("名前", "Name")], rows: exports))) }
            rep.sections.append(ReportSection(id: "symbols", title: L("クラスと素材の名前", "Classes and Symbols"), symbol: "curlybraces", blocks: blocks, count: symbols.count + exports.count))
        }
        if !labels.isEmpty { rep.sections.append(ReportSection(id: "labels", title: L("フレームのラベル", "Frame Labels"), symbol: "tag", blocks: [.text(labels.joined(separator: "\n"))], count: labels.count)) }
        if !imports.isEmpty { rep.sections.append(ReportSection(id: "imports", title: L("読み込む外部の swf", "Imported Movies"), symbol: "square.and.arrow.down", blocks: [.text(imports.joined(separator: "\n"))], count: imports.count)) }
        // Class names used by ActionScript 3 (packages written "a.b:Class" or "a.b.Class").
        let classes = strings.filter { $0.hasPrefix("flash.") || $0.hasPrefix("mx.") || $0.hasPrefix("spark.") || $0.hasPrefix("fl.") }.sorted()
        if !classes.isEmpty {
            rep.sections.append(ReportSection(id: "apis", title: L("使っている Flash の機能", "Flash APIs Used"), symbol: "puzzlepiece", blocks: [.text(classes.prefix(opts.deep ? 5000 : 400).joined(separator: "\n"))], count: classes.count))
        }
        if let m = metadata, !m.isEmpty { rep.sections.append(ReportSection(id: "metadata", title: L("メタデータ (XMP)", "Metadata (XMP)"), symbol: "doc.text", blocks: [.text(String(m.prefix(20_000)))])) }
        if opts.deep, !strings.isEmpty {
            rep.sections.append(ReportSection(id: "strings", title: L("スクリプト内の文字列", "Script Strings"), symbol: "text.quote", blocks: [.text(strings.sorted().prefix(20_000).joined(separator: "\n"))], count: strings.count))
        }
        return rep
    }
}
