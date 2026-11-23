import Foundation
import CoreGraphics

/// What Linux packages have in common: the files they install, which of those are commands, services or
/// privileged programs, and the desktop entry (name, icon) of the app inside.
enum LinuxApp {
    /// Files worth keeping while an archive streams past: desktop entries and candidate icons.
    static func want(_ name: String, _ size: Int) -> Bool {
        let n = name.lowercased()
        if n.hasSuffix(".desktop") { return size < 256 << 10 && (n.contains("share/applications/") || !n.contains("/")) }
        if n.hasSuffix(".png") {
            guard size < 3 << 20 else { return false }
            return n.contains("/icons/") || n.contains("/pixmaps/") || !n.contains("/") || n.hasSuffix("/.diricon") || n.contains("meta/gui/")
        }
        return name == ".DirIcon" && size < 3 << 20
    }

    /// The [Desktop Entry] group; a Japanese name wins when the user reads Japanese.
    static func desktop(_ text: String) -> [String: String] {
        var out = [String: String](), inside = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line == "[Desktop Entry]"; continue }
            guard inside, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces), v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if out[k] == nil { out[k] = v }
        }
        if prefersJapanese {
            for k in ["Name", "Comment", "GenericName"] { if let v = out[k + "[ja]"] ?? out[k + "[ja_JP]"] { out[k] = v } }
        }
        return out
    }

    static func icon(named icon: String?, in kept: [String: Data]) -> CGImage? {
        let pngs = kept.filter { $0.key.lowercased().hasSuffix(".png") || $0.key.hasSuffix(".DirIcon") }
        func score(_ path: String, _ d: Data) -> Int {
            if let m = firstMatch(path, #"/(\d+)x\d+/"#), let s = Int(m) { return s <= 512 ? s * 1000 : 1 }
            return Swift.min(d.count / 100, 200_000)
        }
        var pool = pngs
        if let icon, !icon.isEmpty {
            let base = (icon as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
            let exact = pngs.filter { ($0.key as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "") == base }
            if !exact.isEmpty { pool = exact }
            else if let d = kept[icon.hasPrefix("/") ? String(icon.dropFirst()) : icon], let i = ImageKit.decode(d) { return i }
        }
        for (_, d) in pool.sorted(by: { score($0.key, $0.value) > score($1.key, $1.value) }) { if let i = ImageKit.decode(d) { return i } }
        return nil
    }

    struct App { var rows: [Row] = []; var name: String?; var icon: CGImage? }

    static func describe(_ kept: [String: Data]) -> App {
        var app = App()
        let entries = kept.filter { $0.key.lowercased().hasSuffix(".desktop") }.sorted { $0.key.count < $1.key.count }
        var iconName: String?
        for (path, d) in entries {
            let e = desktop(String(decoding: d, as: UTF8.self))
            guard e["Type"] == nil || e["Type"] == "Application", e["NoDisplay"] != "true" || entries.count == 1 else { continue }
            app.name = e["Name"]
            iconName = e["Icon"]
            app.rows.add(L("アプリ名", "App name"), e["Name"])
            app.rows.add(L("説明", "Comment"), e["Comment"] ?? e["GenericName"])
            app.rows.add(L("起動コマンド", "Launch command"), e["Exec"], mono: true)
            app.rows.add(L("カテゴリ", "Categories"), e["Categories"]?.split(separator: ";").joined(separator: ", "))
            app.rows.add(L("対応するファイルの種類", "Opens"), e["MimeType"].map { m in
                let all = m.split(separator: ";").filter { !$0.isEmpty }
                return all.prefix(8).joined(separator: ", ") + (all.count > 8 ? L(" ほか \(all.count - 8) 種類", " and \(all.count - 8) more") : "")
            })
            if e["Terminal"] == "true" { app.rows.add(L("端末で動作", "Runs in a terminal"), L("はい", "Yes")) }
            app.rows.add(L("メニュー項目のファイル", "Desktop entry"), path, mono: true)
            break
        }
        app.icon = icon(named: iconName, in: kept)
        return app
    }

    /// What installing these files does to a system, beyond putting an app in place.
    static func effects(_ entries: [ArchiveScanner.Entry]) -> [Row] {
        var rows = [Row]()
        func names(_ test: (String) -> Bool, _ cap: Int = 12) -> String? {
            let all = entries.filter { !$0.isDir && test($0.name) }.map { ($0.name as NSString).lastPathComponent }
            guard !all.isEmpty else { return nil }
            return all.prefix(cap).joined(separator: ", ") + (all.count > cap ? L(" ほか \(all.count - cap) 個", " and \(all.count - cap) more") : "")
        }
        func inDir(_ dirs: [String]) -> (String) -> Bool { { n in dirs.contains { n.hasPrefix($0) && !n.dropFirst($0.count).contains("/") } } }
        rows.add(L("入るコマンド", "Commands"), names(inDir(["usr/bin/", "bin/", "usr/sbin/", "sbin/", "usr/local/bin/", "usr/games/"])), mono: true)
        rows.add(L("常駐サービス", "Services"), names { ($0.contains("systemd/system/") || $0.contains("systemd/user/")) && ($0.hasSuffix(".service") || $0.hasSuffix(".timer") || $0.hasSuffix(".socket")) || $0.hasPrefix("etc/init.d/") }, mono: true)
        rows.add(L("ログイン時に自動で起動", "Starts at login"), names { $0.hasPrefix("etc/xdg/autostart/") }, mono: true)
        let setuid = entries.filter { !$0.isDir && $0.mode & 0o6000 != 0 }.map { $0.name }
        if !setuid.isEmpty { rows.add(L("管理者の権限で動くプログラム (setuid)", "Runs with elevated rights (setuid)"), setuid.prefix(10).joined(separator: "\n"), mono: true, tone: .warn) }
        rows.add(L("カーネルモジュール", "Kernel modules"), names { $0.hasSuffix(".ko") || $0.hasSuffix(".ko.xz") || $0.hasSuffix(".ko.zst") || $0.hasSuffix(".ko.gz") }, mono: true)
        rows.add(L("デバイスの規則 (udev)", "udev rules"), names { $0.contains("udev/rules.d/") }, mono: true)
        rows.add(L("定期実行 (cron)", "Scheduled jobs (cron)"), names { $0.hasPrefix("etc/cron") }, mono: true)
        rows.add(L("パッケージの入手先を追加", "Adds a package source"), names { $0.hasPrefix("etc/apt/sources.list.d/") || $0.hasPrefix("etc/yum.repos.d/") || $0.hasPrefix("etc/apt/trusted.gpg.d/") || $0.hasPrefix("usr/share/keyrings/") }, mono: true)
        return rows
    }

    static func filesSection(_ entries: [ArchiveScanner.Entry], total: Int, complete: Bool, deep: Bool) -> ReportSection {
        let files = entries.filter { !$0.isDir }.sorted { $0.size > $1.size }
        let rows = files.prefix(deep ? 5000 : 300).map { ["/" + $0.name, $0.link != nil ? L("リンク", "link") : byteSize($0.size), String($0.mode & 0o7777, radix: 8)] }
        var blocks: [Block] = [.table(TableData(columns: [L("パス", "Path"), L("サイズ", "Size"), L("権限", "Mode")], rows: rows, total: files.count))]
        if !complete { blocks.insert(.note(L("時間内に読めた分だけを表示しています（アプリで開くと最後まで読みます）。", "Only the part read within the time limit is shown (opening in the app reads to the end).")), at: 0) }
        return ReportSection(id: "files", title: L("インストールされるファイル（大きい順）", "Installed Files (largest first)"), symbol: "doc.on.doc", blocks: blocks, count: complete ? files.count : nil)
    }

    static func scriptsSection(_ scripts: [(String, String)]) -> ReportSection? {
        guard !scripts.isEmpty else { return nil }
        var blocks = [Block]()
        for (name, body) in scripts {
            blocks.append(.heading(name))
            let lines = body.components(separatedBy: "\n")
            blocks.append(.text(lines.prefix(300).joined(separator: "\n") + (lines.count > 300 ? "\n…" : "")))
        }
        return ReportSection(id: "scripts", title: L("インストール時に実行されるスクリプト", "Install Scripts"), symbol: "terminal", blocks: blocks, count: scripts.count)
    }

    static let archNames: [String: String] = [
        "amd64": "x64 (amd64)", "x86_64": "x64 (x86_64)", "i386": "x86 (i386)", "i686": "x86 (i686)", "i586": "x86 (i586)", "arm64": "ARM64", "aarch64": "ARM64 (aarch64)",
        "armhf": L("ARM 32 ビット (armhf)", "ARM 32-bit (armhf)"), "armel": L("ARM 32 ビット (armel)", "ARM 32-bit (armel)"), "armv7hl": L("ARM 32 ビット (armv7hl)", "ARM 32-bit (armv7hl)"),
        "all": L("すべて（CPU に依存しない）", "All (architecture-independent)"), "noarch": L("すべて（CPU に依存しない）", "All (architecture-independent)"),
        "riscv64": "RISC-V 64", "ppc64el": "PowerPC 64 LE", "ppc64le": "PowerPC 64 LE", "s390x": "IBM Z (s390x)", "loong64": "LoongArch 64", "mips64el": "MIPS64 LE",
    ]
}

/// Debian packages (.deb / .udeb): an `ar` archive holding a control archive and a data archive.
enum Deb {
    struct Member { var name: String; var offset: Int; var size: Int }

    static func members(_ r: Reader) -> [Member]? {
        guard r.count >= 68, r.fixedStr(0, 8) == "!<arch>\n" else { return nil }
        var out = [Member]()
        var o = 8
        while r.ok(o, 60), out.count < 32 {
            var name = r.fixedStr(o, 16).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("/") { name.removeLast() }
            let size = Int(r.fixedStr(o + 48, 10).trimmingCharacters(in: .whitespaces)) ?? 0
            out.append(Member(name: name, offset: o + 60, size: Swift.min(size, r.count - o - 60)))
            o += 60 + size + (size & 1)
        }
        return out.first?.name == "debian-binary" ? out : nil
    }

    /// "Key: value" paragraphs with continuation lines.
    static func fields(_ text: String) -> [(key: String, value: String)] {
        var out = [(String, String)]()
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !out.isEmpty {
                let t = line.trimmingCharacters(in: .whitespaces)
                out[out.count - 1].1 += "\n" + (t == "." ? "" : t)
            } else if let c = line.firstIndex(of: ":") {
                out.append((String(line[..<c]), line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    static func scan(_ data: Data, _ m: Member, budget: TimeInterval?, want: @escaping (String, Int) -> Bool) -> (ArchiveScanner, complete: Bool, codec: Unpack.Codec) {
        let sc = ArchiveScanner(.tar)
        sc.want = want
        let codec = Unpack.codec(Reader(data), m.offset)
        let done = Unpack.stream(data, at: m.offset, length: m.size, codec: codec, budget: budget) { sc.feed($0) }
        return (sc, done || sc.finished, codec)
    }

    static func dataMember(_ ms: [Member]) -> Member? { ms.first { $0.name.hasPrefix("data.tar") } }

    static func icon(_ data: Data) -> CGImage? {
        guard let ms = members(Reader(data)), let dm = dataMember(ms) else { return nil }
        let (sc, _, _) = scan(data, dm, budget: 1.5, want: LinuxApp.want)
        return LinuxApp.describe(sc.kept).icon
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        let r = Reader(data)
        guard let ms = members(r) else { return nil }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        var control = [(key: String, value: String)]()
        var scripts = [(String, String)]()
        var conffiles: String?
        if let cm = ms.first(where: { $0.name.hasPrefix("control.tar") }) {
            let (sc, _, _) = scan(data, cm, budget: 5) { _, size in size < 2 << 20 }
            if let c = sc.kept["control"] { control = fields(String(decoding: c, as: UTF8.self)) }
            for n in ["preinst", "postinst", "prerm", "postrm", "config"] { if let d = sc.kept[n] { scripts.append((n, String(decoding: d, as: UTF8.self))) } }
            conffiles = sc.kept["conffiles"].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func f(_ k: String) -> String? { control.first { $0.key.caseInsensitiveCompare(k) == .orderedSame }?.value }
        let isUdeb = url.pathExtension.lowercased() == "udeb" || f("Package-Type") == "udeb"
        let kind = isUdeb ? L("Debian インストーラー用のパッケージ (udeb)", "Debian installer package (udeb)") : L("Debian パッケージ (deb)", "Debian package (deb)")

        // The files it installs.
        var payload: (ArchiveScanner, complete: Bool, codec: Unpack.Codec)?
        if !opts.light, let dm = dataMember(ms) { payload = scan(data, dm, budget: opts.deep ? 120 : Swift.max(1.0, opts.budget), want: LinuxApp.want) }
        let app = payload.map { LinuxApp.describe($0.0.kept) } ?? LinuxApp.App()

        let desc = f("Description") ?? ""
        let firstLine = desc.components(separatedBy: "\n").first ?? ""
        rep.title = app.name ?? f("Package") ?? url.lastPathComponent
        rep.subtitle = kind
        rep.icon = app.icon
        if let a = f("Architecture") { rep.badges.append(Badge(text: a, tone: .info)) }
        var sum = [Row(L("種類", "Kind"), kind)]
        sum.add(L("パッケージ名", "Package"), f("Package"), mono: true)
        sum.add(L("バージョン", "Version"), f("Version"))
        sum.add(L("アーキテクチャ", "Architecture"), f("Architecture").map { LinuxApp.archNames[$0] ?? $0 })
        sum.add(L("概要", "Summary"), firstLine)
        sum.add(L("メンテナー", "Maintainer"), f("Maintainer"))
        sum.add(L("ホームページ", "Homepage"), f("Homepage"))
        sum.add(L("分類", "Section"), f("Section"))
        sum.add(L("インストール後のサイズ", "Installed size"), f("Installed-Size").flatMap { Int($0) }.map { byteSize($0 * 1024) })
        sum.append(contentsOf: app.rows.filter { $0.key != L("メニュー項目のファイル", "Desktop entry") && $0.key != L("説明", "Comment") })
        if let p = payload { sum.append(contentsOf: LinuxApp.effects(p.0.entries)) }
        if !scripts.isEmpty { sum.add(L("インストール時に実行", "Runs on install"), scripts.map { $0.0 }.joined(separator: ", "), mono: true) }
        let codecs = Set(ms.filter { $0.name.contains(".tar") }.map { Unpack.codec(r, $0.offset).rawValue }).filter { !$0.isEmpty }.sorted()
        sum.add(L("圧縮", "Compression"), codecs.isEmpty ? L("なし", "None") : codecs.joined(separator: ", "))
        sum.add(L("パッケージ単体の署名", "Package signature"), ms.contains { $0.name.hasPrefix("_gpg") } ? L("あり (GPG)", "Present (GPG)") : L("なし（通常は入手元のリポジトリ側で署名されます）", "None (normally the repository is signed instead)"))
        if let p = payload, p.complete { sum.add(L("ファイル数", "Files"), "\(p.0.entries.filter { !$0.isDir }.count)") }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum

        var sections = [ReportSection]()
        let rest = desc.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sections.append(ReportSection(id: "description", title: L("説明", "Description"), symbol: "text.alignleft", blocks: [.text(rest)])) }
        let relKeys: [(String, String)] = [("Pre-Depends", L("先に必要", "Pre-depends")), ("Depends", L("必要", "Depends")), ("Recommends", L("推奨", "Recommends")), ("Suggests", L("提案", "Suggests")),
                                           ("Enhances", L("機能を追加する相手", "Enhances")), ("Provides", L("提供する名前", "Provides")), ("Conflicts", L("同時に入れられない", "Conflicts")),
                                           ("Breaks", L("壊す相手", "Breaks")), ("Replaces", L("置き換える相手", "Replaces"))]
        var relRows = [[String]]()
        for (k, label) in relKeys { for item in (f(k) ?? "").split(separator: ",") { relRows.append([label, item.trimmingCharacters(in: .whitespaces)]) } }
        if !relRows.isEmpty {
            sections.append(ReportSection(id: "depends", title: L("依存関係", "Dependencies"), symbol: "link",
                blocks: [.table(TableData(columns: [L("関係", "Relation"), L("パッケージ", "Package")], rows: relRows))], count: relRows.count))
        }
        if !control.isEmpty {
            sections.append(ReportSection(id: "control", title: L("パッケージ情報 (control)", "Control Fields"), symbol: "list.bullet.rectangle",
                blocks: [.rows(control.filter { $0.key != "Description" }.map { Row($0.key, $0.value, mono: true) })], count: control.count))
        }
        if let s = LinuxApp.scriptsSection(scripts) { sections.append(s) }
        if let c = conffiles, !c.isEmpty {
            sections.append(ReportSection(id: "conffiles", title: L("設定ファイル", "Configuration Files"), symbol: "gearshape", blocks: [.text(c)], count: c.components(separatedBy: "\n").count))
        }
        if let p = payload, !p.0.entries.isEmpty { sections.append(LinuxApp.filesSection(p.0.entries, total: p.0.total, complete: p.complete, deep: opts.deep)) }
        sections.append(ReportSection(id: "members", title: L("アーカイブの構成", "Archive Members"), symbol: "tray.full",
            blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: ms.map { [$0.name, byteSize($0.size)] }))], count: ms.count))
        rep.sections = sections
        return rep
    }
}

/// RPM packages: a header of tagged values (name, version, file list, scripts) followed by a compressed cpio archive.
enum RPM {
    static func isRPM(_ r: Reader) -> Bool { r.be32(0) == 0xedab_eedb }

    struct Header {
        var index: [Int: (type: Int, offset: Int, count: Int)] = [:]
        var store = Reader(Data(), little: false)
        var end = 0

        init?(_ r: Reader, at o: Int) {
            guard r.ok(o, 16), r.be32(o) & 0xffff_ff00 == 0x8ead_e800 else { return nil }
            let n = Int(r.be32(o + 8)), size = Int(r.be32(o + 12))
            guard n < 100_000, r.ok(o + 16, n * 16 + size) else { return nil }
            for i in 0..<n {
                let e = o + 16 + i * 16
                index[Int(r.be32(e))] = (Int(r.be32(e + 4)), Int(r.be32(e + 8)), Int(r.be32(e + 12)))
            }
            store = Reader(r.bytes(o + 16 + n * 16, size), little: false)
            end = o + 16 + n * 16 + size
        }

        func str(_ tag: Int) -> String? {
            guard let e = index[tag], [6, 8, 9].contains(e.type) else { return nil }
            let s = store.cstr(e.offset, max: 1 << 20)
            return s.isEmpty ? nil : s
        }
        func strs(_ tag: Int) -> [String] {
            guard let e = index[tag], [6, 8, 9].contains(e.type) else { return [] }
            var out = [String](), o = e.offset
            out.reserveCapacity(Swift.min(e.count, 100_000))
            for _ in 0..<Swift.min(e.count, 500_000) {
                guard o < store.count else { break }
                let s = store.cstr(o, max: 8192)
                out.append(s)
                o += s.utf8.count + 1
            }
            return out
        }
        func ints(_ tag: Int) -> [Int] {
            guard let e = index[tag] else { return [] }
            let n = Swift.min(e.count, 500_000)
            switch e.type {
            case 3: return (0..<n).map { Int(store.u16(e.offset + $0 * 2)) }
            case 4: return (0..<n).map { Int(store.u32(e.offset + $0 * 4)) }
            case 5: return (0..<n).map { Int(clamping: store.u64(e.offset + $0 * 8)) }
            default: return []
            }
        }
        func blob(_ tag: Int) -> Data? { index[tag].flatMap { $0.type == 7 ? store.bytes($0.offset, $0.count) : nil } }
    }

    /// Key ID and algorithms of an OpenPGP signature packet.
    static func pgp(_ d: Data) -> String? {
        let b = [UInt8](d)
        guard b.count > 8, b[0] & 0x80 != 0 else { return nil }
        var o = 1
        if b[0] & 0x40 != 0 { o += b[1] < 192 ? 1 : b[1] < 224 ? 2 : 5 } else { o += [1, 2, 4, 0][Int(b[0] & 3)] }
        guard o + 6 < b.count else { return nil }
        let version = b[o]
        var keyID: [UInt8]?, algo = 0, hash = 0
        if version == 3, o + 17 <= b.count { keyID = Array(b[(o + 7)..<(o + 15)]); algo = Int(b[o + 15]); hash = Int(b[o + 16]) }
        else if version >= 4 {
            algo = Int(b[o + 2]); hash = Int(b[o + 3])
            var p = o + 4
            for _ in 0..<2 {
                guard p + 2 <= b.count else { break }
                let len = Int(b[p]) << 8 | Int(b[p + 1])
                p += 2
                let end = Swift.min(p + len, b.count)
                var q = p
                while q < end {
                    var sl = Int(b[q]); q += 1
                    if sl >= 192, sl < 255, q < end { sl = ((sl - 192) << 8) + Int(b[q]) + 192; q += 1 }
                    else if sl == 255, q + 4 <= end { sl = Int(b[q]) << 24 | Int(b[q + 1]) << 16 | Int(b[q + 2]) << 8 | Int(b[q + 3]); q += 4 }
                    guard sl > 0, q + sl <= end else { break }
                    let type = b[q] & 0x7f
                    if type == 16, sl == 9 { keyID = Array(b[(q + 1)..<(q + 9)]) }
                    if type == 33, sl >= 21, keyID == nil { keyID = Array(b[(q + sl - 8)..<(q + sl)]) }
                    q += sl
                }
                p = end
            }
        }
        let algos = [1: "RSA", 17: "DSA", 19: "ECDSA", 22: "EdDSA"], hashes = [2: "SHA-1", 8: "SHA-256", 9: "SHA-384", 10: "SHA-512"]
        var parts = [String]()
        if let a = algos[algo] { parts.append(a) }
        if let h = hashes[hash] { parts.append(h) }
        if let k = keyID { parts.append(L("鍵 ID ", "key ID ") + k.map { String(format: "%02X", $0) }.joined()) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func parse(_ r: Reader) -> (sig: Header, main: Header)? {
        guard isRPM(r), let sig = Header(r, at: 96), let main = Header(r, at: (sig.end + 7) & ~7) else { return nil }
        return (sig, main)
    }

    static func scanPayload(_ data: Data, at start: Int, budget: TimeInterval) -> (ArchiveScanner, complete: Bool, codec: Unpack.Codec) {
        let sc = ArchiveScanner(.cpio)
        sc.want = LinuxApp.want
        let codec = Unpack.codec(Reader(data), start)
        let done = Unpack.stream(data, at: start, length: data.count - start, codec: codec, budget: budget) { sc.feed($0) }
        return (sc, done || sc.finished, codec)
    }

    static func icon(_ data: Data) -> CGImage? {
        guard let (_, main) = parse(Reader(data, little: false)) else { return nil }
        return LinuxApp.describe(scanPayload(data, at: main.end, budget: 1.5).0.kept).icon
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        let r = Reader(data, little: false)
        guard let (sig, h) = parse(r) else { return nil }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        let isSource = h.index[1106] != nil || (h.str(1044) == nil && r.be16(6) == 1)
        let kind = isSource ? L("RPM のソースパッケージ (src.rpm)", "RPM source package (src.rpm)") : L("RPM パッケージ", "RPM package")
        let name = h.str(1000) ?? "", version = h.str(1001) ?? "", release = h.str(1002) ?? ""
        let arch = isSource ? "src" : (h.str(1022) ?? "")

        // File list straight from the header (no need to unpack anything).
        let bases = h.strs(1117), dirs = h.strs(1118), dirIdx = h.ints(1116)
        var sizes = h.ints(1028)
        if sizes.isEmpty { sizes = h.ints(5008) }
        let modes = h.ints(1030), flags = h.ints(1037)
        var entries = [ArchiveScanner.Entry]()
        entries.reserveCapacity(bases.count)
        for (i, b) in bases.enumerated() {
            let dir = i < dirIdx.count && dirIdx[i] < dirs.count ? dirs[dirIdx[i]] : ""
            let mode = i < modes.count ? modes[i] : 0
            var path = dir + b
            while path.hasPrefix("/") { path.removeFirst() }
            let kindBits = mode & 0o170000
            entries.append(ArchiveScanner.Entry(name: path, size: kindBits == 0o100000 && i < sizes.count ? sizes[i] : 0, mode: mode & 0o7777, isDir: kindBits == 0o040000, link: kindBits == 0o120000 ? "" : nil))
        }
        if entries.isEmpty { for (i, p) in h.strs(1027).enumerated() { entries.append(ArchiveScanner.Entry(name: String(p.drop { $0 == "/" }), size: i < sizes.count ? sizes[i] : 0, mode: i < modes.count ? modes[i] & 0o7777 : 0, isDir: false, link: nil)) } }

        // The app's desktop entry and icon need the payload itself.
        var app = LinuxApp.App()
        if !opts.light, !isSource, entries.contains(where: { $0.name.hasSuffix(".desktop") }) {
            app = LinuxApp.describe(scanPayload(data, at: h.end, budget: opts.deep ? 60 : Swift.max(1.0, opts.budget)).0.kept)
        }

        rep.title = app.name ?? name
        rep.subtitle = kind
        rep.icon = app.icon
        if !arch.isEmpty { rep.badges.append(Badge(text: arch, tone: .info)) }
        let pgpBlob = sig.blob(1002) ?? sig.blob(1005) ?? sig.blob(268) ?? sig.blob(267)
        if pgpBlob != nil { rep.badges.append(Badge(text: L("署名あり", "Signed"), tone: .good)) }
        var sum = [Row(L("種類", "Kind"), kind)]
        sum.add(L("パッケージ名", "Package"), name, mono: true)
        let epoch = h.ints(1003).first
        sum.add(L("バージョン", "Version"), (epoch.map { "\($0):" } ?? "") + version + (release.isEmpty ? "" : "-" + release))
        sum.add(L("アーキテクチャ", "Architecture"), LinuxApp.archNames[arch] ?? arch)
        sum.add(L("概要", "Summary"), h.str(1004))
        sum.add(L("ライセンス", "License"), h.str(1014))
        sum.add(L("提供元", "Vendor"), h.str(1011))
        sum.add(L("配布元", "Distribution"), h.str(1010))
        sum.add(L("作成者", "Packager"), h.str(1015))
        sum.add("URL", h.str(1020))
        sum.add(L("分類", "Group"), h.str(1016) == "Unspecified" ? nil : h.str(1016))
        if let t = h.ints(1006).first, t > 0 { sum.add(L("ビルド日時", "Built"), dateString(Date(timeIntervalSince1970: Double(t))) + (h.str(1007).map { L("（\($0)）", " (\($0))") } ?? "")) }
        sum.add(L("元のソースパッケージ", "Source package"), h.str(1044), mono: true)
        let installed = h.ints(1009).first ?? h.ints(5009).first
        sum.add(L("インストール後のサイズ", "Installed size"), installed.map { byteSize($0) })
        sum.append(contentsOf: app.rows.filter { $0.key != L("メニュー項目のファイル", "Desktop entry") && $0.key != L("説明", "Comment") })
        if !isSource { sum.append(contentsOf: LinuxApp.effects(entries)) }
        let scriptTags: [(Int, String)] = [(1151, "pretrans"), (1023, "pre (%pre)"), (1024, "post (%post)"), (1025, "preun (%preun)"), (1026, "postun (%postun)"), (1152, "posttrans"), (1079, "verify")]
        let scripts = scriptTags.compactMap { t in h.str(t.0).map { (t.1, $0) } }
        if !scripts.isEmpty { sum.add(L("インストール時に実行", "Runs on install"), scripts.map { $0.0 }.joined(separator: ", "), mono: true) }
        let comp = h.str(1125) ?? Unpack.codec(r, h.end).rawValue
        sum.add(L("圧縮", "Compression"), comp.isEmpty ? nil : comp + (h.str(1124).map { " (\($0))" } ?? ""))
        if let b = pgpBlob { sum.add(L("署名", "Signature"), "OpenPGP" + (pgp(b).map { L("（\($0)）", " (\($0))") } ?? ""), tone: .good) }
        else { sum.add(L("署名", "Signature"), L("なし", "None")) }
        sum.add(L("ファイル数", "Files"), entries.isEmpty ? nil : "\(entries.filter { !$0.isDir }.count)")
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum

        var sections = [ReportSection]()
        if let d = h.str(1005) { sections.append(ReportSection(id: "description", title: L("説明", "Description"), symbol: "text.alignleft", blocks: [.text(d)])) }
        func relation(_ nameTag: Int, _ verTag: Int, _ flagTag: Int, _ label: String) -> [[String]] {
            let names = h.strs(nameTag), vers = h.strs(verTag), fl = h.ints(flagTag)
            return names.enumerated().compactMap { i, n in
                guard !n.hasPrefix("rpmlib(") else { return nil }
                let f = i < fl.count ? fl[i] : 0
                let op = (f & 2 != 0 ? "<" : "") + (f & 4 != 0 ? ">" : "") + (f & 8 != 0 ? "=" : "")
                let v = i < vers.count ? vers[i] : ""
                return [label, n + (v.isEmpty ? "" : " \(op) \(v)")]
            }
        }
        let rel = relation(1049, 1050, 1048, L("必要", "Requires")) + relation(5046, 5047, 5048, L("推奨", "Recommends")) + relation(1047, 1113, 1112, L("提供する名前", "Provides"))
            + relation(1054, 1055, 1053, L("同時に入れられない", "Conflicts")) + relation(1090, 1115, 1114, L("置き換える相手", "Obsoletes"))
        if !rel.isEmpty {
            sections.append(ReportSection(id: "depends", title: L("依存関係", "Dependencies"), symbol: "link",
                blocks: [.table(TableData(columns: [L("関係", "Relation"), L("名前", "Name")], rows: Array(rel.prefix(3000)), total: rel.count))], count: rel.count))
        }
        if let s = LinuxApp.scriptsSection(scripts) { sections.append(s) }
        let conf = entries.enumerated().filter { $0.offset < flags.count && flags[$0.offset] & 1 != 0 }.map { "/" + $0.element.name }
        if !conf.isEmpty { sections.append(ReportSection(id: "conffiles", title: L("設定ファイル", "Configuration Files"), symbol: "gearshape", blocks: [.text(conf.prefix(500).joined(separator: "\n"))], count: conf.count)) }
        if !entries.isEmpty { sections.append(LinuxApp.filesSection(entries, total: entries.count, complete: true, deep: opts.deep)) }
        let log = Array(zip(h.ints(1080), zip(h.strs(1081), h.strs(1082))).prefix(opts.deep ? 200 : 15))
        if !log.isEmpty {
            sections.append(ReportSection(id: "changelog", title: L("変更履歴", "Changelog"), symbol: "clock.arrow.circlepath",
                blocks: [.text(log.map { "* \(dateString(Date(timeIntervalSince1970: Double($0.0))).prefix(10)) \($0.1.0)\n\($0.1.1)" }.joined(separator: "\n\n"))]))
        }
        rep.sections = sections
        return rep
    }
}

/// Flatpak: single-file bundles (.flatpak) and the small text files that point at a repository (.flatpakref / .flatpakrepo).
enum Flatpak {
    static func keyFile(_ text: String) -> [(group: String, key: String, value: String)] {
        var out = [(String, String, String)](), group = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") { group = String(line.dropFirst().dropLast()); continue }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out.append((group, String(line[..<eq]), String(line[line.index(after: eq)...])))
        }
        return out
    }

    static let permissionNames: [String: (ja: String, en: String)] = [
        "network": ("ネットワーク", "Network"), "ipc": ("プロセス間通信 (IPC)", "IPC"), "x11": ("X11 の画面", "X11 display"), "fallback-x11": ("X11 の画面（Wayland が無いとき）", "X11 (fallback)"),
        "wayland": ("Wayland の画面", "Wayland display"), "pulseaudio": ("音の再生と録音", "Audio (PulseAudio)"), "session-bus": ("セッションバス全体", "Whole session bus"),
        "system-bus": ("システムバス全体", "Whole system bus"), "ssh-auth": ("SSH の鍵エージェント", "SSH agent"), "pcsc": ("スマートカード", "Smart cards"), "cups": ("プリンター", "Printing"),
        "gpg-agent": ("GPG の鍵エージェント", "GPG agent"), "dri": ("GPU", "GPU"), "kvm": ("仮想化 (KVM)", "Virtualisation (KVM)"), "all": ("すべてのデバイス", "All devices"), "shm": ("共有メモリー", "Shared memory"),
        "input": ("入力デバイス", "Input devices"), "usb": ("USB デバイス", "USB devices"), "home": ("ホームフォルダー全体", "Whole home folder"), "host": ("システムのファイル全体", "All host files"),
        "host-os": ("OS のファイル", "Host OS files"), "host-etc": ("/etc", "/etc"), "bluetooth": ("Bluetooth", "Bluetooth"), "devel": ("デバッグ用のシステムコール", "Development syscalls"),
        "multiarch": ("別アーキテクチャの実行", "Multi-arch"), "canbus": ("CAN バス", "CAN bus"), "per-app-dev-shm": ("アプリ専用の共有メモリー", "Per-app shared memory"),
    ]

    static func permissions(_ kv: [(group: String, key: String, value: String)]) -> [Row] {
        var rows = [Row]()
        func items(_ key: String) -> [String] { kv.first { $0.group == "Context" && $0.key == key }?.value.split(separator: ";").map(String.init).filter { !$0.isEmpty } ?? [] }
        func named(_ a: [String]) -> String? {
            a.isEmpty ? nil : a.map { v in
                let base = v.split(separator: ":").first.map(String.init) ?? v
                let ro = v.hasSuffix(":ro") ? L("（読み取りのみ）", " (read-only)") : ""
                return (permissionNames[base].map { L($0.ja, $0.en) } ?? v.replacingOccurrences(of: ":ro", with: "")) + ro
            }.joined(separator: "\n")
        }
        let shared = items("shared"), fs = items("filesystems")
        rows.add(L("ネットワークなどの共有", "Shared with the host"), named(shared), tone: shared.contains("network") ? .info : .neutral)
        rows.add(L("画面・音などの接続", "Sockets"), named(items("sockets")))
        rows.add(L("デバイス", "Devices"), named(items("devices")), tone: items("devices").contains("all") ? .warn : .neutral)
        rows.add(L("ファイルへのアクセス", "File access"), named(fs), tone: fs.contains { $0.hasPrefix("host") || $0 == "home" } ? .warn : .neutral)
        rows.add(L("その他の機能", "Features"), named(items("features")))
        let talk = kv.filter { $0.group == "Session Bus Policy" || $0.group == "System Bus Policy" }.map { "\($0.key) (\($0.value))" }
        rows.add(L("ほかのアプリやサービスとの通信 (D-Bus)", "D-Bus access"), talk.isEmpty ? nil : talk.joined(separator: "\n"), mono: true)
        return rows
    }

    /// Text files: .flatpakref / .flatpakrepo.
    static func refReport(url: URL, data: Data) -> Report? {
        guard data.count < 1 << 20, let text = String(data: data, encoding: .utf8) else { return nil }
        let isRef = text.contains("[Flatpak Ref]"), isRepo = text.contains("[Flatpak Repo]")
        guard isRef || isRepo else { return nil }
        let kv = keyFile(text)
        func v(_ k: String) -> String? { kv.first { $0.key == k }?.value }
        var rep = Report(kind: .pkg, path: url.path, title: v("Title") ?? v("Name") ?? url.lastPathComponent)
        let kind = isRef ? L("Flatpak アプリの参照ファイル", "Flatpak app reference") : L("Flatpak リポジトリの設定ファイル", "Flatpak repository file")
        rep.subtitle = kind
        rep.badges = [Badge(text: "Flatpak", tone: .info)]
        var sum = [Row(L("種類", "Kind"), kind)]
        sum.add(L("アプリ ID", "App ID"), v("Name"), mono: true)
        sum.add(L("ブランチ", "Branch"), v("Branch"))
        sum.add(L("説明", "Comment"), v("Comment") ?? v("Description"))
        sum.add(L("入手元", "Repository"), v("Url"), mono: true)
        sum.add(L("ランタイムの入手元", "Runtime repository"), v("RuntimeRepo"), mono: true)
        sum.add(L("ホームページ", "Homepage"), v("Homepage"))
        sum.add(L("ランタイムか", "Is a runtime"), v("IsRuntime") == "true" ? L("はい", "Yes") : nil)
        sum.add(L("署名の鍵", "Signing key"), v("GPGKey") != nil ? L("含まれています (GPG)", "Included (GPG)") : L("なし", "None"))
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        rep.sections = [ReportSection(id: "text", title: L("内容", "Contents"), symbol: "doc.plaintext",
                                      blocks: [.rows(kv.map { Row($0.key, $0.value.count > 200 ? String($0.value.prefix(200)) + "…" : $0.value, mono: true) })])]
        return rep
    }

    static func find(_ b: UnsafeRawBufferPointer, _ pat: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
        let end = Swift.min(to ?? b.count, b.count) - pat.count
        guard from <= end else { return nil }
        var i = from
        while i <= end {
            if b[i] == pat[0] {
                var k = 1
                while k < pat.count, b[i + k] == pat[k] { k += 1 }
                if k == pat.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// A single-file bundle is an OSTree "static delta": the head of the file carries the ref, the app's
    /// metadata (permissions included) and its icons; they are picked out by their keys.
    static func bundle(_ data: Data) -> (ref: String?, metadata: String?, appdata: Data?, icon: Data?)? {
        let scan = Swift.min(data.count, 24 << 20)
        return data.withUnsafeBytes { raw -> (String?, String?, Data?, Data?)? in
            let b = UnsafeRawBufferPointer(rebasing: raw[0..<scan])
            func cstr(_ at: Int, max: Int = 1 << 20) -> String {
                var e = at
                while e < b.count, e - at < max, b[e] != 0 { e += 1 }
                return String(decoding: UnsafeRawBufferPointer(rebasing: b[at..<e]), as: UTF8.self)
            }
            var ref: String?
            for prefix in ["app/", "runtime/"] {
                var from = 0
                while ref == nil, let at = find(b, Array(prefix.utf8), from: from, to: 1 << 20) {
                    let s = cstr(at, max: 300)
                    if s.split(separator: "/").count == 4, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }) { ref = s }
                    from = at + 1
                }
            }
            var metadata: String?
            for head in ["[Application]", "[Runtime]"] where metadata == nil { if let at = find(b, Array(head.utf8), to: 4 << 20) { metadata = cstr(at) } }
            guard ref != nil || metadata != nil else { return nil }
            var icon: Data?
            for key in ["icon-128", "icon-64"] where icon == nil {
                guard let k = find(b, Array(key.utf8)), let png = find(b, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], from: k, to: k + 64),
                      let end = find(b, [0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82], from: png, to: png + (4 << 20)) else { continue }
                icon = Data(UnsafeRawBufferPointer(rebasing: b[png..<(end + 8)]))
            }
            var appdata: Data?
            if let k = find(b, Array("appdata".utf8), to: 8 << 20), let gz = find(b, [0x1f, 0x8b, 0x08], from: k, to: k + 64) {
                appdata = Unpack.all(Data(UnsafeRawBufferPointer(rebasing: b[gz..<Swift.min(gz + (2 << 20), b.count)])), codec: .gzip, max: 8 << 20)
                    ?? { var out = Data(); Unpack.stream(Data(UnsafeRawBufferPointer(rebasing: b[gz..<Swift.min(gz + (2 << 20), b.count)])), codec: .gzip) { out.append(contentsOf: $0); return out.count < 8 << 20 }; return out.isEmpty ? nil : out }()
            }
            return (ref, metadata, appdata, icon)
        }
    }

    static func icon(_ data: Data) -> CGImage? { bundle(data)?.icon.flatMap { ImageKit.decode($0) } }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        guard let b = bundle(data) else { return nil }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        let kv = b.metadata.map { keyFile($0) } ?? []
        func v(_ g: String, _ k: String) -> String? { kv.first { $0.group == g && $0.key == k }?.value }
        let parts = b.ref?.split(separator: "/").map(String.init) ?? []
        let isRuntime = parts.first == "runtime" || kv.contains { $0.group == "Runtime" } && !kv.contains { $0.group == "Application" }
        let kind = isRuntime ? L("Flatpak のランタイム（単一ファイル）", "Flatpak runtime bundle") : L("Flatpak アプリ（単一ファイル）", "Flatpak app bundle")
        rep.subtitle = kind
        rep.badges = [Badge(text: "Flatpak", tone: .info)]
        if parts.count == 4 { rep.badges.append(Badge(text: parts[2])) }
        rep.icon = b.icon.flatMap { ImageKit.decode($0) }
        var sum = [Row(L("種類", "Kind"), kind)]
        // AppStream data: the human name, summary and version.
        if let x = b.appdata.flatMap({ XMLNode.parse($0) }), let comp = x.name == "component" ? x : x.descendants("component").first {
            func pick(_ tag: String) -> String? {
                let all = comp.all(tag)
                let ja = prefersJapanese ? all.first { $0.attrs["xml:lang"] == "ja" } : nil
                return (ja ?? all.first { $0.attrs["xml:lang"] == nil })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let n = pick("name"), !n.isEmpty { rep.title = n }
            sum.add(L("概要", "Summary"), pick("summary"))
            if let rel = comp.first("releases")?.all("release").first { sum.add(L("バージョン", "Version"), rel.attrs["version"]) }
            sum.add(L("開発者", "Developer"), pick("developer_name") ?? comp.first("developer")?.first("name")?.text)
            sum.add(L("ライセンス", "License"), pick("project_license"))
            sum.add(L("ホームページ", "Homepage"), comp.all("url").first { $0.attrs["type"] == "homepage" }?.text)
        }
        let id = v("Application", "name") ?? v("Runtime", "name") ?? (parts.count == 4 ? parts[1] : nil)
        if rep.title == url.lastPathComponent, let id { rep.title = id }
        sum.add(L("アプリ ID", "App ID"), id, mono: true)
        sum.add(L("アーキテクチャ", "Architecture"), parts.count == 4 ? LinuxApp.archNames[parts[2]] ?? parts[2] : nil)
        sum.add(L("ブランチ", "Branch"), parts.count == 4 ? parts[3] : nil)
        sum.add(L("ランタイム", "Runtime"), v("Application", "runtime") ?? v("Runtime", "runtime"), mono: true)
        sum.add("SDK", v("Application", "sdk") ?? v("Runtime", "sdk"), mono: true)
        sum.add(L("起動コマンド", "Command"), v("Application", "command"), mono: true)
        let perms = permissions(kv)
        sum.append(contentsOf: perms.filter { $0.tone != .neutral })
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        var sections = [ReportSection]()
        if !perms.isEmpty { sections.append(ReportSection(id: "permissions", title: L("サンドボックスの外に出られる範囲", "Sandbox Permissions"), symbol: "hand.raised", blocks: [.rows(perms)], count: perms.count)) }
        if let m = b.metadata { sections.append(ReportSection(id: "metadata", title: L("メタデータ", "Metadata"), symbol: "list.bullet.rectangle", blocks: [.text(m.trimmingCharacters(in: .whitespacesAndNewlines))])) }
        rep.sections = sections
        return rep
    }
}
