import Foundation

/// Minimal UDF reader (plain partitions, as on Windows installation discs and most data DVDs).
struct UDF {
    struct Node { var isDir: Bool; var size: Int; var extents: [(offset: Int, length: Int)]; var embedded: Data? }
    struct Entry { var name: String; var isDir: Bool; var icb: Int }

    let r: Reader
    var partitionStart = 0
    var blockSize = 2048
    var rootICB = 0
    var volumeName = ""

    func block(_ lbn: Int) -> Int { (partitionStart + lbn) * blockSize }

    static func dstring(_ d: Data) -> String {
        guard let first = d.first, d.count > 1 else { return "" }
        let body = d.dropFirst()
        if first == 16 {
            var u = [UInt16]()
            var it = body.makeIterator()
            while let a = it.next(), let b = it.next() { u.append(UInt16(a) << 8 | UInt16(b)) }
            return String(decoding: u, as: UTF16.self)
        }
        return String(data: Data(body), encoding: .isoLatin1) ?? ""
    }

    init?(_ data: Data) {
        r = Reader(data, little: true)
        let avdp = 256 * 2048
        guard r.ok(avdp, 512), r.u16(avdp) == 2 else { return nil }
        let vds = Int(r.u32(avdp + 20)), vdsLen = Int(r.u32(avdp + 16))
        var fsd = -1
        for i in 0..<Swift.min(vdsLen / 2048, 64) {
            let d = (vds + i) * 2048
            guard r.ok(d, 2048) else { break }
            switch r.u16(d) {
            case 5: partitionStart = Int(r.u32(d + 188))
            case 6:
                blockSize = Int(r.u32(d + 212))
                fsd = Int(r.u32(d + 252))
                let len = Int(r.u8(d + 84 + 127))
                volumeName = UDF.dstring(r.bytes(d + 84, Swift.min(Swift.max(len, 0), 127))).trimmingCharacters(in: .whitespaces)
            case 8: break
            default: continue
            }
        }
        guard fsd >= 0, blockSize == 2048, partitionStart > 0 else { return nil }
        let f = block(fsd)
        guard r.ok(f, 512), r.u16(f) == 256 else { return nil }
        rootICB = Int(r.u32(f + 404))
    }

    /// File Entry (261) or Extended File Entry (266) → where the data lives.
    func node(_ icb: Int) -> Node? {
        let b = block(icb)
        guard r.ok(b, 2048) else { return nil }
        let tag = r.u16(b)
        guard tag == 261 || tag == 266 else { return nil }
        let type = r.u8(b + 27), adType = r.u16(b + 34) & 7
        let size = Int(clamping: r.u64(b + 56))
        let lea = Int(r.u32(b + (tag == 261 ? 168 : 208))), lad = Int(r.u32(b + (tag == 261 ? 172 : 212)))
        var p = b + (tag == 261 ? 176 : 216) + lea
        var node = Node(isDir: type == 4, size: size, extents: [], embedded: nil)
        if adType == 3 {
            node.embedded = r.bytes(p, Swift.min(lad, size))
            return node
        }
        var end = p + lad
        let step = adType == 1 ? 16 : 8
        var guardN = 0
        while p + step <= end, guardN < 100_000 {
            guardN += 1
            let raw = r.u32(p)
            let len = Int(raw & 0x3fff_ffff), kind = raw >> 30
            let lbn = Int(r.u32(p + 4))
            if len == 0 { break }
            if kind == 3 {   // the list continues in another block (Allocation Extent Descriptor)
                let a = block(lbn)
                guard r.ok(a, 24), r.u16(a) == 258 else { break }
                p = a + 24
                end = p + Int(r.u32(a + 20))
                continue
            }
            if kind == 0 { node.extents.append((block(lbn), len)) } else { node.extents.append((-1, len)) }   // unrecorded = zeros
            p += step
        }
        return node
    }

    func read(_ n: Node, offset: Int, length: Int) -> Data? {
        guard offset >= 0, offset < n.size else { return nil }
        let want = Swift.min(length, n.size - offset)
        if let e = n.embedded { return e.count >= offset + want ? e.subdata(in: (e.startIndex + offset)..<(e.startIndex + offset + want)) : nil }
        var out = Data()
        var pos = 0
        for ext in n.extents {
            if out.count >= want { break }
            let start = Swift.max(offset + out.count, pos)
            if start < pos + ext.length {
                let inExt = start - pos
                let c = Swift.min(ext.length - inExt, want - out.count)
                if ext.offset < 0 { out.append(Data(count: c)) }
                else { guard r.ok(ext.offset + inExt, c) else { return nil }; out.append(r.bytes(ext.offset + inExt, c)) }
            }
            pos += ext.length
        }
        return out.count == want ? out : nil
    }

    func list(_ icb: Int, limit: Int = 4000) -> [Entry] {
        guard let n = node(icb), n.isDir, n.size < 8 << 20, let d = read(n, offset: 0, length: n.size) else { return [] }
        let dr = Reader(d, little: true)
        var out = [Entry]()
        var p = 0
        while p + 38 <= d.count, out.count < limit {
            guard dr.u16(p) == 257 else { break }
            let chars = dr.u8(p + 18), lfi = Int(dr.u8(p + 19)), liu = Int(dr.u16(p + 36))
            let childICB = Int(dr.u32(p + 24))
            if chars & 0x0c == 0, lfi > 0 {   // not deleted, not the parent entry
                out.append(Entry(name: UDF.dstring(dr.bytes(p + 38 + liu, lfi)), isDir: chars & 2 != 0, icb: childICB))
            }
            p += (38 + liu + lfi + 3) & ~3
        }
        return out
    }
}

/// One view over a disc's files, whichever file system holds the real contents (UDF first, then ISO 9660).
final class DiscFS {
    struct Item { var name: String; var isDir: Bool; var size: Int }
    let iso: ISO9660?
    let udf: UDF?
    var usesUDF: Bool { udf != nil }

    init(data: Data, iso: ISO9660?) {
        self.iso = iso
        // Use UDF when the disc has it and its root can actually be read.
        if iso == nil || iso!.hasUDF, let u = UDF(data), !u.list(u.rootICB).isEmpty { udf = u } else { udf = nil }
    }

    private func udfEntry(_ path: String) -> UDF.Entry? {
        guard let udf else { return nil }
        var cur = UDF.Entry(name: "", isDir: true, icb: udf.rootICB)
        for part in path.split(separator: "/") {
            guard cur.isDir, let e = udf.list(cur.icb).first(where: { $0.name.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            cur = e
        }
        return cur
    }

    func list(_ path: String = "") -> [Item] {
        if let udf {
            guard let e = udfEntry(path) else { return [] }
            return udf.list(e.icb).map { Item(name: $0.name, isDir: $0.isDir, size: $0.isDir ? 0 : (udf.node($0.icb)?.size ?? 0)) }
        }
        guard let iso else { return [] }
        if path.isEmpty { return iso.root().map { Item(name: $0.name, isDir: $0.isDir, size: $0.size) } }
        guard let e = iso.find(path), e.isDir else { return [] }
        return iso.list(lba: e.lba, size: e.size).map { Item(name: $0.name, isDir: $0.isDir, size: $0.size) }
    }

    func exists(_ path: String) -> Bool { size(path) != nil }

    func size(_ path: String) -> Int? {
        if let udf { return udfEntry(path).flatMap { udf.node($0.icb)?.size } }
        return iso?.find(path).map { $0.size }
    }

    func read(_ path: String, offset: Int = 0, length: Int = 4 << 20) -> Data? {
        if let udf {
            guard let e = udfEntry(path), !e.isDir, let n = udf.node(e.icb) else { return nil }
            return udf.read(n, offset: offset, length: length)
        }
        guard let iso, let e = iso.find(path) else { return nil }
        return iso.read(e, offset: offset, length: length)
    }

    func text(_ path: String, max: Int = 1 << 16) -> String? {
        read(path, offset: 0, length: max).flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
