import Foundation

/// Read-only HFS+ / HFSX: enough to walk folders and read files (first eight extents of each fork).
final class HFSPlus {
    struct Fork { var size: Int; var extents: [(start: Int, count: Int)] }
    struct Item { var name: String; var isDir: Bool; var id: UInt32; var data: Fork }

    let dev: BlockDevice
    var blockSize = 4096
    var fileCount = 0
    var folderCount = 0
    var created: Date?
    var modified: Date?
    var totalBytes = 0
    var freeBytes = 0
    private var catalog = Fork(size: 0, extents: [])
    private var nodeSize = 4096
    private var rootNode = 0

    init?(_ device: BlockDevice) {
        var d = device
        // HFS wrapper around an embedded HFS+ volume (old install CDs).
        if let w = d.reader(1024, 512), w.fixedStr(0, 2) == "BD", w.fixedStr(0x7c, 2) == "H+" {
            let alBlkSize = Int(w.u32(0x14)), alBlSt = Int(w.u16(0x1c))
            let start = Int(w.u16(0x7e)), count = Int(w.u16(0x80))
            d = SubDevice(parent: d, base: alBlSt * 512 + start * alBlkSize, size: count * alBlkSize)
        }
        dev = d
        guard let h = d.reader(1024, 512) else { return nil }
        let sig = h.fixedStr(0, 2)
        guard sig == "H+" || sig == "HX" else { return nil }
        func mac(_ v: UInt32) -> Date? { v == 0 ? nil : Date(timeIntervalSince1970: Double(v) - 2_082_844_800) }
        created = mac(h.u32(16)); modified = mac(h.u32(20))
        fileCount = Int(h.u32(32)); folderCount = Int(h.u32(36))
        blockSize = Int(h.u32(40))
        totalBytes = Int(h.u32(44)) * blockSize; freeBytes = Int(h.u32(48)) * blockSize
        guard blockSize >= 512, blockSize <= 1 << 20 else { return nil }
        catalog = HFSPlus.fork(h, 272)
        guard let head = read(catalog, 0, 512) else { return nil }
        let hr = Reader(head, little: false)
        rootNode = Int(hr.u32(16)); nodeSize = Int(hr.u16(32))
        guard nodeSize >= 512, nodeSize <= 65536, rootNode > 0 else { return nil }
    }

    static func fork(_ r: Reader, _ o: Int) -> Fork {
        var f = Fork(size: Int(clamping: r.u64(o)), extents: [])
        for i in 0..<8 {
            let s = Int(r.u32(o + 16 + i * 8)), c = Int(r.u32(o + 20 + i * 8))
            if c > 0 { f.extents.append((s, c)) }
        }
        return f
    }

    func read(_ f: Fork, _ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, offset < f.size || (offset == 0 && length == 0) else { return nil }
        let want = Swift.min(length, f.size - offset)
        var out = Data()
        var pos = 0
        for e in f.extents {
            if out.count >= want { break }
            let extBytes = e.count * blockSize
            let start = offset + out.count
            if start < pos + extBytes {
                let inExt = start - pos
                let n = Swift.min(extBytes - inExt, want - out.count)
                guard let d = dev.read(e.start * blockSize + inExt, n) else { return nil }
                out.append(d)
            }
            pos += extBytes
        }
        return out.count == want ? out : nil   // nil when the file continues beyond its first eight extents
    }

    private func node(_ n: Int) -> Reader? { read(catalog, n * nodeSize, nodeSize).map { Reader($0, little: false) } }

    private func records(_ nd: Reader) -> [Int] {
        let count = Int(nd.u16(10))
        return (0..<Swift.min(count, nodeSize / 8)).map { Int(nd.u16(nodeSize - 2 * ($0 + 1))) }
    }

    private func key(_ nd: Reader, _ o: Int) -> (parent: UInt32, name: [UInt16], end: Int) {
        let klen = Int(nd.u16(o))
        let n = Swift.min(Int(nd.u16(o + 6)), 255)
        var u = [UInt16]()
        u.reserveCapacity(n)
        for i in 0..<n { u.append(nd.u16(o + 8 + i * 2)) }
        return (nd.u32(o + 2), u, o + 2 + klen)
    }

    /// Ordering used inside the tree: parent first, then the name. ASCII letters fold to lower case,
    /// which matches the real ordering for the plain names looked up here.
    private func less(_ ap: UInt32, _ an: [UInt16], _ bp: UInt32, _ bn: [UInt16]) -> Bool {
        if ap != bp { return ap < bp }
        func fold(_ c: UInt16) -> UInt16 { c >= 0x41 && c <= 0x5a ? c + 0x20 : c }
        for i in 0..<Swift.min(an.count, bn.count) {
            let x = fold(an[i]), y = fold(bn[i])
            if x != y { return x < y }
        }
        return an.count < bn.count
    }

    /// Leaf node where records of `parent` start.
    private func firstLeaf(for parent: UInt32) -> Int? {
        var n = rootNode
        for _ in 0..<16 {
            guard let nd = node(n) else { return nil }
            if Int8(bitPattern: nd.u8(8)) == -1 { return n }
            // Index node: follow the last record whose key is <= (parent, "").
            var child = -1
            for o in records(nd) {
                let k = key(nd, o)
                if child >= 0, !less(k.parent, k.name, parent, []) && !(k.parent == parent && k.name.isEmpty) { break }
                child = Int(nd.u32(k.end))
            }
            guard child > 0 else { return nil }
            n = child
        }
        return nil
    }

    func children(_ parent: UInt32, limit: Int = 20_000) -> [Item] {
        guard var n = firstLeaf(for: parent) else { return [] }
        var out = [Item]()
        var hops = 0
        while n != 0, hops < 200_000, out.count < limit {
            guard let nd = node(n) else { break }
            var past = false
            for o in records(nd) {
                let k = key(nd, o)
                if k.parent < parent { continue }
                if k.parent > parent { past = true; break }
                let rec = k.end
                let type = nd.u16(rec)
                if type == 1 {
                    out.append(Item(name: String(decoding: k.name, as: UTF16.self), isDir: true, id: nd.u32(rec + 8), data: Fork(size: 0, extents: [])))
                } else if type == 2 {
                    out.append(Item(name: String(decoding: k.name, as: UTF16.self), isDir: false, id: nd.u32(rec + 8), data: HFSPlus.fork(nd, rec + 88)))
                }
            }
            if past { break }
            n = Int(nd.u32(0))
            hops += 1
        }
        return out
    }

    /// Volume name: the thread record of the root folder (ID 2) holds it.
    var volumeName: String {
        guard let n = firstLeaf(for: 2), let nd = node(n) else { return "" }
        for o in records(nd) {
            let k = key(nd, o)
            guard k.parent == 2, k.name.isEmpty else { continue }
            let rec = k.end
            guard nd.u16(rec) == 3 else { continue }
            let len = Swift.min(Int(nd.u16(rec + 8)), 255)
            return String(decoding: (0..<len).map { nd.u16(rec + 10 + $0 * 2) }, as: UTF16.self)
        }
        return ""
    }

    func item(_ path: String) -> Item? {
        var cur = Item(name: "", isDir: true, id: 2, data: Fork(size: 0, extents: []))
        for part in path.split(separator: "/") {
            guard cur.isDir, let next = children(cur.id).first(where: { $0.name.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            cur = next
        }
        return cur
    }

    /// Every file under `path`, as (path relative to the volume root, data fork). Breadth-first, bounded.
    func files(under path: String, limit: Int = 30_000) -> [(path: String, fork: Fork)] {
        guard let start = item(path), start.isDir else { return [] }
        var out = [(String, Fork)]()
        var queue = [(path, start.id)]
        var visited = 0
        while !queue.isEmpty, out.count < limit, visited < 20_000 {
            let (dir, id) = queue.removeFirst()
            visited += 1
            for c in children(id) {
                let p = dir + "/" + c.name
                if c.isDir { queue.append((p, c.id)) } else { out.append((p, c.data)) }
                if out.count >= limit { break }
            }
        }
        return out
    }

    func list(_ path: String = "") -> [Item] { item(path).map { $0.isDir ? children($0.id) : [] } ?? [] }

    func read(_ path: String, max: Int = 16 << 20) -> Data? {
        guard let i = item(path), !i.isDir, i.data.size <= max else { return nil }
        return read(i.data, 0, i.data.size)
    }

    func plist(_ path: String) -> [String: Any]? {
        read(path, max: 8 << 20).flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
    }
}

/// A file inside an HFS+ volume, usable as a device (for disk images stored inside disk images).
struct HFSFileDevice: BlockDevice {
    let fs: HFSPlus
    let fork: HFSPlus.Fork
    var size: Int { fork.size }
    func read(_ offset: Int, _ length: Int) -> Data? { fs.read(fork, offset, length) }
}
