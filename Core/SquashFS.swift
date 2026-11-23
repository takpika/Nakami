import Foundation
import Compression
import CoreGraphics

/// Read-only SquashFS 4: the file system inside AppImage and Snap packages (and most Linux live discs).
final class SquashFS {
    struct Item { var name: String; var type: Int; var block: Int; var offset: Int; var isDir: Bool { type == 1 || type == 8 }; var isLink: Bool { type == 3 || type == 10 } }
    struct Inode {
        var type = 0, mode = 0, size = 0
        var dirBlock = 0, dirOffset = 0
        var blocksStart = 0, frag = 0xffff_ffff, fragOffset = 0
        var blockSizes: [UInt32] = []
        var target = ""
    }

    let r: Reader
    let base: Int
    var blockSize = 0, compressor = 0, inodeCount = 0, fragCount = 0, bytesUsed = 0
    var modified: Date?
    private var inodeTable = 0, dirTable = 0, fragTable = 0
    private var rootBlock = 0, rootOffset = 0
    private var metaCache: [Int: (data: Data, next: Int)] = [:]

    static let compressors = [1: "gzip", 2: "lzma", 3: "lzo", 4: "xz", 5: "lz4", 6: "zstd"]
    var compressorName: String { SquashFS.compressors[compressor] ?? "?" }
    /// False when the image uses a method that cannot be expanded here (lzo, old lzma).
    var readable: Bool { [1, 4, 5, 6].contains(compressor) }

    init?(_ data: Data, base: Int = 0) {
        r = Reader(data, little: true)
        self.base = base
        guard r.ok(base, 96), r.fixedStr(base, 4) == "hsqs", r.u16(base + 28) == 4 else { return nil }
        inodeCount = Int(r.u32(base + 4))
        let t = r.u32(base + 8)
        modified = t == 0 ? nil : Date(timeIntervalSince1970: Double(t))
        blockSize = Int(r.u32(base + 12))
        fragCount = Int(r.u32(base + 16))
        compressor = Int(r.u16(base + 20))
        let root = r.u64(base + 32)
        rootBlock = Int(root >> 16); rootOffset = Int(root & 0xffff)
        bytesUsed = Int(clamping: r.u64(base + 40))
        inodeTable = Int(clamping: r.u64(base + 64)); dirTable = Int(clamping: r.u64(base + 72)); fragTable = Int(clamping: r.u64(base + 80))
        guard blockSize >= 4096, blockSize <= 1 << 20 else { return nil }
    }

    func expand(_ d: Data, max: Int) -> Data? {
        switch compressor {
        case 1: return Inflate.zlib(d, max: max)
        case 4: return Unpack.all(d, codec: .xz, max: max)
        case 6: return Zstd.decode(d, max: max)
        case 5:
            var out = Data(count: max)
            let n = out.withUnsafeMutableBytes { dst in d.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, max, src.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_LZ4_RAW) } }
            guard n > 0 else { return nil }
            out.removeSubrange(n...)
            return out
        default: return nil
        }
    }

    private func metaBlock(_ pos: Int) -> (data: Data, next: Int)? {
        if let hit = metaCache[pos] { return hit }
        guard r.ok(base + pos, 2) else { return nil }
        let h = Int(r.u16(base + pos)), size = h & 0x7fff
        guard size > 0, r.ok(base + pos + 2, size) else { return nil }
        let raw = r.bytes(base + pos + 2, size)
        guard let d = h & 0x8000 != 0 ? raw : expand(raw, max: 8192) else { return nil }
        if metaCache.count > 4096 { metaCache.removeAll() }
        metaCache[pos] = (d, pos + 2 + size)
        return (d, pos + 2 + size)
    }

    /// `length` bytes of a metadata stream starting at (block position, offset inside the decoded block).
    private func meta(_ pos: inout Int, _ off: inout Int, _ length: Int) -> Data? {
        var out = Data()
        while out.count < length {
            guard let b = metaBlock(pos), off <= b.data.count else { return nil }
            let n = Swift.min(length - out.count, b.data.count - off)
            if n > 0 { out.append(b.data.subdata(in: (b.data.startIndex + off)..<(b.data.startIndex + off + n))) }
            off += n
            if off >= b.data.count { pos = b.next; off = 0 }
            if n == 0, out.count < length, b.data.isEmpty { return nil }
        }
        return out
    }

    func inode(_ block: Int, _ offset: Int) -> Inode? {
        var pos = inodeTable + block, off = offset
        guard let hd = meta(&pos, &off, 16) else { return nil }
        let h = Reader(hd, little: true)
        var n = Inode()
        n.type = Int(h.u16(0)); n.mode = Int(h.u16(2))
        switch n.type {
        case 1:
            guard let d = meta(&pos, &off, 16) else { return nil }
            let b = Reader(d, little: true)
            n.dirBlock = Int(b.u32(0)); n.size = Int(b.u16(8)); n.dirOffset = Int(b.u16(10))
        case 8:
            guard let d = meta(&pos, &off, 24) else { return nil }
            let b = Reader(d, little: true)
            n.size = Int(b.u32(4)); n.dirBlock = Int(b.u32(8)); n.dirOffset = Int(b.u16(18))
        case 2, 9:
            if n.type == 2 {
                guard let d = meta(&pos, &off, 16) else { return nil }
                let b = Reader(d, little: true)
                n.blocksStart = Int(b.u32(0)); n.frag = Int(b.u32(4)); n.fragOffset = Int(b.u32(8)); n.size = Int(b.u32(12))
            } else {
                guard let d = meta(&pos, &off, 40) else { return nil }
                let b = Reader(d, little: true)
                n.blocksStart = Int(clamping: b.u64(0)); n.size = Int(clamping: b.u64(8)); n.frag = Int(b.u32(28)); n.fragOffset = Int(b.u32(32))
            }
            let count = n.frag == 0xffff_ffff ? (n.size + blockSize - 1) / blockSize : n.size / blockSize
            guard count <= 1 << 22, let d = meta(&pos, &off, count * 4) else { return nil }
            let b = Reader(d, little: true)
            n.blockSizes = (0..<count).map { b.u32($0 * 4) }
        case 3, 10:
            guard let d = meta(&pos, &off, 8) else { return nil }
            let len = Int(Reader(d, little: true).u32(4))
            guard len <= 4096, let t = meta(&pos, &off, len) else { return nil }
            n.target = String(decoding: t, as: UTF8.self)
        default: break
        }
        return n
    }

    func list(_ dir: Inode, limit: Int = 50_000) -> [Item] {
        guard dir.type == 1 || dir.type == 8, dir.size > 3 else { return [] }
        var pos = dirTable + dir.dirBlock, off = dir.dirOffset
        var left = dir.size - 3
        var out = [Item]()
        while left >= 12, out.count < limit {
            guard let hd = meta(&pos, &off, 12) else { break }
            let h = Reader(hd, little: true)
            let count = Int(h.u32(0)) + 1, start = Int(h.u32(4))
            left -= 12
            guard count <= 256 else { break }
            for _ in 0..<count {
                guard left >= 8, let ed = meta(&pos, &off, 8) else { return out }
                let e = Reader(ed, little: true)
                let nameLen = Int(e.u16(6)) + 1
                guard let nd = meta(&pos, &off, nameLen) else { return out }
                left -= 8 + nameLen
                out.append(Item(name: String(decoding: nd, as: UTF8.self), type: Int(e.u16(4)), block: start, offset: Int(e.u16(0))))
            }
        }
        return out
    }

    var root: Inode? { inode(rootBlock, rootOffset) }

    /// Follows a path from the root, resolving symbolic links on the way.
    func lookup(_ path: String, depth: Int = 0) -> Inode? {
        guard depth < 8, var cur = root else { return nil }
        var walked = [String]()
        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            if part == "." { continue }
            guard let item = list(cur).first(where: { $0.name == part }), let next = inode(item.block, item.offset) else { return nil }
            if next.type == 3 || next.type == 10 {
                let rest = parts[(i + 1)...].joined(separator: "/")
                var target = next.target.hasPrefix("/") ? String(next.target.dropFirst()) : (walked + [next.target]).joined(separator: "/")
                // Normalise "a/../b".
                var norm = [String]()
                for p in target.split(separator: "/") { if p == ".." { _ = norm.popLast() } else if p != "." { norm.append(String(p)) } }
                target = norm.joined(separator: "/")
                return lookup(rest.isEmpty ? target : target + "/" + rest, depth: depth + 1)
            }
            walked.append(part)
            cur = next
        }
        return cur
    }

    func list(_ path: String = "") -> [Item] { lookup(path).map { list($0) } ?? [] }

    func read(_ n: Inode, max: Int = 16 << 20) -> Data? {
        guard n.type == 2 || n.type == 9, n.size <= max else { return nil }
        var out = Data(capacity: n.size)
        var pos = base + n.blocksStart
        for s in n.blockSizes {
            let size = Int(s & 0x00ff_ffff)
            let want = Swift.min(blockSize, n.size - out.count)
            if size == 0 { out.append(Data(count: want)); continue }
            guard r.ok(pos, size) else { return nil }
            let raw = r.bytes(pos, size)
            guard let d = s & 0x0100_0000 != 0 ? raw : expand(raw, max: blockSize) else { return nil }
            out.append(d.prefix(want))
            pos += size
        }
        if out.count < n.size, n.frag != 0xffff_ffff {
            // The tail lives in a shared fragment block.
            let ptr = Int(clamping: r.u64(base + fragTable + (n.frag / 512) * 8))
            guard let mb = metaBlock(ptr) else { return nil }
            let e = Reader(mb.data, little: true)
            let at = (n.frag % 512) * 16
            let start = Int(clamping: e.u64(at)), s = e.u32(at + 8)
            let size = Int(s & 0x00ff_ffff)
            guard r.ok(base + start, size) else { return nil }
            let raw = r.bytes(base + start, size)
            guard let d = s & 0x0100_0000 != 0 ? raw : expand(raw, max: blockSize), n.fragOffset + (n.size - out.count) <= d.count else { return nil }
            out.append(d.subdata(in: (d.startIndex + n.fragOffset)..<(d.startIndex + n.fragOffset + n.size - out.count)))
        }
        return out.count == n.size ? out : nil
    }

    func read(_ path: String, max: Int = 16 << 20) -> Data? { lookup(path).flatMap { read($0, max: max) } }

    func rootSection() -> ReportSection? {
        guard let rt = root else { return nil }
        let items = list(rt, limit: 2000)
        guard !items.isEmpty else { return nil }
        let rows = items.map { i -> [String] in
            let n = inode(i.block, i.offset)
            return [i.name + (i.isDir ? "/" : ""), i.isLink ? "→ " + (n?.target ?? "") : i.isDir ? "" : byteSize(n?.size ?? 0)]
        }
        return ReportSection(id: "root", title: L("最上位のファイル", "Top-level Files"), symbol: "folder",
                             blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: rows))], count: rows.count)
    }

    func factRows() -> [Row] {
        var rows = [Row]()
        rows.add(L("ファイルシステム", "File system"), "SquashFS 4")
        rows.add(L("圧縮", "Compression"), compressorName + L("（ブロック \(byteSize(blockSize))）", " (\(byteSize(blockSize)) blocks)", "（區塊 \(byteSize(blockSize))）"))
        rows.add(L("ファイルとフォルダーの数", "Files and folders"), "\(inodeCount)")
        if let m = modified { rows.add(L("作成日時", "Created"), dateString(m)) }
        if !readable { rows.add(L("中身の読み取り", "Reading the contents"), L("\(compressorName) 圧縮の展開には対応していないため、中のファイルは読めません", "\(compressorName) compression is not supported here, so files inside are not read", "此處不支援 \(compressorName) 壓縮，因此無法讀取其中的檔案"), tone: .warn) }
        return rows
    }
}

/// A tiny reader for the YAML that packages actually use (nested maps, lists, plain scalars).
indirect enum MiniYAML {
    case scalar(String)
    case map([(String, MiniYAML)])
    case list([MiniYAML])

    subscript(_ k: String) -> MiniYAML? {
        if case .map(let m) = self { return m.first { $0.0 == k }?.1 }
        return nil
    }
    var string: String? { if case .scalar(let s) = self { return s.isEmpty ? nil : s }; return nil }
    var keys: [String] { if case .map(let m) = self { return m.map { $0.0 } }; return [] }
    var strings: [String] {
        switch self {
        case .list(let l): return l.compactMap { $0.string }
        case .scalar(let s): return s.isEmpty ? [] : [s]
        case .map(let m): return m.map { $0.0 }
        }
    }

    static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if let hash = v.range(of: " #"), !v.hasPrefix("\""), !v.hasPrefix("'") { v = v[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) { v = String(v.dropFirst().dropLast()) }
        return v
    }

    static func parse(_ text: String) -> MiniYAML {
        let lines: [(indent: Int, text: String)] = text.components(separatedBy: "\n").compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t == "---" { return nil }
            return (raw.prefix { $0 == " " }.count, t)
        }
        var i = 0
        func value(_ rest: String, _ indent: Int) -> MiniYAML {
            let v = rest.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("[") && v.hasSuffix("]") { return .list(v.dropFirst().dropLast().split(separator: ",").map { .scalar(unquote(String($0))) }) }
            if v == "|" || v == ">" || v == "|-" || v == ">-" || v == "|+" {
                var parts = [String]()
                while i < lines.count, lines[i].indent > indent { parts.append(lines[i].text); i += 1 }
                return .scalar(parts.joined(separator: v.hasPrefix(">") ? " " : "\n"))
            }
            if v.isEmpty {
                if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && lines[i].text.hasPrefix("- ")) { return block(lines[i].indent) }
                return .scalar("")
            }
            return .scalar(unquote(v))
        }
        func block(_ indent: Int) -> MiniYAML {
            if i < lines.count, lines[i].text.hasPrefix("-") {
                var items = [MiniYAML]()
                while i < lines.count, lines[i].indent == indent, lines[i].text.hasPrefix("-") {
                    let rest = String(lines[i].text.dropFirst()).trimmingCharacters(in: .whitespaces)
                    i += 1
                    if let c = rest.range(of: ": "), !rest.hasPrefix("\"") {
                        // "- key: value" starts a map item; its other keys follow, indented.
                        var m: [(String, MiniYAML)] = [(String(rest[..<c.lowerBound]), .scalar(unquote(String(rest[c.upperBound...]))))]
                        if i < lines.count, lines[i].indent > indent, case .map(let more) = block(lines[i].indent) { m += more }
                        items.append(.map(m))
                    } else { items.append(.scalar(unquote(rest))) }
                }
                return .list(items)
            }
            var m = [(String, MiniYAML)]()
            while i < lines.count, lines[i].indent == indent {
                let t = lines[i].text
                guard let c = t.range(of: ":") else { i += 1; continue }
                let key = unquote(String(t[..<c.lowerBound]))
                i += 1
                m.append((key, value(String(t[c.upperBound...]), indent)))
            }
            // Skip anything indented deeper than expected.
            while i < lines.count, lines[i].indent > indent { i += 1 }
            return .map(m)
        }
        return lines.isEmpty ? .map([]) : block(lines[0].indent)
    }
}

/// AppImage: an ELF launcher with a SquashFS image of the whole app appended to it.
enum AppImage {
    /// Offset of the appended image (type 2), or nil for ordinary ELF files.
    static func imageOffset(_ data: Data) -> Int? {
        let r0 = Reader(data, little: true)
        guard data.count > 0x1000, r0.u8(8) == 0x41, r0.u8(9) == 0x49, r0.u8(10) == 2 else { return nil }
        var r = r0
        r.little = r.u8(5) != 2
        let is64 = r.u8(4) == 2
        let shoff = is64 ? Int(clamping: r.u64(40)) : Int(r.u32(32))
        let end = shoff + Int(r.u16(is64 ? 58 : 46)) * Int(r.u16(is64 ? 60 : 48))
        var o = end
        while o < Swift.min(end + 4096, data.count - 4) {
            if r.fixedStr(o, 4) == "hsqs" { return o }
            o += 1
        }
        return nil
    }

    static func kept(_ fs: SquashFS) -> [String: Data] {
        var kept = [String: Data]()
        guard let root = fs.root else { return kept }
        var iconName: String?
        for i in fs.list(root, limit: 500) where i.name.hasSuffix(".desktop") {
            if let d = fs.read(i.name, max: 256 << 10) { kept[i.name] = d; iconName = LinuxApp.desktop(String(decoding: d, as: UTF8.self))["Icon"] }
        }
        if let n = iconName {
            for size in ["256x256", "512x512", "128x128", "64x64", "48x48"] {
                let p = "usr/share/icons/hicolor/\(size)/apps/\(n).png"
                if let d = fs.read(p, max: 3 << 20) { kept[p] = d; break }
            }
            if let d = fs.read(n + ".png", max: 3 << 20) { kept[n + ".png"] = d }
        }
        if kept.keys.allSatisfy({ !$0.hasSuffix(".png") }), let d = fs.read(".DirIcon", max: 3 << 20) { kept[".DirIcon"] = d }
        return kept
    }

    static func icon(_ data: Data) -> CGImage? {
        guard let o = imageOffset(data), let fs = SquashFS(data, base: o) else { return nil }
        return LinuxApp.describe(kept(fs)).icon
    }

    /// Turns the ELF report of the launcher into a report about the app it carries.
    static func augment(_ rep: inout Report, data: Data) {
        let r = Reader(data, little: true)
        guard r.u8(8) == 0x41, r.u8(9) == 0x49, r.u8(10) == 1 || r.u8(10) == 2 else { return }
        let type = Int(r.u8(10))
        let kind = "AppImage" + L("（Linux のアプリを 1 ファイルにまとめたもの）", " (a Linux app in a single file)")
        rep.badges.insert(Badge(text: "AppImage", tone: .info), at: 0)
        var rows = [Row(L("種類", "Kind"), kind), Row(L("AppImage の形式", "AppImage type"), "type \(type)" + (type == 1 ? " (ISO 9660)" : " (SquashFS)"))]
        var sections = [ReportSection]()
        if let o = imageOffset(data), let fs = SquashFS(data, base: o) {
            let files = kept(fs)
            let app = LinuxApp.describe(files)
            if let n = app.name { rep.title = n }
            if let i = app.icon { rep.icon = i }
            rows.append(contentsOf: app.rows)
            if let d = files.first(where: { $0.key.hasSuffix(".desktop") })?.value {
                let e = LinuxApp.desktop(String(decoding: d, as: UTF8.self))
                rows.add(L("バージョン", "Version"), e["X-AppImage-Version"])
            }
            rows.add(L("起動用のランチャー", "Launcher"), byteSize(o) + L("（残りがアプリ本体のイメージ）", " (the rest is the app image)"))
            rows.append(contentsOf: fs.factRows())
            if let s = fs.rootSection() { sections.append(s) }
        }
        rep.subtitle = "AppImage · " + rep.subtitle
        rep.summary = rows + rep.summary.filter { $0.key != L("種類", "Kind") }
        rep.sections = sections + rep.sections
    }
}

/// Snap packages and plain SquashFS images.
enum Snap {
    static func isSquash(_ r: Reader) -> Bool { r.fixedStr(0, 4) == "hsqs" }

    static func icon(_ data: Data) -> CGImage? {
        guard let fs = SquashFS(data), fs.readable else { return nil }
        if let d = fs.read("meta/gui/icon.png", max: 4 << 20) { return ImageKit.decode(d) }
        for i in fs.list("meta/gui") where i.name.hasSuffix(".png") { if let d = fs.read("meta/gui/" + i.name, max: 4 << 20), let img = ImageKit.decode(d) { return img } }
        return nil
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        guard let fs = SquashFS(data) else { return nil }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        var sections = [ReportSection]()
        var sum = [Row]()
        if fs.readable, let yd = fs.read("meta/snap.yaml", max: 1 << 20) {
            let text = String(decoding: yd, as: UTF8.self)
            let y = MiniYAML.parse(text)
            let kind = L("Snap パッケージ", "Snap package")
            rep.subtitle = kind
            rep.badges = [Badge(text: "Snap", tone: .info)]
            rep.title = y["title"]?.string ?? y["name"]?.string ?? url.lastPathComponent
            rep.icon = icon(data)
            sum = [Row(L("種類", "Kind"), kind)]
            sum.add(L("パッケージ名", "Package"), y["name"]?.string, mono: true)
            sum.add(L("バージョン", "Version"), y["version"]?.string)
            sum.add(L("概要", "Summary"), y["summary"]?.string)
            sum.add(L("アーキテクチャ", "Architecture"), y["architectures"]?.strings.map { LinuxApp.archNames[$0] ?? $0 }.joined(separator: ", "))
            let type = y["type"]?.string
            sum.add(L("パッケージの種類", "Snap type"), type.map { ["app": L("アプリ", "App"), "base": L("土台 (base)", "Base"), "core": L("土台 (core)", "Core"), "gadget": L("機器の設定 (gadget)", "Gadget"),
                                                                    "kernel": L("カーネル", "Kernel"), "snapd": "snapd"][$0] ?? $0 })
            sum.add(L("土台にする Snap", "Base"), y["base"]?.string, mono: true)
            if let c = y["confinement"]?.string {
                let name = ["strict": L("あり（strict）", "Strict"), "classic": L("なし（classic。システム全体に触れられます）", "None (classic: full access to the system)"),
                            "devmode": L("開発用（devmode。制限は記録されるだけ）", "Developer mode (violations are only logged)")][c] ?? c
                sum.add(L("サンドボックス", "Confinement"), name, tone: c == "strict" ? .good : .warn)
            }
            sum.add(L("公開の段階", "Grade"), y["grade"]?.string)
            sum.add(L("ライセンス", "License"), y["license"]?.string)
            // Apps (commands) and what each may reach.
            var appRows = [[String]]()
            var plugs = Set<String>()
            if case .map(let apps)? = y["apps"] {
                for (name, a) in apps {
                    let p = a["plugs"]?.strings ?? []
                    plugs.formUnion(p)
                    appRows.append([name, a["command"]?.string ?? "", a["daemon"]?.string ?? "", p.joined(separator: ", ")])
                }
            }
            plugs.formUnion(y["plugs"]?.keys ?? [])
            sum.add(L("入るコマンド", "Commands"), appRows.filter { $0[2].isEmpty }.map { $0[0] }.joined(separator: ", "), mono: true)
            sum.add(L("常駐サービス", "Services"), appRows.filter { !$0[2].isEmpty }.map { $0[0] }.joined(separator: ", "), mono: true)
            sum.add(L("使える機能 (plugs)", "Interfaces (plugs)"), plugs.sorted().joined(separator: ", "), mono: true)
            let hooks = fs.list("meta/hooks").map { $0.name }
            sum.add(L("インストール時などに実行", "Hooks"), hooks.joined(separator: ", "), mono: true)
            if let d = y["description"]?.string { sections.append(ReportSection(id: "description", title: L("説明", "Description"), symbol: "text.alignleft", blocks: [.text(d)])) }
            if !appRows.isEmpty {
                sections.append(ReportSection(id: "apps", title: L("アプリとサービス", "Apps and Services"), symbol: "app.badge",
                    blocks: [.table(TableData(columns: [L("名前", "Name"), L("コマンド", "Command"), L("常駐の種類", "Daemon"), L("使える機能", "Plugs")], rows: appRows))], count: appRows.count))
            }
            sections.append(ReportSection(id: "yaml", title: "snap.yaml", symbol: "doc.text", blocks: [.text(text.trimmingCharacters(in: .whitespacesAndNewlines))]))
        } else {
            let kind = L("SquashFS イメージ（読み取り専用の圧縮ファイルシステム）", "SquashFS image (compressed read-only file system)")
            rep.subtitle = kind
            sum = [Row(L("種類", "Kind"), kind)]
            // A Linux system image says which distribution it is.
            if fs.readable, let d = fs.read("etc/os-release", max: 64 << 10) ?? fs.read("usr/lib/os-release", max: 64 << 10) {
                let text = String(decoding: d, as: UTF8.self)
                if let n = firstMatch(text, #"PRETTY_NAME="?([^"\n]+)"#) { rep.title = n; sum.add(L("中のシステム", "System inside"), n) }
            }
        }
        sum.append(contentsOf: fs.factRows().filter { $0.key != L("ファイルシステム", "File system") || rep.badges.isEmpty == false })
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        if fs.readable, let s = fs.rootSection() { sections.append(s) }
        rep.sections = sections
        return rep
    }
}
