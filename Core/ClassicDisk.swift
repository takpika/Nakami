import Foundation
import CoreGraphics

/// A file on a classic Mac volume: both forks plus the Finder's type and creator codes.
struct ClassicFile {
    var path: String
    var type: String, creator: String
    var dataSize: Int, resourceSize: Int
    var created: Date?, modified: Date?
}

protocol ClassicVolume: MacVolume {
    var bootable: Bool { get }
    /// Every file on the volume (bounded).
    var files: [ClassicFile] { get }
    func resourceFork(_ path: String, max: Int) -> Data?
}

/// Read-only HFS ("Mac OS Standard"): the file system of classic Mac hard disks, CDs and 800K / 1.4MB floppies.
final class HFSClassic: ClassicVolume {
    struct Node { var name: String; var isDir: Bool; var id: UInt32; var parent: UInt32; var type = ""; var creator = ""
                  var dataLen = 0; var rsrcLen = 0; var created: Date?; var modified: Date?; var dataExt: [(Int, Int)] = []; var rsrcExt: [(Int, Int)] = [] }

    let dev: BlockDevice
    var volumeName = ""
    var fileCount = 0, folderCount = 0
    var created: Date?
    var totalBytes = 0
    var bootable = false
    private var blockSize = 512, firstBlock = 0
    private var byParent: [UInt32: [Node]] = [:]
    private var overflow: [String: [(start: Int, ext: [(Int, Int)])]] = [:]
    private(set) var files: [ClassicFile] = []

    init?(_ device: BlockDevice) {
        dev = device
        guard let m = device.reader(1024, 162), m.fixedStr(0, 2) == "BD" else { return nil }
        blockSize = Int(m.u32(20)); firstBlock = Int(m.u16(28)) * 512
        guard blockSize >= 512, blockSize % 512 == 0, blockSize <= 1 << 22 else { return nil }
        created = ClassicMac.date(m.u32(2))
        volumeName = ClassicMac.pstring(m, 36, max: 27)
        fileCount = Int(m.u32(84)); folderCount = Int(m.u32(88))
        totalBytes = Int(m.u16(18)) * blockSize
        bootable = device.string(0, 2) == "LK"
        func ext(_ o: Int) -> [(Int, Int)] { (0..<3).map { (Int(m.u16(o + $0 * 4)), Int(m.u16(o + $0 * 4 + 2))) }.filter { $0.1 > 0 } }
        // Extents overflow tree first: long or fragmented files (the catalog included) continue there.
        let xt = ext(134)
        loadOverflow(extents: xt, size: Int(m.u32(130)))
        var cat = ext(150)
        cat += more(4, fork: 0, after: cat.reduce(0) { $0 + $1.1 })
        loadCatalog(extents: cat, size: Int(m.u32(146)))
        guard !byParent.isEmpty else { return nil }
    }

    private func read(_ extents: [(Int, Int)], _ offset: Int, _ length: Int) -> Data? {
        var out = Data(capacity: length)
        var pos = 0
        for e in extents {
            if out.count >= length { break }
            let bytes = e.1 * blockSize
            let start = offset + out.count
            if start < pos + bytes {
                let inExt = start - pos
                let n = Swift.min(bytes - inExt, length - out.count)
                guard let d = dev.read(firstBlock + e.0 * blockSize + inExt, n) else { return nil }
                out.append(d)
            }
            pos += bytes
        }
        return out.count == length ? out : nil
    }

    /// Walks the leaf nodes of a B-tree file, handing each record (node bytes, key offset, data offset) to `visit`.
    private func leaves(_ extents: [(Int, Int)], size: Int, _ visit: (Reader, Int, Int) -> Void) {
        guard let head = read(extents, 0, 512) else { return }
        var n = Int(Reader(head, little: false).u32(24))
        var seen = 0
        let nodes = size / 512
        while n != 0, n < nodes, seen < 400_000 {
            guard let d = read(extents, n * 512, 512) else { break }
            let r = Reader(d, little: false)
            seen += 1
            if r.u8(8) == 0xff {
                for i in 0..<Swift.min(Int(r.u16(10)), 100) {
                    let o = Int(r.u16(510 - i * 2))
                    guard o >= 14, o < 508 else { continue }
                    let keyLen = Int(r.u8(o))
                    guard keyLen > 0 else { continue }
                    visit(r, o, (o + 1 + keyLen + 1) & ~1)
                }
            }
            let next = Int(r.u32(0))
            if next == n { break }
            n = next
        }
    }

    private func loadOverflow(extents: [(Int, Int)], size: Int) {
        guard !extents.isEmpty, size >= 1024 else { return }
        leaves(extents, size: size) { r, k, d in
            guard r.u8(k) >= 7 else { return }
            let key = "\(r.u32(k + 2)):\(r.u8(k + 1))"
            let ext = (0..<3).map { (Int(r.u16(d + $0 * 4)), Int(r.u16(d + $0 * 4 + 2))) }.filter { $0.1 > 0 }
            overflow[key, default: []].append((Int(r.u16(k + 6)), ext))
        }
    }

    private func more(_ id: UInt32, fork: UInt8, after blocks: Int) -> [(Int, Int)] {
        guard let recs = overflow["\(id):\(fork)"] else { return [] }
        return recs.sorted { $0.start < $1.start }.flatMap { $0.ext }
    }

    private func loadCatalog(extents: [(Int, Int)], size: Int) {
        var total = 0
        leaves(extents, size: size) { r, k, d in
            guard total < 300_000, r.u8(k) >= 6 else { return }
            let parent = r.u32(k + 2)
            let name = ClassicMac.pstring(r, k + 6, max: 31)
            let type = r.u8(d)
            if type == 1 {
                total += 1
                byParent[parent, default: []].append(Node(name: name, isDir: true, id: r.u32(d + 6), parent: parent, created: ClassicMac.date(r.u32(d + 10)), modified: ClassicMac.date(r.u32(d + 14))))
            } else if type == 2 {
                total += 1
                var n = Node(name: name, isDir: false, id: r.u32(d + 20), parent: parent, type: ClassicMac.code(r, d + 4), creator: ClassicMac.code(r, d + 8))
                n.dataLen = Int(r.u32(d + 26)); n.rsrcLen = Int(r.u32(d + 36))
                n.created = ClassicMac.date(r.u32(d + 44)); n.modified = ClassicMac.date(r.u32(d + 48))
                n.dataExt = (0..<3).map { (Int(r.u16(d + 74 + $0 * 4)), Int(r.u16(d + 76 + $0 * 4))) }.filter { $0.1 > 0 }
                n.rsrcExt = (0..<3).map { (Int(r.u16(d + 86 + $0 * 4)), Int(r.u16(d + 88 + $0 * 4))) }.filter { $0.1 > 0 }
                byParent[parent, default: []].append(n)
            }
        }
        // Paths for every file, walking down from the root folder (ID 2).
        var queue: [(UInt32, String)] = [(2, "")]
        var visited = 0
        while !queue.isEmpty, visited < 100_000, files.count < 200_000 {
            let (id, prefix) = queue.removeFirst()
            visited += 1
            for n in byParent[id] ?? [] {
                let p = prefix.isEmpty ? n.name : prefix + "/" + n.name
                if n.isDir { queue.append((n.id, p)) }
                else { files.append(ClassicFile(path: p, type: n.type, creator: n.creator, dataSize: n.dataLen, resourceSize: n.rsrcLen, created: n.created, modified: n.modified)) }
            }
        }
    }

    private func find(_ path: String) -> Node? {
        var cur = Node(name: "", isDir: true, id: 2, parent: 1)
        for part in path.split(separator: "/") {
            guard cur.isDir, let next = byParent[cur.id]?.first(where: { $0.name == part }) ?? byParent[cur.id]?.first(where: { $0.name.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            cur = next
        }
        return cur
    }

    private func fork(_ n: Node, resource: Bool, max: Int) -> Data? {
        let len = resource ? n.rsrcLen : n.dataLen
        guard len <= max else { return nil }
        var ext = resource ? n.rsrcExt : n.dataExt
        if ext.reduce(0, { $0 + $1.1 }) * blockSize < len { ext += more(n.id, fork: resource ? 0xff : 0, after: 0) }
        return read(ext, 0, len)
    }

    func entries(_ path: String) -> [VolEntry] {
        guard let d = find(path), d.isDir else { return [] }
        return (byParent[d.id] ?? []).map { VolEntry(name: $0.name, isDir: $0.isDir, size: $0.dataLen + $0.rsrcLen) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func data(_ path: String, max: Int) -> Data? { find(path).flatMap { $0.isDir ? nil : fork($0, resource: false, max: max) } }
    func resourceFork(_ path: String, max: Int) -> Data? { find(path).flatMap { $0.isDir ? nil : fork($0, resource: true, max: max) } }
    func device(_ path: String) -> BlockDevice? { nil }
    func tree(under path: String, limit: Int) -> [VolFile] { [] }
}

/// MFS, the flat file system of the first Macintosh (400K floppies): no real folders, one directory.
final class MFSVolume: ClassicVolume {
    struct Item { var name: String; var type: String; var creator: String; var dataStart: Int; var dataLen: Int; var rsrcStart: Int; var rsrcLen: Int; var created: Date?; var modified: Date? }
    let dev: BlockDevice
    var volumeName = ""
    var fileCount = 0
    var folderCount = 0
    var created: Date?
    var totalBytes = 0
    var bootable = false
    private var blockSize = 1024, firstBlock = 0
    private var items: [Item] = []
    private var map: [UInt8] = []
    var files: [ClassicFile] { items.map { ClassicFile(path: $0.name, type: $0.type, creator: $0.creator, dataSize: $0.dataLen, resourceSize: $0.rsrcLen, created: $0.created, modified: $0.modified) } }

    init?(_ device: BlockDevice) {
        dev = device
        guard let m = device.reader(1024, 64), m.u16(0) == 0xd2d7 else { return nil }
        created = ClassicMac.date(m.u32(2))
        fileCount = Int(m.u16(12))
        let dirStart = Int(m.u16(14)), dirLen = Int(m.u16(16)), blocks = Int(m.u16(18))
        blockSize = Int(m.u32(20)); firstBlock = Int(m.u16(28)) * 512
        guard blockSize >= 512, blockSize <= 1 << 20, dirLen > 0, dirLen < 4096 else { return nil }
        volumeName = ClassicMac.pstring(m, 36, max: 27)
        totalBytes = blocks * blockSize
        bootable = device.string(0, 2) == "LK"
        map = device.read(1024 + 64, (blocks * 3 + 1) / 2 + 2).map { [UInt8]($0) } ?? []
        for b in 0..<dirLen {
            guard let d = device.reader((dirStart + b) * 512, 512) else { break }
            var o = 0
            while o + 51 <= 512, d.u8(o) & 0x80 != 0, items.count < 5000 {
                let nameLen = Int(d.u8(o + 50))
                items.append(Item(name: ClassicMac.pstring(d, o + 50), type: ClassicMac.code(d, o + 2), creator: ClassicMac.code(d, o + 6),
                                  dataStart: Int(d.u16(o + 22)), dataLen: Int(d.u32(o + 24)), rsrcStart: Int(d.u16(o + 32)), rsrcLen: Int(d.u32(o + 34)),
                                  created: ClassicMac.date(d.u32(o + 42)), modified: ClassicMac.date(d.u32(o + 46))))
                o += (51 + nameLen + 1) & ~1
            }
        }
        guard !items.isEmpty || fileCount == 0 else { return nil }
    }

    /// The allocation map packs one 12-bit "next block" number per block, starting at block 2.
    private func next(_ block: Int) -> Int {
        let i = (block - 2) * 3 / 2
        guard block >= 2, i + 1 < map.count else { return 1 }
        return (block - 2) % 2 == 0 ? Int(map[i]) << 4 | Int(map[i + 1]) >> 4 : (Int(map[i]) & 0xf) << 8 | Int(map[i + 1])
    }

    private func chain(_ start: Int, _ length: Int, max: Int) -> Data? {
        guard length <= max else { return nil }
        var out = Data(capacity: length)
        var b = start, hops = 0
        while out.count < length, b >= 2, hops < 65536 {
            guard let d = dev.read(firstBlock + (b - 2) * blockSize, Swift.min(blockSize, length - out.count)) else { return nil }
            out.append(d)
            b = next(b); hops += 1
        }
        return out.count == length ? out : nil
    }

    func entries(_ path: String) -> [VolEntry] { path.isEmpty ? items.map { VolEntry(name: $0.name, isDir: false, size: $0.dataLen + $0.rsrcLen) } : [] }
    func data(_ path: String, max: Int) -> Data? { items.first { $0.name == path }.flatMap { chain($0.dataStart, $0.dataLen, max: max) } }
    func resourceFork(_ path: String, max: Int) -> Data? { items.first { $0.name == path }.flatMap { chain($0.rsrcStart, $0.rsrcLen, max: max) } }
    func device(_ path: String) -> BlockDevice? { nil }
    func tree(under path: String, limit: Int) -> [VolFile] { [] }
}

extension DiskImage {
    /// Apple's Disk Copy 4.2 image: an 84-byte header in front of the raw disk.
    static func diskCopy42(_ dev: BlockDevice) -> (device: BlockDevice, name: String, format: String)? {
        guard dev.size > 84 + 1024, let h = dev.reader(0, 84), h.u16(82) == 0x0100, h.u8(0) <= 63 else { return nil }
        let dataSize = Int(h.u32(64)), tagSize = Int(h.u32(68))
        guard dataSize > 0, dataSize % 512 == 0, 84 + dataSize + tagSize <= dev.size + 512, dataSize <= dev.size else { return nil }
        let format = [0: "400K", 1: "800K", 2: "720K", 3: "1440K"][Int(h.u8(80))] ?? ""
        return (SubDevice(parent: dev, base: 84, size: Swift.min(dataSize, dev.size - 84)), ClassicMac.pstring(h, 0), format)
    }

    /// What a classic Mac volume holds: a system to boot from, applications, or plain documents.
    static func inspectClassic(_ vol: ClassicVolume, deadline: Date = Date().addingTimeInterval(1.2)) -> Found {
        var f = Found()
        let files = vol.files
        // The System file names the system version; the Finder sits next to it.
        var systemVersion: String?, finderVersion: String?, systemFolder: String?
        var systemIcon: CGImage?
        var finderResources: ClassicMac.Resources?
        // The real System file sits next to the Finder; installer discs also carry loose system parts elsewhere.
        func folder(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
        let finderFolders = Set(files.filter { $0.type == "FNDR" && $0.creator == "MACS" }.map { folder($0.path) })
        let systems = files.filter { ($0.type == "ZSYS" || $0.type == "zsys") && $0.creator == "MACS" }.sorted { $0.path.count < $1.path.count }
        var japanese = false
        if let sys = systems.first(where: { finderFolders.contains(folder($0.path)) }) ?? systems.first ?? files.first(where: { $0.type == "zsys" }) {
            systemFolder = (sys.path as NSString).deletingLastPathComponent
            if let rf = vol.resourceFork(sys.path, max: 24 << 20), let res = ClassicMac.Resources(rf) {
                systemVersion = res.get("vers", 1).flatMap { ClassicMac.version($0)?.short } ?? res.get("vers", 2).flatMap { ClassicMac.version($0)?.short }
                // Before 'vers' existed (System 6 and earlier) the version is a string resource.
                if systemVersion == nil, let s = res.get("STR ", 0) { systemVersion = firstMatch(ClassicMac.pstring(Reader(s, little: false), 0), #"(\d+\.\d+(?:\.\d+)?)"#) }
                // Localised systems prefix the number ("J1-7.5.3" for the Japanese one).
                if let v = systemVersion, let n = firstMatch(v, #"^[A-Z]\d*-(\d+\.\d+(?:\.\d+)?.*)$"#) { japanese = v.hasPrefix("J"); systemVersion = n }
            }
            if let fn = files.first(where: { $0.type == "FNDR" && ($0.path as NSString).deletingLastPathComponent == systemFolder }),
               let rf = vol.resourceFork(fn.path, max: 8 << 20), let res = ClassicMac.Resources(rf) {
                finderVersion = res.get("vers", 1).flatMap { ClassicMac.version($0)?.short }.map { firstMatch($0, #"^[A-Z]\d*-(.+)$"#) ?? $0 }
                finderResources = res
            }
            // A startup disk is shown with the Finder's own icon. From System 7 on it is kept in the System
            // file (the little Macintosh, ID 3); earlier systems keep it in the Finder itself.
            if let rf = vol.resourceFork(sys.path, max: 24 << 20), let res = ClassicMac.Resources(rf) {
                for id in [3, -16482, -16483] where systemIcon == nil { systemIcon = ClassicMac.icon(res, id: id) }
            }
            if systemIcon == nil, let res = finderResources { systemIcon = ClassicMac.bundleIcon(res, type: "FNDR") }
        }
        func systemName(_ v: String) -> String {
            let major = Int(v.split(separator: ".").first ?? "") ?? 0
            let minor = Int(v.split(separator: ".").dropFirst().first?.prefix { $0.isNumber } ?? "") ?? 0
            if major > 7 || (major == 7 && minor >= 6) { return "Mac OS " + v }
            // The Japanese system was sold as 漢字Talk until Mac OS 7.6.
            return (japanese ? "漢字Talk " : "System ") + v
        }
        if let v = systemVersion {
            f.title = systemName(v)
            f.kind = vol.bootable ? L("Classic Mac OS の起動ディスク", "Classic Mac OS startup disk") : L("Classic Mac OS のシステムが入ったディスク", "Disk with a Classic Mac OS system")
        } else if systemFolder != nil {
            f.kind = vol.bootable ? L("Classic Mac OS の起動ディスク", "Classic Mac OS startup disk") : L("Classic Mac OS のディスク", "Classic Mac OS disk")
        } else {
            f.kind = L("Classic Mac OS のディスク", "Classic Mac OS disk")
        }
        f.badges.append(Badge(text: "Classic Mac OS", tone: .info))
        f.rows.add(L("システム", "System"), systemVersion.map { systemName($0) })
        f.rows.add(L("Finder", "Finder"), finderVersion)
        f.rows.add(L("システムフォルダー", "System folder"), systemFolder, mono: true)
        f.rows.add(L("起動", "Startup"), vol.bootable ? L("起動できます（ブートブロックあり）", "Bootable (has boot blocks)") : nil)
        f.rows.add(L("ファイルシステム", "File system"), vol is MFSVolume ? L("MFS（フォルダーのない初期の形式）", "MFS (the original flat format)") : "HFS (Mac OS Standard)")

        // Applications: version and CPU of each, as far as time allows.
        let apps = files.filter { $0.type == "APPL" }
        var appRows = [[String]]()
        var firstIcon: CGImage?
        for a in apps.prefix(300) {
            var version = "", cpu = ""
            if Date() < deadline, a.resourceSize > 0, a.resourceSize < 8 << 20, let rf = vol.resourceFork(a.path, max: 8 << 20), let res = ClassicMac.Resources(rf) {
                version = res.get("vers", 1).flatMap { ClassicMac.version($0)?.short } ?? ""
                let head = a.dataSize > 40 ? vol.data(a.path, max: 16 << 20) : nil
                cpu = ClassicMac.architecture(res: res, data: head).name
                if firstIcon == nil { firstIcon = ClassicMac.bundleIcon(res, type: "APPL") }
            }
            appRows.append([a.path, version, cpu, a.creator, byteSize(a.dataSize + a.resourceSize)])
        }
        if !apps.isEmpty {
            f.rows.add(L("アプリケーション", "Applications"), "\(apps.count)" + L(" 個", "") + (apps.count <= 4 ? L("（\(apps.map { ($0.path as NSString).lastPathComponent }.joined(separator: "、"))）", " (\(apps.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")))") : ""))
            f.sections.append(ReportSection(id: "apps", title: L("アプリケーション", "Applications"), symbol: "app",
                blocks: [.table(TableData(columns: [L("場所", "Path"), L("バージョン", "Version"), "CPU", L("クリエーター", "Creator"), L("サイズ", "Size")], rows: appRows, total: apps.count))], count: apps.count))
        }
        // One application and no system: the disk is that program's.
        if systemVersion == nil, apps.count == 1, let a = apps.first {
            f.title = (a.path as NSString).lastPathComponent
            f.kind = L("Classic Mac OS のアプリケーションのディスク", "Classic Mac OS application disk")
        }
        // Volume icon (a custom one, else the lone application's).
        if let rf = vol.resourceFork("Icon\r", max: 2 << 20), let res = ClassicMac.Resources(rf), let img = ClassicMac.icon(res, id: -16455) ?? ClassicMac.icon(res) { f.icon = img }
        else if let i = systemIcon { f.icon = i }
        else if apps.count <= 3 || systemVersion == nil { f.icon = firstIcon }
        let exts = files.filter { $0.type == "INIT" }.count, cdevs = files.filter { $0.type == "cdev" }.count
        f.rows.add(L("機能拡張とコントロールパネル", "Extensions and control panels"), exts + cdevs > 0 ? L("機能拡張 \(exts) 個、コントロールパネル \(cdevs) 個", "\(exts) extensions, \(cdevs) control panels") : nil)

        // All files, with what the Finder knows about them.
        let rows = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.prefix(3000).map {
            [$0.path, $0.type, $0.creator, ClassicMac.typeNames[$0.type].map { L($0.ja, $0.en) } ?? "", byteSize($0.dataSize), byteSize($0.resourceSize)]
        }
        f.sections.append(ReportSection(id: "files", title: L("ファイル", "Files"), symbol: "doc.on.doc",
            blocks: [.table(TableData(columns: [L("場所", "Path"), L("タイプ", "Type"), L("クリエーター", "Creator"), L("種類", "Kind"), L("データ", "Data"), L("リソース", "Resource")], rows: Array(rows), total: files.count))], count: files.count))
        return f
    }
}

/// StuffIt (.sit) and Compact Pro (.cpt) archives: the usual way classic Mac software was packed.
/// The contents are listed with their type and creator; the compressed data itself is not expanded.
enum ClassicArchive {
    struct Item { var path: String; var isDir: Bool; var type = ""; var creator = ""; var dataLen = 0; var rsrcLen = 0; var packed = 0; var method = ""; var modified: Date? }

    static let methods: [Int: String] = [0: L("無圧縮", "None"), 1: "RLE", 2: "LZW", 3: L("ハフマン", "Huffman"), 5: "LZAH", 6: L("固定ハフマン", "Fixed Huffman"), 8: "LZMW",
                                         13: "LZ + Huffman", 14: "Installer", 15: "Arsenic (BWT)"]

    static func stuffIt(_ data: Data) -> (items: [Item], version: String, encrypted: Bool)? {
        let r = Reader(data, little: false)
        if data.count > 22, r.fixedStr(10, 4) == "rLau", ["SIT!", "ST46", "ST50", "ST60", "ST65", "STin", "STi2", "STi3", "STi4"].contains(r.fixedStr(0, 4)) {
            var items = [Item]()
            var o = 22
            var folders = [String]()
            var encrypted = false
            let end = Swift.min(Int(r.u32(6)), data.count)
            while o + 112 <= end, items.count < 100_000 {
                let rm = Int(r.u8(o)), dm = Int(r.u8(o + 1))
                let name = ClassicMac.text(r.bytes(o + 3, Swift.min(Int(r.u8(o + 2)), 63)))
                let rsrcLen = Int(r.u32(o + 84)), dataLen = Int(r.u32(o + 88)), cr = Int(r.u32(o + 92)), cd = Int(r.u32(o + 96))
                if rm == 32 || dm == 32 {
                    folders.append(name)
                    items.append(Item(path: folders.joined(separator: "/"), isDir: true))
                    o += 112
                    continue
                }
                if rm == 33 || dm == 33 { _ = folders.popLast(); o += 112; continue }
                if (rm | dm) & 0x10 != 0 { encrypted = true }
                let used = [rm & 0x0f, dm & 0x0f].filter { $0 != 0 || rsrcLen + dataLen == 0 }
                let m = Set(used.map { methods[$0] ?? "?\($0)" }).sorted().joined(separator: " / ")
                items.append(Item(path: (folders + [name]).joined(separator: "/"), isDir: false, type: ClassicMac.code(r, o + 66), creator: ClassicMac.code(r, o + 70),
                                  dataLen: dataLen, rsrcLen: rsrcLen, packed: cr + cd, method: m.isEmpty ? methods[0]! : m, modified: ClassicMac.date(r.u32(o + 80))))
                o += 112 + cr + cd
            }
            return items.isEmpty ? nil : (items, "StuffIt 1.5 – 4", encrypted)
        }
        // StuffIt 5: entries are chained, each starting with A5A5A5A5.
        guard data.count > 120, r.fixedStr(0, 16) == "StuffIt (c)1997-" else { return nil }
        var items = [Item]()
        var encrypted = false
        var names = [Int: String]()
        var o = Int(r.u32(94))
        var hops = 0
        while o > 0, r.ok(o, 48), r.u32(o) == 0xa5a5_a5a5, hops < 100_000 {
            hops += 1
            let hdrSize = Int(r.u16(o + 6)), flags = r.u8(o + 9)
            let parent = Int(r.u32(o + 26)), nameLen = Int(r.u16(o + 30))
            let dataLen = Int(r.u32(o + 34)), dataPacked = Int(r.u32(o + 38))
            let isDir = flags & 0x40 != 0
            let name = ClassicMac.text(r.bytes(o + 48, Swift.min(nameLen, 255)))
            let path = (names[parent].map { $0 + "/" } ?? "") + name
            if flags & 0x20 != 0 { encrypted = true }
            if isDir {
                // 0xFFFFFFFF marks the end-of-folder record.
                if dataLen == 0xffff_ffff { o += hdrSize; continue }
                names[o] = path
                items.append(Item(path: path, isDir: true))
                // A folder's entry is followed by a 36-byte second header; its files come right after.
                o += hdrSize + 36
                continue
            }
            var it = Item(path: path, isDir: false, dataLen: dataLen, packed: dataPacked, modified: ClassicMac.date(r.u32(o + 14)))
            let dm = Int(r.u8(o + 46))
            // Second header: Finder info, then the resource fork's sizes when there is one.
            let h2 = o + hdrSize
            let hasRsrc = r.u16(h2) & 1 != 0
            it.type = ClassicMac.code(r, h2 + 4); it.creator = ClassicMac.code(r, h2 + 8)
            var rm: Int?
            var body = h2 + 36
            var rsrcPacked = 0
            if hasRsrc {
                it.rsrcLen = Int(r.u32(body)); rsrcPacked = Int(r.u32(body + 4))
                rm = Int(r.u8(body + 12))
                body += 14
            }
            it.packed += rsrcPacked
            it.method = Set([it.dataLen > 0 ? dm : nil, it.rsrcLen > 0 ? rm : nil].compactMap { $0 }.map { methods[$0] ?? "?\($0)" }).sorted().joined(separator: " / ")
            items.append(it)
            o = body + it.packed
        }
        return items.isEmpty ? nil : (items, "StuffIt 5", encrypted)
    }

    static func compactPro(_ data: Data) -> [Item]? {
        let r = Reader(data, little: false)
        guard data.count > 16, r.u8(0) == 1, r.u8(1) >= 1, r.u8(1) < 32 else { return nil }
        let dir = Int(r.u32(4))
        guard dir >= 8, r.ok(dir, 7) else { return nil }
        let total = Int(r.u16(dir + 4))
        var o = dir + 7 + Int(r.u8(dir + 6))
        var items = [Item]()
        func walk(_ count: Int, _ prefix: String, _ depth: Int) -> Bool {
            var left = count
            while left > 0 {
                guard r.ok(o, 2), items.count < 100_000, depth < 32 else { return false }
                let b = Int(r.u8(o))
                let name = ClassicMac.text(r.bytes(o + 1, b & 0x7f))
                guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return false }
                o += 1 + (b & 0x7f)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if b & 0x80 != 0 {
                    let inside = Int(r.u16(o)); o += 2
                    items.append(Item(path: path, isDir: true))
                    guard walk(inside, path, depth + 1) else { return false }
                    left -= 1 + inside
                } else {
                    guard r.ok(o, 45) else { return false }
                    let flags = r.u16(o + 27)
                    var it = Item(path: path, isDir: false, type: ClassicMac.code(r, o + 5), creator: ClassicMac.code(r, o + 9))
                    it.modified = ClassicMac.date(r.u32(o + 17))
                    it.rsrcLen = Int(r.u32(o + 29)); it.dataLen = Int(r.u32(o + 33))
                    it.packed = Int(r.u32(o + 37)) + Int(r.u32(o + 41))
                    it.method = (flags & 2 != 0 || flags & 4 != 0 ? "LZH" : "RLE") + (flags & 1 != 0 ? L("（暗号化）", " (encrypted)") : "")
                    items.append(it)
                    o += 45
                    left -= 1
                }
            }
            return true
        }
        guard total > 0, total < 65535, walk(total, "", 0), !items.isEmpty else { return nil }
        return items
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        var items = [Item]()
        var format = "", encrypted = false
        if let s = stuffIt(data) { items = s.items; format = s.version; encrypted = s.encrypted }
        else if url.pathExtension.lowercased() == "cpt", let c = compactPro(data) { items = c; format = "Compact Pro" }
        else { return nil }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        let kind = format.hasPrefix("StuffIt") ? L("StuffIt アーカイブ (sit)", "StuffIt archive (sit)") : L("Compact Pro アーカイブ (cpt)", "Compact Pro archive (cpt)")
        rep.subtitle = kind
        rep.badges = [Badge(text: "Classic Mac OS", tone: .info)]
        if encrypted { rep.badges.append(Badge(text: L("暗号化", "Encrypted"), tone: .warn)) }
        let files = items.filter { !$0.isDir }
        let apps = files.filter { $0.type == "APPL" }
        if apps.count == 1 { rep.title = (apps[0].path as NSString).lastPathComponent }
        var sum = [Row(L("種類", "Kind"), kind)]
        sum.add(L("形式", "Format"), format)
        sum.add(L("中のアプリケーション", "Applications inside"), apps.isEmpty ? nil : apps.prefix(6).map { ($0.path as NSString).lastPathComponent }.joined(separator: "、") + (apps.count > 6 ? L(" ほか \(apps.count - 6) 個", " and \(apps.count - 6) more") : ""))
        sum.add(L("ファイル数", "Files"), "\(files.count)" + L(" 個（フォルダー \(items.count - files.count) 個）", " (\(items.count - files.count) folders)"))
        let unpacked = files.reduce(0) { $0 + $1.dataLen + $1.rsrcLen }
        sum.add(L("展開後のサイズ", "Unpacked size"), byteSize(unpacked))
        let used = Set(files.flatMap { $0.method.components(separatedBy: " / ") }).filter { !$0.isEmpty }.sorted()
        sum.add(L("圧縮方式", "Compression"), used.joined(separator: ", "))
        if let newest = files.compactMap({ $0.modified }).max() { sum.add(L("いちばん新しいファイル", "Newest file"), dateString(newest)) }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        let rows = items.prefix(opts.deep ? 20_000 : 2000).map {
            $0.isDir ? [$0.path + "/", "", "", "", "", ""] : [$0.path, $0.type, $0.creator, byteSize($0.dataLen + $0.rsrcLen), byteSize($0.packed), $0.method]
        }
        rep.sections = [ReportSection(id: "files", title: L("中身", "Contents"), symbol: "doc.on.doc",
            blocks: [.table(TableData(columns: [L("場所", "Path"), L("タイプ", "Type"), L("クリエーター", "Creator"), L("サイズ", "Size"), L("圧縮後", "Packed"), L("方式", "Method")], rows: Array(rows), total: items.count))], count: items.count)]
        return rep
    }
}
