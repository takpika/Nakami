import Foundation

enum Analyzer {
    static func analyze(_ url: URL, opts: AnalyzeOptions = AnalyzeOptions()) -> Report {
        let url = url.standardizedFileURL
        #if os(macOS)
        if BundleAnalyzer.isBundle(url) { return BundleAnalyzer.report(url: url, opts: opts) }
        #else
        // iOS has no Security.framework code-signing API: read the bundle's files directly, like an unpacked ipa.
        if BundleAnalyzer.isBundle(url), let zip = Zip(directory: url), let dir = IPA.appDir(zip) {
            return IPA.report(url: url, zip: zip, dir: dir, fileSize: zip.totalUncompressed, opts: opts)
        }
        #endif

        var rep = Report(kind: .unknown, path: url.path, title: url.lastPathComponent)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            rep.subtitle = L("ファイルが見つかりません", "File not found")
            return rep
        }
        guard !isDir.boolValue, let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            rep.subtitle = L("読み込めませんでした", "Could not be read")
            return rep
        }
        // Compressed kernel modules (.ko.xz / .ko.gz): look inside.
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".ko.xz") || lower.hasSuffix(".ko.gz") || lower.hasSuffix(".ko.zst"), data.count < 256 << 20 {
            let inner: Data? = lower.hasSuffix(".gz") ? Inflate.gzip(data) : lower.hasSuffix(".xz") ? (try? (data as NSData).decompressed(using: .lzma) as Data) : Zstd.decode(data, max: 512 << 20)
            if let inner, inner.count > 64, ELF.isELF(Reader(inner)) {
                var m = ELF.report(url: url, data: inner, opts: opts)
                m.summary.add(L("圧縮", "Compression"), (lower.hasSuffix(".gz") ? "gzip" : lower.hasSuffix(".xz") ? "xz" : "zstd") + L("（展開後 ", " (unpacked ") + byteSize(inner.count) + L("）", ")"))
                return withIcon(m, url)
            }
            if lower.hasSuffix(".zst") {
                rep.subtitle = L("圧縮された Linux カーネルモジュール (zstd)", "Compressed Linux kernel module (zstd)")
                rep.summary = [Row(L("種類", "Kind"), L("カーネルモジュール（zstd 圧縮）", "Kernel module (zstd-compressed)")),
                               Row(L("中身の読み取り", "Reading the contents"), L("zstd の展開には対応していないため、中は読めません", "zstd is not supported here, so the module itself is not read")),
                               Row(L("サイズ", "Size"), byteSizeExact(data.count))]
                rep.kind = .elf
                return withIcon(rep, url)
            }
        }
        let r = Reader(data)
        if data.count >= 4 {
            if ELF.isELF(r) { rep = ELF.report(url: url, data: data, opts: opts); AppImage.augment(&rep, data: data) }
            else if RPM.isRPM(r), let p = RPM.report(url: url, data: data, opts: opts) { rep = p }
            else if SWF.isSWF(r), let p = SWF.report(url: url, data: data, opts: opts) { rep = p }
            else if Snap.isSquash(r), let p = Snap.report(url: url, data: data, opts: opts) { rep = p }
            else if MachO.isMachO(r) { rep = MachO.report(url: url, data: data, opts: opts) }
            else if PE.isMZ(r), data.count >= 0x40 { rep = PE.report(url: url, data: data, opts: opts) }
            else if Kernels.isLinuxBoot(Reader(data, little: true)) { rep = Kernels.linux(url: url, data: data) }
            else if let k = Kernels.linuxPlain(url: url, data: data) { rep = k }
            else if Xar.isXar(r), let p = PKG.report(url: url, data: data, opts: opts) { rep = p }
            else if CompoundFile.isCFB(r), let m = MSI.report(url: url, data: data, opts: opts) { rep = m }
            else if Zip.isZip(r), let zip = Zip(data) {
                if IPSW.isIPSW(zip) { rep = IPSW.report(url: url, zip: zip, fileSize: data.count, opts: opts) }
                else if let dir = IPA.appDir(zip) { rep = IPA.report(url: url, zip: zip, dir: dir, fileSize: data.count, opts: opts) }
                else if APK.isAPK(zip) { rep = APK.report(url: url, zip: zip, fileSize: data.count, opts: opts) }
                else if AAB.isAAB(zip) { rep = AAB.report(url: url, zip: zip, fileSize: data.count, opts: opts) }
                else if Appx.kind(zip) != nil { rep = Appx.report(url: url, zip: zip, fileSize: data.count, opts: opts) }
                else if JAR.isJAR(zip) { rep = JAR.report(url: url, zip: zip, fileSize: data.count, opts: opts) }
            }
        }
        if rep.kind == .unknown, let d = Deb.report(url: url, data: data, opts: opts) { rep = d }
        if rep.kind == .unknown, let f = Flatpak.refReport(url: url, data: data) { rep = f }
        if rep.kind == .unknown, lower.hasSuffix(".flatpak") || r.fixedStr(0, 4) == "flat", let f = Flatpak.report(url: url, data: data, opts: opts) { rep = f }
        if rep.kind == .unknown, let ar = Archive.report(url: url, data: data) { rep = ar }
        if rep.kind == .unknown, let a = ClassicArchive.report(url: url, data: data, opts: opts) { rep = a }
        if rep.kind == .unknown, let c = ClassicMac.report(url: url, data: data, opts: opts, inner: { inner, name in
            let u = URL(fileURLWithPath: name)
            return ClassicArchive.report(url: u, data: inner, opts: opts) ?? (inner.count > 2048 ? DiskImage.report(url: u, data: inner, opts: opts) : nil)
        }) { rep = c }
        // A disk image whose first chunk happens to be bzip2 or zlib data starts like a compressed file:
        // the image's own trailer decides.
        let isDMG = DMGDevice.hasTrailer(DataDevice(data))
        if rep.kind == .unknown, !isDMG, let t = TarArchive.report(url: url, data: data, opts: opts) { rep = t }
        if rep.kind == .unknown, !isDMG, let c = CompressedFile.report(url: url, data: data) { rep = c }
        if rep.kind == .unknown, let v = VirtualDisk.report(url: url, data: data, opts: opts) { rep = v }
        if rep.kind == .unknown, let c = Console.report(url: url, data: data, opts: opts) { rep = c }
        // A resource fork saved as an ordinary file (.rsrc).
        if rep.kind == .unknown, lower.hasSuffix(".rsrc"), ClassicMac.Resources(data) != nil {
            var f = ClassicMac.Fork(name: url.lastPathComponent)
            f.resource = data
            f.wrapper = L("リソースフォークだけを保存したファイル", "A resource fork saved on its own")
            rep = ClassicMac.describe(f, url: url, fileSize: data.count, opts: opts)
        }
        // A file that still has its resource fork on this Mac (classic applications, fonts, extensions).
        if rep.kind == .unknown, let f = ClassicMac.native(url, data: data) { rep = ClassicMac.describe(f, url: url, fileSize: data.count + f.resource.count, opts: opts) }
        if rep.kind == .unknown, let tx = textReport(url: url, data: data) { return withIcon(tx, url) }
        if rep.kind == .unknown {
            rep.subtitle = L("対応していない形式です", "Unsupported format")
            rep.summary = [Row(L("サイズ", "Size"), byteSizeExact(data.count)),
                           Row(L("先頭のバイト列", "First bytes"), r.bytes(0, Swift.min(16, data.count)).map { String(format: "%02X", $0) }.joined(separator: " "), mono: true)]
            rep.sections = []
        } else if let q = BundleAnalyzer.quarantine(url) {
            rep.summary.add(L("ダウンロード元", "Quarantine"), q)
        }
        return withIcon(rep, url)
    }

    static func withIcon(_ rep0: Report, _ url: URL) -> Report {
        var rep = rep0
        if rep.icon == nil { rep.icon = ImageKit.systemIcon(url) }
        return rep
    }

    /// Extension-less executables are often scripts: show them as text instead of "unsupported".
    static func textReport(url: URL, data: Data) -> Report? {
        let head = data.prefix(256 << 10)
        guard !head.isEmpty, !head.prefix(8192).contains(0), let text = String(data: head, encoding: .utf8) ?? String(data: head.dropLast(3), encoding: .utf8) else { return nil }
        var rep = Report(kind: .unknown, path: url.path, title: url.lastPathComponent)
        let lines = text.components(separatedBy: "\n")
        var sum = [Row]()
        if let first = lines.first, first.hasPrefix("#!") {
            let interp = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            rep.subtitle = L("スクリプト", "Script")
            sum.add(L("インタープリター", "Interpreter"), interp, mono: true)
        } else {
            rep.subtitle = L("テキストファイル", "Text file")
        }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        let shown = lines.prefix(400).joined(separator: "\n") + (lines.count > 400 || data.count > head.count ? "\n…" : "")
        rep.sections = [ReportSection(id: "text", title: L("内容", "Contents"), symbol: "doc.plaintext", blocks: [.text(shown)])]
        return rep
    }
}

/// Unix `ar` archives (.a) and COFF import/static libraries (.lib).
enum Archive {
    static func report(url: URL, data: Data) -> Report? {
        let r = Reader(data)
        guard data.count >= 8, r.fixedStr(0, 8) == "!<arch>\n" else { return nil }
        var rep = Report(kind: .unknown, path: url.path, title: url.lastPathComponent)
        var members = [[String]]()
        var total = 0
        var longNames = Data()
        var kinds = [String: Int]()
        var o = 8
        while r.ok(o, 60), total < 200_000 {
            var name = r.fixedStr(o, 16).trimmingCharacters(in: .whitespaces)
            let size = Int(r.fixedStr(o + 48, 10).trimmingCharacters(in: .whitespaces)) ?? 0
            var body = o + 60
            var bodySize = size
            if name.hasPrefix("#1/"), let n = Int(name.dropFirst(3)) {  // BSD long name
                name = r.fixedStr(body, n)
                body += n
                bodySize -= n
            } else if name == "//" {  // GNU long-name table
                longNames = r.bytes(body, size)
            } else if name.hasPrefix("/"), let n = Int(name.dropFirst()), n < longNames.count {
                let tail = longNames.dropFirst(n)
                let end = tail.firstIndex(where: { $0 == 0x0a || $0 == 0 }) ?? tail.endIndex
                name = Reader.decode(Data(tail[..<end]))
            }
            if name.hasSuffix("/") && name.count > 1 { name.removeLast() }
            let special = name == "/" || name == "//" || name.hasPrefix("__.SYMDEF") || name.isEmpty
            if !special {
                total += 1
                let m = r.be32(body)
                var kind = "?"
                if m == 0x7f45_4c46 { kind = "ELF " + (ELF.machines[r.u8(body + 5) == 2 ? r.be16(body + 18) : r.le16(body + 18)] ?? "") }
                else if [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe].contains(m) {
                    let le = m == 0xcefa_edfe || m == 0xcffa_edfe
                    kind = "Mach-O " + MachO.archName(le ? r.le32(body + 4) : r.be32(body + 4), le ? r.le32(body + 8) : r.be32(body + 8))
                } else if r.le16(body) == 0 && r.le16(body + 2) == 0xffff {
                    kind = "COFF import " + (PEFile.machines[r.le16(body + 6)] ?? "")
                } else if let mn = PEFile.machines[r.le16(body)] { kind = "COFF " + mn }
                else if r.fixedStr(body, 4) == "BC\u{c0}\u{de}" || m == 0x4243_c0de { kind = "LLVM bitcode" }
                kinds[kind, default: 0] += 1
                if members.count < 5000 { members.append([name, kind, byteSize(Swift.max(0, bodySize))]) }
            }
            o += 60 + size + (size & 1)
        }
        guard total > 0 || o > 8 else { return nil }
        let summary = kinds.sorted { $0.value > $1.value }.map { "\($0.key) × \($0.value)" }.joined(separator: ", ")
        rep.subtitle = L("スタティックライブラリ (ar)", "Static library (ar)") + (kinds.count == 1 ? " · " + kinds.keys.first! : "")
        rep.summary = [Row(L("種類", "Kind"), L("スタティックライブラリ / インポートライブラリ", "Static / import library")),
                       Row(L("メンバー", "Members"), "\(total)" + L(" 個", "")),
                       Row(L("内容", "Contents"), summary),
                       Row(L("サイズ", "Size"), byteSizeExact(data.count))]
        rep.sections = [ReportSection(id: "members", title: L("メンバー", "Members"), symbol: "tray.full",
            blocks: [.table(TableData(columns: [L("名前", "Name"), L("形式", "Format"), L("サイズ", "Size")], rows: members, total: total))], count: total)]
        return rep
    }
}
