import Foundation
import Compression

/// What the disk image code needs from a Mac volume, whichever file system it is (HFS+ or APFS).
struct VolEntry { var name: String; var isDir: Bool; var size: Int }
struct VolFile { var path: String; var size: Int; var read: () -> Data? }

protocol MacVolume: AnyObject {
    var volumeName: String { get }
    var fileCount: Int { get }
    var folderCount: Int { get }
    var created: Date? { get }
    var totalBytes: Int { get }
    func entries(_ path: String) -> [VolEntry]
    func data(_ path: String, max: Int) -> Data?
    /// A file inside the volume as a device (for disk images stored inside disk images).
    func device(_ path: String) -> BlockDevice?
    /// Every file under `path`, with paths relative to the volume root.
    func tree(under path: String, limit: Int) -> [VolFile]
}

extension MacVolume {
    func plist(_ path: String) -> [String: Any]? {
        data(path, max: 8 << 20).flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
    }
    func exists(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let last = parts.last else { return true }
        return entries(parts.dropLast().joined(separator: "/")).contains { $0.name.caseInsensitiveCompare(String(last)) == .orderedSame }
    }
}

extension HFSPlus: MacVolume {
    func entries(_ path: String) -> [VolEntry] { list(path).map { VolEntry(name: $0.name, isDir: $0.isDir, size: $0.data.size) } }
    func data(_ path: String, max: Int) -> Data? { read(path, max: max) }
    func device(_ path: String) -> BlockDevice? { item(path).flatMap { $0.isDir ? nil : HFSFileDevice(fs: self, fork: $0.data) } }
    func tree(under path: String, limit: Int) -> [VolFile] {
        files(under: path, limit: limit).map { f in VolFile(path: f.path, size: f.fork.size) { [unowned self] in self.read(f.fork, 0, f.fork.size) } }
    }
}

/// Read-only APFS: the container, its volumes, and inside an unencrypted volume the folders and files
/// (including files stored compressed, the way macOS keeps its own system files).
final class APFS {
    let dev: BlockDevice
    var blockSize = 4096
    var blockCount = 0
    var volumes: [APFSVolume] = []
    private var omapRoot = 0
    private var blockCache: [Int: Data] = [:]
    private var blockOrder: [Int] = []

    init?(_ device: BlockDevice) {
        dev = device
        guard var sb = device.reader(0, 4096, little: true), sb.fixedStr(32, 4) == "NXSB" else { return nil }
        blockSize = Int(sb.u32(36))
        guard blockSize >= 4096, blockSize <= 65536 else { return nil }
        if blockSize != 4096, let full = device.reader(0, blockSize, little: true) { sb = full }
        // The newest checkpoint may be further along than block 0: take the superblock with the highest transaction.
        let descBlocks = Int(sb.u32(104)), descBase = Int(clamping: sb.u64(112))
        if descBlocks & 0x8000_0000 == 0, descBase > 0, descBase < 1 << 40 {
            var best = sb.u64(16)
            for i in 0..<Swift.min(descBlocks, 512) {
                guard let b = device.reader((descBase + i) * blockSize, blockSize, little: true), b.fixedStr(32, 4) == "NXSB", b.u32(24) & 0xffff == 1 else { continue }
                if b.u64(16) > best { best = b.u64(16); sb = b }
            }
        }
        blockCount = Int(clamping: sb.u64(40))
        let omapOID = Int(clamping: sb.u64(160))
        guard let om = block(omapOID) else { return nil }
        omapRoot = Int(clamping: Reader(om, little: true).u64(48))
        let maxFS = Swift.min(Int(sb.u32(180)), 100)
        for i in 0..<maxFS {
            let oid = sb.u64(184 + i * 8)
            guard oid != 0, let addr = omap(root: omapRoot, oid: oid), let vb = block(addr) else { continue }
            let v = Reader(vb, little: true)
            guard v.fixedStr(32, 4) == "APSB" else { continue }
            volumes.append(APFSVolume(self, v))
        }
        guard !volumes.isEmpty else { return nil }
    }

    func block(_ n: Int) -> Data? {
        if let hit = blockCache[n] { return hit }
        guard n > 0 || blockCount == 0, n < 1 << 40, let d = dev.read(n * blockSize, blockSize) else { return nil }
        if blockOrder.count >= 6000 { for k in blockOrder.prefix(2000) { blockCache[k] = nil }; blockOrder.removeFirst(2000) }
        blockCache[n] = d
        blockOrder.append(n)
        return d
    }

    /// A B-tree node, with the positions its table of contents refers to already worked out.
    struct Node {
        let r: Reader
        let leaf: Bool
        let fixed: Bool
        let count: Int
        let toc: Int
        let keys: Int
        let valEnd: Int

        init?(_ d: Data) {
            r = Reader(d, little: true)
            let type = r.u32(24) & 0xffff
            guard type == 2 || type == 3 else { return nil }
            let flags = Int(r.u16(32))
            leaf = flags & 2 != 0
            fixed = flags & 4 != 0
            count = Int(r.u32(36))
            toc = 56 + Int(r.u16(40))
            keys = toc + Int(r.u16(42))
            valEnd = d.count - (flags & 1 != 0 ? 40 : 0)
            guard count <= d.count / 4, keys <= d.count else { return nil }
        }
        func key(_ i: Int) -> (off: Int, len: Int) {
            fixed ? (keys + Int(r.u16(toc + i * 4)), 16) : (keys + Int(r.u16(toc + i * 8)), Int(r.u16(toc + i * 8 + 2)))
        }
        func value(_ i: Int) -> (off: Int, len: Int) {
            if fixed { return (valEnd - Int(r.u16(toc + i * 4 + 2)), leaf ? 16 : 8) }
            return (valEnd - Int(r.u16(toc + i * 8 + 4)), Int(r.u16(toc + i * 8 + 6)))
        }
    }

    /// Looks a (first, second) key up in a tree of fixed 16-byte keys: the entry with the same `first`
    /// and the greatest `second` that is not above the one asked for. Returns the offset of its value.
    func fixedLookup(root: Int, first: UInt64, second: UInt64) -> (r: Reader, key: Int, value: Int)? {
        var n = root
        for _ in 0..<12 {
            guard let d = block(n), let node = Node(d) else { return nil }
            var pick = -1
            var lo = 0, hi = node.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let k = node.key(mid).off
                let a = node.r.u64(k), b = node.r.u64(k + 8)
                if a < first || (a == first && b <= second) { pick = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            if node.leaf {
                guard pick >= 0, node.r.u64(node.key(pick).off) == first else { return nil }
                return (node.r, node.key(pick).off, node.value(pick).off)
            }
            n = Int(clamping: node.r.u64(node.value(Swift.max(pick, 0)).off))
        }
        return nil
    }

    /// Object map: virtual object ID → block, for the newest transaction.
    func omap(root: Int, oid: UInt64) -> Int? {
        guard let hit = fixedLookup(root: root, first: oid, second: .max) else { return nil }
        return Int(clamping: hit.r.u64(hit.value + 8))
    }

    /// The volume worth showing: readable, not one of the helper volumes, and the one with the most files.
    var mainVolume: APFSVolume? {
        let helpers: Set<Int> = [0x04, 0x08, 0x10, 0x20, 0xc0, 0x140, 0x180, 0x200]   // recovery, VM, preboot, installer, update, hardware, backup, xART…
        let usable = volumes.filter { !$0.encrypted }
        return usable.filter { !helpers.contains($0.role) }.max { $0.fileCount < $1.fileCount } ?? usable.max { $0.fileCount < $1.fileCount }
    }
}

final class APFSVolume: MacVolume {
    struct Inode {
        var id: UInt64 = 0, privateID: UInt64 = 0
        var mode = 0, bsdFlags: UInt32 = 0
        var size = 0, uncompressedSize = 0
        var created: Date?
        var isDir: Bool { mode & 0o170000 == 0o040000 }
        var isLink: Bool { mode & 0o170000 == 0o120000 }
    }
    struct Extent { var logical: Int; var length: Int; var block: Int }

    unowned let fs: APFS
    var volumeName = ""
    var role = 0
    var encrypted = false
    var sealed = false
    var caseInsensitive = false
    var fileCount = 0, folderCount = 0
    var created: Date?
    var totalBytes = 0
    private var hashedNames = true
    private var omapRoot = 0
    private var rootTree: UInt64 = 0
    private var physicalTree = false
    private var fextRoot = 0
    private var nodeCache: [UInt64: APFS.Node] = [:]
    private var dirCache: [UInt64: [(name: String, id: UInt64, isDir: Bool)]] = [:]
    private var extentCache: [UInt64: [Extent]] = [:]

    init(_ fs: APFS, _ v: Reader) {
        self.fs = fs
        let incompat = v.u64(56)
        caseInsensitive = incompat & 1 != 0
        hashedNames = incompat & 0x9 != 0
        sealed = incompat & 0x20 != 0
        encrypted = v.u64(264) & 1 == 0
        totalBytes = Int(Swift.min(v.u64(88), 1 << 40)) * fs.blockSize
        physicalTree = v.u32(116) & 0x4000_0000 != 0
        rootTree = v.u64(136)
        fileCount = Int(clamping: v.u64(184)); folderCount = Int(clamping: v.u64(192))
        volumeName = v.fixedStr(704, 256)
        role = Int(v.u16(964))
        let t = v.u64(272 + 32)   // when the volume was formatted
        created = t == 0 ? nil : Date(timeIntervalSince1970: Double(t) / 1e9)
        if let om = fs.block(Int(clamping: v.u64(128))) { omapRoot = Int(clamping: Reader(om, little: true).u64(48)) }
        if sealed, v.count >= 1044 { fextRoot = Int(clamping: v.u64(1032)) }
    }

    static let roleNames: [Int: (ja: String, en: String)] = [
        0x01: ("システム", "System"), 0x02: ("ユーザー", "User"), 0x04: ("復旧", "Recovery"), 0x08: ("仮想メモリー", "VM"), 0x10: ("起動前の処理", "Preboot"),
        0x20: ("インストーラー", "Installer"), 0x40: ("データ", "Data"), 0x80: ("ベースバンド", "Baseband"), 0xc0: ("アップデート", "Update"), 0x100: ("xART", "xART"),
        0x140: ("ハードウェア", "Hardware"), 0x180: ("バックアップ", "Backup"), 0x2c0: ("事前ログイン", "Prelogin"),
    ]
    var roleName: String { role == 0 ? "" : APFSVolume.roleNames[role].map { L($0.ja, $0.en) } ?? hex(role) }

    // MARK: tree walking

    private func node(_ oid: UInt64) -> APFS.Node? {
        if let hit = nodeCache[oid] { return hit }
        let addr = physicalTree ? Int(clamping: oid) : fs.omap(root: omapRoot, oid: oid)
        guard let addr, let d = fs.block(addr), let n = APFS.Node(d) else { return nil }
        if nodeCache.count > 3000 { nodeCache.removeAll() }
        nodeCache[oid] = n
        return n
    }

    /// Visits every record whose (object ID, record type) equals the one asked for, in key order.
    /// `visit` gets the node's bytes and where the key and the value sit; return false to stop.
    private func records(_ id: UInt64, _ type: UInt64, _ visit: (Reader, _ key: Int, _ keyLen: Int, _ val: Int, _ valLen: Int) -> Bool) {
        @inline(__always) func rank(_ r: Reader, _ o: Int) -> (UInt64, UInt64) { let h = r.u64(o); return (h & 0x0fff_ffff_ffff_ffff, h >> 60) }
        var visited = 0   // a damaged tree must not send the walk in circles
        func walk(_ oid: UInt64, _ depth: Int) -> Bool {
            visited += 1
            guard depth < 16, visited < 20_000, let n = node(oid) else { return visited < 20_000 }
            if n.leaf {
                // Binary search for the first record at or after the one wanted.
                var lo = 0, hi = n.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let k = rank(n.r, n.key(mid).off)
                    if k.0 < id || (k.0 == id && k.1 < type) { lo = mid + 1 } else { hi = mid }
                }
                var i = lo
                while i < n.count {
                    let k = n.key(i), v = n.value(i)
                    let rk = rank(n.r, k.off)
                    if rk.0 != id || rk.1 != type { return false }
                    if !visit(n.r, k.off, k.len, v.off, v.len) { return false }
                    i += 1
                }
                return true
            }
            // Children whose key range can contain the record: from the last child starting before it onwards.
            var lo = 0, hi = n.count
            while lo < hi {
                let mid = (lo + hi) / 2
                let k = rank(n.r, n.key(mid).off)
                if k.0 < id || (k.0 == id && k.1 < type) { lo = mid + 1 } else { hi = mid }
            }
            var i = Swift.max(lo - 1, 0)
            while i < n.count {
                let rk = rank(n.r, n.key(i).off)
                if rk.0 > id || (rk.0 == id && rk.1 > type) { return false }
                if !walk(n.r.u64(n.value(i).off), depth + 1) { return false }
                i += 1
            }
            return true
        }
        _ = walk(rootTree, 0)
    }

    func inode(_ id: UInt64) -> Inode? {
        var out: Inode?
        records(id, 3) { r, _, _, v, len in
            guard len >= 92 else { return false }
            var n = Inode(id: id, privateID: r.u64(v + 8))
            let c = r.u64(v + 16)
            n.created = c == 0 ? nil : Date(timeIntervalSince1970: Double(c) / 1e9)
            n.bsdFlags = r.u32(v + 68)
            n.mode = Int(r.u16(v + 80))
            n.uncompressedSize = Int(Swift.min(r.u64(v + 84), 1 << 47))
            // Extended fields: the data stream (file size) is one of them.
            if len >= 96 {
                let num = Int(r.u16(v + 92))
                var data = v + 96 + num * 4
                for i in 0..<Swift.min(num, 32) {
                    let type = r.u8(v + 96 + i * 4), size = Int(r.u16(v + 96 + i * 4 + 2))
                    if type == 8, size >= 8 { n.size = Int(Swift.min(r.u64(data), 1 << 47)) }
                    data += (size + 7) & ~7
                }
            }
            out = n
            return false
        }
        return out
    }

    func children(_ id: UInt64, limit: Int = 50_000) -> [(name: String, id: UInt64, isDir: Bool)] {
        if let hit = dirCache[id] { return hit }
        var out = [(String, UInt64, Bool)]()
        records(id, 9) { r, k, klen, v, vlen in
            guard vlen >= 18 else { return true }
            let nameLen: Int, nameAt: Int
            if hashedNames { nameLen = Int(r.u32(k + 8) & 0x3ff); nameAt = k + 12 } else { nameLen = Int(r.u16(k + 8)); nameAt = k + 10 }
            guard nameLen > 0, nameAt + nameLen <= k + klen else { return true }
            out.append((r.fixedStr(nameAt, nameLen), r.u64(v), r.u16(v + 16) & 0xf == 4))
            return out.count < limit
        }
        if dirCache.count > 4000 { dirCache.removeAll() }
        dirCache[id] = out
        return out
    }

    func find(_ path: String) -> (id: UInt64, isDir: Bool)? {
        var cur: (UInt64, Bool) = (2, true)
        for part in path.split(separator: "/") {
            guard cur.1 else { return nil }
            let kids = children(cur.0)
            guard let next = kids.first(where: { $0.name == part }) ?? kids.first(where: { $0.name.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            cur = (next.id, next.isDir)
        }
        return cur
    }

    func xattr(_ id: UInt64, _ name: String) -> (embedded: Data?, stream: (id: UInt64, size: Int)?)? {
        var out: (Data?, (UInt64, Int)?)?
        records(id, 4) { r, k, _, v, vlen in
            let n = Int(r.u16(k + 8))
            guard r.fixedStr(k + 10, n) == name, vlen >= 4 else { return true }
            let flags = r.u16(v), len = Int(r.u16(v + 2))
            if flags & 1 != 0, len >= 16 { out = (nil, (r.u64(v + 4), Int(clamping: r.u64(v + 12)))) }
            else { out = (r.bytes(v + 4, Swift.min(len, vlen - 4)), nil) }
            return false
        }
        return out
    }

    private func extents(_ privateID: UInt64) -> [Extent] {
        if let hit = extentCache[privateID] { return hit }
        var out = [Extent]()
        if sealed, fextRoot != 0 {
            // Sealed system volumes keep extents in a separate tree keyed by (file, offset).
            var at: UInt64 = 0
            while out.count < 100_000, let hit = fs.fixedLookup(root: fextRoot, first: privateID, second: at), hit.r.u64(hit.key + 8) == at {
                let len = Int(clamping: hit.r.u64(hit.value) & 0x00ff_ffff_ffff_ffff)
                guard len > 0, len < 1 << 48, at < 1 << 48, hit.r.u64(hit.value + 8) < 1 << 40 else { break }
                out.append(Extent(logical: Int(at), length: len, block: Int(clamping: hit.r.u64(hit.value + 8))))
                at += UInt64(len)
            }
        } else {
            records(privateID, 8) { r, k, _, v, vlen in
                guard vlen >= 16 else { return true }
                let e = Extent(logical: Int(clamping: r.u64(k + 8)), length: Int(clamping: r.u64(v) & 0x00ff_ffff_ffff_ffff), block: Int(clamping: r.u64(v + 8)))
                // Values outside any real disk mean a damaged record: leave it out.
                if e.logical < 1 << 48, e.length > 0, e.length < 1 << 48, e.block < 1 << 40 { out.append(e) }
                return out.count < 200_000
            }
        }
        if extentCache.count > 2000 { extentCache.removeAll() }
        extentCache[privateID] = out
        return out
    }

    /// Bytes of a data stream (a file's contents, or a large extended attribute).
    func stream(_ privateID: UInt64, size: Int, offset: Int, length: Int) -> Data? {
        guard offset >= 0, offset <= size, size < 1 << 48, length >= 0 else { return nil }
        let want = Swift.min(length, size - offset)
        if want == 0 { return Data() }
        var out = Data(capacity: want)
        let ext = extents(privateID)
        var pos = offset
        // First extent that reaches `pos`.
        var lo = 0, hi = ext.count
        while lo < hi { let mid = (lo + hi) / 2; if ext[mid].logical + ext[mid].length <= pos { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while out.count < want {
            if i >= ext.count || ext[i].logical > pos {
                // A hole reads as zeros.
                let until = i < ext.count ? ext[i].logical : size
                let n = Swift.min(want - out.count, until - pos)
                guard n > 0 else { return nil }
                out.append(Data(count: n)); pos += n
                continue
            }
            let e = ext[i]
            let inExt = pos - e.logical
            let n = Swift.min(want - out.count, e.length - inExt)
            if e.block == 0 { out.append(Data(count: n)) }
            else { guard let d = fs.dev.read(e.block * fs.blockSize + inExt, n) else { return nil }; out.append(d) }
            pos += n
            i += 1
        }
        return out
    }

    /// Files macOS stores compressed keep the real contents in an extended attribute (small files)
    /// or in the resource fork, cut into 64 KB pieces.
    private func decompressed(_ n: Inode, max: Int) -> Data? {
        guard let x = xattr(n.id, "com.apple.decmpfs") else { return nil }
        let head: Data
        if let e = x.embedded { head = e } else if let s = x.stream { guard let d = stream(s.id, size: s.size, offset: 0, length: Swift.min(s.size, 1 << 20)) else { return nil }; head = d } else { return nil }
        let h = Reader(head, little: true)
        guard head.count >= 16, h.u32(0) == 0x636d_7066 else { return nil }
        let type = Int(h.u32(4)), size = Int(clamping: h.u64(8))
        guard size <= max else { return nil }
        if size == 0 { return Data() }
        func expand(_ src: Data, _ algo: compression_algorithm, _ outSize: Int) -> Data? {
            var out = Data(count: outSize)
            let got = out.withUnsafeMutableBytes { dst in src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, outSize, s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algo) } }
            guard got > 0 else { return nil }
            if got < outSize { out.removeSubrange(got...) }
            return out
        }
        let lzvn = compression_algorithm(rawValue: 0x900)
        let body = head.dropFirst(16)
        let payload = Data(body)
        switch type {
        case 1: return payload.prefix(size)
        case 9: return Data(payload.dropFirst().prefix(size))   // stored as is, after a one-byte marker
        case 3:   // zlib, inline (a first byte with the low nibble 0xF means "stored")
            if payload.first.map({ $0 & 0x0f == 0x0f }) == true { return Data(payload.dropFirst().prefix(size)) }
            return Inflate.zlib(payload, max: size)
        case 7: return payload.first == 0x06 ? Data(payload.dropFirst().prefix(size)) : expand(payload, lzvn, size)
        case 11: return payload.first == 0xff ? Data(payload.dropFirst().prefix(size)) : expand(payload, COMPRESSION_LZFSE, size)
        case 4, 8, 10, 12:
            guard let rf = xattr(n.id, "com.apple.ResourceFork"), let s = rf.stream, s.size < 2 << 30, let fork = stream(s.id, size: s.size, offset: 0, length: s.size) else { return nil }
            let f = Reader(fork, little: true)
            var out = Data(capacity: size)
            if type == 4 {
                // Classic resource fork: big-endian header, then a little-endian table of (offset, size).
                let dataOff = Int(f.be32(0))
                let table = dataOff + 4
                let count = Int(f.u32(table))
                guard count < 1 << 20 else { return nil }
                for i in 0..<count {
                    let off = table + Int(f.u32(table + 4 + i * 8)), len = Int(f.u32(table + 8 + i * 8))
                    guard f.ok(off, len), len > 0 else { return nil }
                    let piece = f.bytes(off, len)
                    if piece.first.map({ $0 & 0x0f == 0x0f }) == true { out.append(piece.dropFirst()) }
                    else { guard let d = Inflate.zlib(piece, max: 65536) else { return nil }; out.append(d) }
                }
            } else {
                // A table of offsets; its first entry is also the table's own size.
                let first = Int(f.u32(0))
                let count = first / 4 - 1
                guard count > 0, count < 1 << 20 else { return nil }
                for i in 0..<count {
                    let a = Int(f.u32(i * 4)), b = Int(f.u32(i * 4 + 4))
                    guard b > a, f.ok(a, b - a) else { return nil }
                    let piece = f.bytes(a, b - a)
                    let want = Swift.min(65536, size - out.count)
                    if type == 10 { out.append(piece.first == 0xcc ? piece.dropFirst().prefix(want) : piece.prefix(want)) }
                    else if type == 8, piece.first == 0x06 { out.append(piece.dropFirst().prefix(want)) }
                    else if type == 12, piece.first == 0xff { out.append(piece.dropFirst().prefix(want)) }
                    else { guard let d = expand(piece, type == 8 ? lzvn : COMPRESSION_LZFSE, want) else { return nil }; out.append(d) }
                }
            }
            return out.count >= size ? out.prefix(size) : nil
        default: return nil
        }
    }

    func read(_ n: Inode, max: Int = 16 << 20) -> Data? {
        if n.bsdFlags & 0x20 != 0 {
            if let d = decompressed(n, max: max) { return d }
            // Marked as compressed but stored in a way that is not understood: say so instead of returning nothing.
            if n.size == 0, n.uncompressedSize > 0 { return nil }
        }
        guard n.size <= max else { return nil }
        return stream(n.privateID, size: n.size, offset: 0, length: n.size)
    }

    func size(_ n: Inode) -> Int { n.bsdFlags & 0x20 != 0 && n.uncompressedSize > 0 ? n.uncompressedSize : n.size }

    // MARK: MacVolume

    func entries(_ path: String) -> [VolEntry] {
        guard let d = find(path), d.isDir else { return [] }
        let kids = children(d.id)
        return kids.enumerated().map { i, k in
            VolEntry(name: k.name, isDir: k.isDir, size: k.isDir || i > 3000 ? 0 : (inode(k.id).map { size($0) } ?? 0))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func data(_ path: String, max: Int) -> Data? {
        guard let f = find(path), !f.isDir, let n = inode(f.id) else { return nil }
        return read(n, max: max)
    }

    func device(_ path: String) -> BlockDevice? {
        guard let f = find(path), !f.isDir, let n = inode(f.id), n.bsdFlags & 0x20 == 0 else { return nil }
        return APFSFileDevice(volume: self, privateID: n.privateID, size: n.size)
    }

    func tree(under path: String, limit: Int) -> [VolFile] {
        guard let start = find(path), start.isDir else { return [] }
        var out = [VolFile]()
        var queue: [(String, UInt64)] = [(path, start.id)]
        var visited = 0
        while !queue.isEmpty, out.count < limit, visited < 20_000 {
            let (dir, id) = queue.removeFirst()
            visited += 1
            for c in children(id) {
                let p = dir + "/" + c.name
                if c.isDir { queue.append((p, c.id)); continue }
                guard let n = inode(c.id), !n.isLink else { continue }
                out.append(VolFile(path: p, size: size(n)) { [unowned self] in self.read(n, max: 512 << 20) })
                if out.count >= limit { break }
            }
        }
        return out
    }
}

/// A file inside an APFS volume, usable as a device.
struct APFSFileDevice: BlockDevice {
    let volume: APFSVolume
    let privateID: UInt64
    let size: Int
    func read(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= size, length <= size - offset else { return nil }
        return volume.stream(privateID, size: size, offset: offset, length: length)
    }
}
