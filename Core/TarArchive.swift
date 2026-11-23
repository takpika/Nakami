import Foundation
import CoreGraphics

/// tar archives, plain or compressed (.tar / .tar.gz / .tar.xz / .tar.bz2 / .tar.zst). When the archive holds
/// an app — typically "Install macOS ….app" — the app is described; otherwise the contents are listed.
enum TarArchive {
    static func detect(_ data: Data) -> Unpack.Codec? {
        let codec = Unpack.codec(Reader(data))
        if codec == .none { return ArchiveScanner.isTarHeader(data.prefix(512)) ? Unpack.Codec.none : nil }
        guard [.gzip, .xz, .bzip2, .zstd].contains(codec), codec != .bzip2 || data.count < 64 << 20 else { return nil }
        return ArchiveScanner.isTarHeader(Unpack.head(data, codec: codec, count: 512)) ? codec : nil
    }

    /// Which macOS an installer app is for, as far as its name and own version number tell: the major
    /// release only. (The exact version is recorded inside the multi-gigabyte image further into the archive.)
    static func macOSMajor(app: String, installer v: String?) -> String? {
        let hit = DiskImage.macNames.sorted { $0.name.count > $1.name.count }.first { app.localizedCaseInsensitiveContains($0.name) }
        if let hit { return hit.prefix }
        guard let major = v?.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        switch major {
        case 13...15: return "10.\(major)"
        case 16...20: return "\(major - 5)"
        case 26...: return "\(major)"
        default: return nil
        }
    }

    struct Scan { var sc: ArchiveScanner; var complete: Bool; var app: String? }

    static func scan(_ data: Data, codec: Unpack.Codec, budget: TimeInterval, stopEarly: Bool) -> Scan {
        let sc = ArchiveScanner(.tar)
        var app: String?
        var iconName: String?
        sc.want = { name, size in
            let parts = name.split(separator: "/")
            guard let top = parts.first, top.hasSuffix(".app") else { return false }
            if app == nil { app = String(top) }
            guard String(top) == app else { return false }
            if name.hasSuffix(".app/Contents/Info.plist") && parts.count == 3 { return true }
            if parts.count == 4, parts[2] == "Resources", name.hasSuffix(".icns"), size < 8 << 20 { return iconName == nil || parts[3] == iconName! }
            if name.hasSuffix("/Contents/SharedSupport/InstallInfo.plist") || name.hasSuffix("/Contents/version.plist") { return size < 1 << 20 }
            return false
        }
        sc.enough = { s in
            guard let a = app, let info = s.kept[a + "/Contents/Info.plist"] else { return false }
            if iconName == nil, let p = (try? PropertyListSerialization.propertyList(from: info, format: nil)) as? [String: Any] {
                let n = (p["CFBundleIconFile"] as? String) ?? ""
                iconName = n.isEmpty ? "" : (n.hasSuffix(".icns") ? n : n + ".icns")
            }
            guard stopEarly else { return false }
            // Older installers (10.7 – 10.15) say the exact system version in a small file: keep going for it.
            let old = a.contains("OS X") || ["Sierra", "Mojave", "Catalina"].contains { a.contains($0) }
            if old, s.kept[a + "/Contents/SharedSupport/InstallInfo.plist"] == nil { return false }
            return iconName == "" || s.kept[a + "/Contents/Resources/" + (iconName ?? "")] != nil
        }
        let done = Unpack.stream(data, codec: codec, budget: budget) { sc.feed($0) }
        return Scan(sc: sc, complete: done || sc.finished, app: app)
    }

    static func icon(_ data: Data) -> CGImage? {
        guard let codec = detect(data) else { return nil }
        let s = scan(data, codec: codec, budget: 1.5, stopEarly: true)
        guard let a = s.app, let d = s.sc.kept.first(where: { $0.key.hasPrefix(a + "/Contents/Resources/") && $0.key.hasSuffix(".icns") })?.value else { return nil }
        return ImageKit.decode(d)
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        guard let codec = detect(data) else { return nil }
        let s = scan(data, codec: codec, budget: opts.deep ? 180 : Swift.max(1.5, opts.budget), stopEarly: !opts.deep)
        let sc = s.sc
        guard sc.total > 0 else { return nil }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        let codecName = codec == .none ? L("無圧縮", "uncompressed") : codec.rawValue
        var kind = L("tar アーカイブ（\(codecName)）", "tar archive (\(codecName))", "tar 封存檔（\(codecName)）")
        var sum = [Row]()
        if let a = s.app, let info = sc.kept[a + "/Contents/Info.plist"].flatMap({ (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }) {
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? String(a.dropLast(4))
            let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
            let id = (info["CFBundleIdentifier"] as? String) ?? ""
            let isInstaller = id.hasPrefix("com.apple.InstallAssistant") || ["Install macOS", "Install OS X", "Install Mac OS X"].contains { a.hasPrefix($0) }
            if isInstaller {
                kind = L("macOS のインストーラー（tar アーカイブ、\(codecName)）", "macOS installer (tar archive, \(codecName))", "macOS 安裝程式（tar 封存檔，\(codecName)）")
                rep.badges.append(Badge(text: "macOS", tone: .info))
                var version: String?
                if let ii = sc.kept[a + "/Contents/SharedSupport/InstallInfo.plist"].flatMap({ (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }),
                   let sys = ii["System Image Info"] as? [String: Any] { version = sys["version"] as? String }
                let exact = version != nil
                if version == nil { version = macOSMajor(app: a, installer: short) }
                rep.title = version.map { DiskImage.macOSName($0) } ?? name
                sum.add(L("インストーラー", "Installer"), a, mono: true)
                sum.add(L("macOS のバージョン", "macOS version"), version.map { $0 + (exact ? "" : L("（細かい版数はアーカイブを展開しないと分かりません）", " (the exact version is only known after unpacking)")) })
                sum.add(L("インストーラーのバージョン", "Installer version"), short.map { $0 + (build.map { " (\($0))" } ?? "") })
            } else {
                kind = L("アプリの入った tar アーカイブ（\(codecName)）", "tar archive with an app (\(codecName))", "含 App 的 tar 封存檔（\(codecName)）")
                rep.title = name
                sum.add(L("アプリ", "App"), a, mono: true)
                sum.add(L("バージョン", "Version"), short.map { $0 + (build != nil && build != $0 ? " (\(build!))" : "") } ?? build)
            }
            sum.add(L("識別子", "Identifier"), id, mono: true)
            sum.add(L("動作に必要な OS", "Runs on"), (info["LSMinimumSystemVersion"] as? String).map { "macOS \($0) " + L("以降", "or later") })
            sum.add(L("著作権", "Copyright"), info["NSHumanReadableCopyright"] as? String)
            if let d = sc.kept.first(where: { $0.key.hasPrefix(a + "/Contents/Resources/") && $0.key.hasSuffix(".icns") })?.value { rep.icon = ImageKit.decode(d) }
        }
        rep.subtitle = kind
        sum.insert(Row(L("種類", "Kind"), kind), at: 0)
        if s.complete {
            sum.add(L("ファイル数", "Files"), "\(sc.entries.filter { !$0.isDir }.count)")
            sum.add(L("展開後のサイズ", "Unpacked size"), byteSize(sc.totalBytes))
        } else if s.app == nil {
            sum.add(L("中身の読み取り", "Reading the contents"), L("時間内に読めた先頭の \(sc.total) 件までを表示しています", "Showing the first \(sc.total) entries read within the time limit", "顯示在時間限制內讀取到的前 \(sc.total) 項"))
        }
        sum.add(L("圧縮", "Compression"), codec == .none ? L("なし", "None") : codec.rawValue)
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        // Top-level items, then the files seen.
        var tops = [String: (count: Int, size: Int, dir: Bool)]()
        for e in sc.entries {
            let parts = e.name.split(separator: "/", maxSplits: 1)
            guard let top = parts.first else { continue }
            var cur = tops[String(top)] ?? (0, 0, false)
            if parts.count > 1 || e.isDir { cur.dir = true }
            if !e.isDir { cur.count += 1; cur.size += e.size }
            tops[String(top)] = cur
        }
        let topRows = tops.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.prefix(2000).map { [$0.key + ($0.value.dir ? "/" : ""), $0.value.dir ? "\($0.value.count)" : "", byteSize($0.value.size)] }
        rep.sections.append(ReportSection(id: "root", title: L("最上位の項目", "Top-level Items"), symbol: "folder",
            blocks: (s.complete ? [] : [.note(L("時間内に読めた分だけを表示しています（アプリで開くと最後まで読みます）。", "Only the part read within the time limit is shown (opening in the app reads to the end)."))])
                + [.table(TableData(columns: [L("名前", "Name"), L("中のファイル数", "Files inside"), L("サイズ", "Size")], rows: Array(topRows)))], count: s.complete ? tops.count : nil))
        if s.complete || s.app == nil { rep.sections.append(LinuxApp.filesSection(sc.entries, total: sc.total, complete: s.complete, deep: opts.deep)) }
        if let last = rep.sections.indices.last, rep.sections[last].id == "files" { rep.sections[last].title = L("ファイル（大きい順）", "Files (largest first)") }
        return rep
    }
}

/// A single file squeezed with gzip / xz / bzip2 / zstd that is not a tar archive: say what it is and what is inside.
enum CompressedFile {
    static func report(url: URL, data: Data) -> Report? {
        let codec = Unpack.codec(Reader(data))
        guard [.gzip, .xz, .bzip2, .zstd].contains(codec) else { return nil }
        var rep = Report(kind: .unknown, path: url.path, title: url.lastPathComponent)
        let kind = L("圧縮されたファイル (\(codec.rawValue))", "Compressed file (\(codec.rawValue))", "已壓縮的檔案 (\(codec.rawValue))")
        rep.subtitle = kind
        var sum = [Row(L("種類", "Kind"), kind)]
        let head = codec == .bzip2 && data.count > 32 << 20 ? Data() : Unpack.head(data, codec: codec, count: 4096)
        let r = Reader(head)
        var inner: String?
        if head.count >= 8 {
            if ELF.isELF(r) { inner = "ELF" }
            else if MachO.isMachO(r) { inner = "Mach-O" }
            else if r.fixedStr(0, 6) == "070701" || r.fixedStr(0, 6) == "070707" { inner = L("cpio アーカイブ（Linux の初期 RAM ディスクなど）", "cpio archive (such as a Linux initial RAM disk)") }
            else if r.fixedStr(0, 4) == "hsqs" { inner = "SquashFS" }
            else if r.fixedStr(0, 15) == "SQLite format 3" { inner = L("SQLite データベース", "SQLite database") }
            else if r.fixedStr(0, 5) == "%PDF-" { inner = "PDF" }
            else if r.fixedStr(0x38, 4) == "ARM\u{64}" { inner = L("Linux カーネル (ARM64)", "Linux kernel (ARM64)") }
            else if !head.prefix(1024).contains(0), String(data: head.prefix(1024), encoding: .utf8) != nil || String(data: head.prefix(1021), encoding: .utf8) != nil { inner = L("テキスト", "Text") }
        }
        sum.add(L("中身", "Contents"), inner)
        // A .dmg should end with the image's own trailer; without it the file was most likely cut short.
        if url.pathExtension.lowercased() == "dmg" {
            sum.add(L("注意", "Note"), L("ディスクイメージとして読めません。末尾の情報が無く、途中で切れている（ダウンロードが完了していない）可能性があります", "Not readable as a disk image: its trailer is missing, so the file is probably cut short (an unfinished download)"), tone: .warn)
        }
        if codec == .gzip, data.count > 18 {
            // gzip records the original name and the size (modulo 4 GB).
            let g = Reader(data, little: true)
            if g.u8(3) & 8 != 0 {
                var o = 10
                if g.u8(3) & 4 != 0 { o += 2 + Int(g.u16(o)) }
                sum.add(L("元のファイル名", "Original name"), g.cstr(o, max: 512), mono: true)
            }
            let t = g.u32(4)
            if t != 0 { sum.add(L("元の更新日時", "Original modified"), dateString(Date(timeIntervalSince1970: Double(t)))) }
            if data.count < 4 << 30 { sum.add(L("展開後のサイズ", "Unpacked size"), byteSize(Int(g.u32(data.count - 4)))) }
        }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        rep.kind = .pkg
        if inner == L("テキスト", "Text"), let t = String(data: head, encoding: .utf8) ?? String(data: head.dropLast(3), encoding: .utf8) {
            rep.sections = [ReportSection(id: "text", title: L("内容の先頭", "Start of the contents"), symbol: "doc.plaintext", blocks: [.text(t)])]
        }
        return rep
    }
}
