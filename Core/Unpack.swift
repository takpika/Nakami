import Foundation
import Compression

/// Compressed streams (gzip / xz / bzip2 / zstd), decoded piece by piece so that an archive inside
/// can be listed without ever holding the whole thing in memory.
enum Unpack {
    enum Codec: String { case none = "", gzip, xz, bzip2, zstd, lzma, lz4 }

    static func codec(_ r: Reader, _ o: Int = 0) -> Codec {
        if r.u8(o) == 0x1f, r.u8(o + 1) == 0x8b { return .gzip }
        if r.be32(o) == 0xfd37_7a58, r.be16(o + 4) == 0x5a00 { return .xz }
        if r.u8(o) == 0x42, r.u8(o + 1) == 0x5a, r.u8(o + 2) == 0x68 { return .bzip2 }
        if r.le32(o) == 0xfd2f_b528 { return .zstd }
        if r.le32(o) == 0x184d_2204 { return .lz4 }
        if r.u8(o) == 0x5d, r.u8(o + 1) == 0, r.u8(o + 2) == 0 { return .lzma }
        return .none
    }

    /// Hands decoded pieces to `sink` until it returns false, the input ends or `budget` seconds pass.
    /// Returns true when the stream was read to its end.
    @discardableResult
    static func stream(_ data: Data, at start: Int = 0, length: Int? = nil, codec: Codec, budget: TimeInterval? = nil, sink: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        let len = Swift.min(length ?? (data.count - start), data.count - start)
        guard len > 0, start >= 0 else { return false }
        let deadline = budget.map { Date().addingTimeInterval($0) }
        switch codec {
        case .none:
            return data.withUnsafeBytes { raw in
                var o = start
                while o < start + len {
                    let n = Swift.min(1 << 20, start + len - o)
                    if !sink(UnsafeRawBufferPointer(rebasing: raw[o..<(o + n)])) { return false }
                    if let deadline, Date() > deadline { return false }
                    o += n
                }
                return true
            }
        case .zstd:
            return Zstd.stream(data, at: start, length: len, deadline: deadline, sink: sink)
        case .bzip2:
            // No streaming interface is bound for libbz2: expand in one go, within a sane size.
            let src = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + len))
            for cap in [Swift.max(len * 8, 4 << 20), 256 << 20] where cap <= 256 << 20 {
                if let out = bunzip2(src, expected: cap) { return out.withUnsafeBytes { sink($0) } }
            }
            return false
        case .gzip, .xz, .lzma, .lz4:
            var skip = 0
            if codec == .gzip {
                let b = Reader(data, little: true)
                let flags = b.u8(start + 3)
                skip = 10
                if flags & 4 != 0 { skip += 2 + Int(b.u16(start + skip)) }
                if flags & 8 != 0 { while skip < len, b.u8(start + skip) != 0 { skip += 1 }; skip += 1 }
                if flags & 16 != 0 { while skip < len, b.u8(start + skip) != 0 { skip += 1 }; skip += 1 }
                if flags & 2 != 0 { skip += 2 }
                guard skip < len else { return false }
            }
            let algo = codec == .gzip ? COMPRESSION_ZLIB : codec == .lz4 ? COMPRESSION_LZ4 : COMPRESSION_LZMA
            let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { sp.deallocate() }
            guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, algo) == COMPRESSION_STATUS_OK else { return false }
            defer { compression_stream_destroy(sp) }
            let cap = 1 << 18
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { dst.deallocate() }
            return data.withUnsafeBytes { raw -> Bool in
                sp.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress! + start + skip
                sp.pointee.src_size = len - skip
                while true {
                    sp.pointee.dst_ptr = dst
                    sp.pointee.dst_size = cap
                    let status = compression_stream_process(sp, sp.pointee.src_size == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let produced = cap - sp.pointee.dst_size
                    if produced > 0, !sink(UnsafeRawBufferPointer(start: dst, count: produced)) { return false }
                    if status == COMPRESSION_STATUS_END { return true }
                    if status != COMPRESSION_STATUS_OK { return false }
                    if produced == 0, sp.pointee.src_size == 0 { return false }
                    if let deadline, Date() > deadline { return false }
                }
            }
        }
    }

    /// The whole decoded stream, or nil when it does not fit in `max` bytes or is damaged.
    static func all(_ data: Data, at start: Int = 0, length: Int? = nil, codec: Codec, max: Int = 64 << 20) -> Data? {
        var out = Data()
        var over = false
        let ok = stream(data, at: start, length: length, codec: codec) { chunk in
            if out.count + chunk.count > max { over = true; return false }
            out.append(contentsOf: chunk)
            return true
        }
        return ok && !over ? out : nil
    }

    /// The first `count` decoded bytes (used to recognise what is inside).
    static func head(_ data: Data, codec: Codec, count: Int = 1024) -> Data {
        var out = Data()
        stream(data, codec: codec, budget: 0.5) { chunk in
            out.append(contentsOf: chunk.prefix(count - out.count))
            return out.count < count
        }
        return out
    }
}

/// Walks a tar or cpio archive as its bytes arrive: lists every entry and keeps the contents of the ones asked for.
final class ArchiveScanner {
    enum Format { case tar, cpio }
    struct Entry { var name: String; var size: Int; var mode: Int; var isDir: Bool; var link: String? }

    let format: Format
    var entries: [Entry] = []
    var total = 0
    var totalBytes = 0
    var kept: [String: Data] = [:]
    var keptBytes = 0
    var finished = false
    /// Return true to keep this file's bytes.
    var want: (String, Int) -> Bool = { _, _ in false }
    /// Checked after each entry; return true to stop early.
    var enough: (ArchiveScanner) -> Bool = { _ in false }
    var listLimit = 200_000
    var keepLimit = 48 << 20

    private var pending = [UInt8]()
    private var need = 0
    private var skip = 0
    private var collecting: (name: String, left: Int, pad: Int, data: Data, special: UInt8)?
    private var longName: String?
    private var stopped = false

    init(_ format: Format) {
        self.format = format
        need = format == .tar ? 512 : 6
    }

    static func isTarHeader(_ d: Data) -> Bool {
        guard d.count >= 512 else { return false }
        let r = Reader(d)
        if r.fixedStr(257, 5) == "ustar" { return true }
        // Old tar: verify the header checksum.
        guard let stored = Int(r.fixedStr(148, 8).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8), stored > 0 else { return false }
        var sum = 0
        for i in 0..<512 { sum += (148..<156).contains(i) ? 32 : Int(r.u8(i)) }
        return sum == stored
    }

    /// Feed the next piece. Returns false when no more input is wanted.
    func feed(_ buf: UnsafeRawBufferPointer) -> Bool {
        var i = 0
        let n = buf.count
        while i < n, !finished, !stopped {
            if var c = collecting {
                let take = Swift.min(c.left, n - i)
                c.data.append(contentsOf: UnsafeRawBufferPointer(rebasing: buf[i..<(i + take)]))
                c.left -= take
                i += take
                if c.left == 0 {
                    collecting = nil
                    skip = c.pad
                    finishCollected(c.name, c.data, special: c.special)
                } else { collecting = c }
                continue
            }
            if skip > 0 {
                let take = Swift.min(skip, n - i)
                skip -= take
                i += take
                continue
            }
            let take = Swift.min(need - pending.count, n - i)
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: buf[i..<(i + take)]))
            i += take
            if pending.count == need { header() }
        }
        return !finished && !stopped
    }

    private func finishCollected(_ name: String, _ data: Data, special: UInt8) {
        switch special {
        case UInt8(ascii: "L"):
            longName = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        case UInt8(ascii: "x"):
            // pax records: "<length> key=value\n"
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if let sp = line.firstIndex(of: " "), line[line.index(after: sp)...].hasPrefix("path=") { longName = String(line[line.index(after: sp)...].dropFirst(5)) }
            }
        default:
            kept[name] = data
            keptBytes += data.count
            if enough(self) { stopped = true }
        }
    }

    private func add(_ e: Entry, pad: Int) {
        total += 1
        totalBytes += e.size
        if entries.count < listLimit { entries.append(e) }
        if !e.isDir, e.link == nil, e.size > 0, e.size <= 16 << 20, keptBytes + e.size <= keepLimit, want(e.name, e.size) {
            collecting = (e.name, e.size, pad, Data(capacity: e.size), 0)
        } else {
            skip = e.size + pad
            if enough(self) { stopped = true }
        }
    }

    private func clean(_ s: String) -> String {
        var s = s
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    private func header() {
        let h = Reader(Data(pending), little: false)
        if format == .tar {
            pending.removeAll(keepingCapacity: true)
            if h.data.allSatisfy({ $0 == 0 }) { finished = true; return }
            var size = 0
            if h.u8(124) & 0x80 != 0 { for k in 125..<136 { size = size << 8 | Int(h.u8(k)) } }
            else { size = Int(h.fixedStr(124, 12).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0 }
            let pad = (512 - size % 512) % 512
            let type = h.u8(156)
            if type == UInt8(ascii: "L") || type == UInt8(ascii: "x") {
                guard size <= 1 << 20 else { skip = size + pad; return }
                if size == 0 { skip = pad; return }
                collecting = ("", size, pad, Data(capacity: size), type)
                return
            }
            if type == UInt8(ascii: "K") || type == UInt8(ascii: "g") { skip = size + pad; return }
            var name = h.fixedStr(0, 100)
            if h.fixedStr(257, 5) == "ustar", h.u8(263) != 0x20 || h.u8(262) == 0 {
                let prefix = h.fixedStr(345, 155)
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            if let l = longName { name = l; longName = nil }
            guard !name.isEmpty else { finished = true; return }
            let mode = Int(h.fixedStr(100, 8).trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) ?? 0
            let isDir = type == UInt8(ascii: "5") || name.hasSuffix("/")
            let link: String? = (type == UInt8(ascii: "1") || type == UInt8(ascii: "2")) ? h.fixedStr(157, 100) : nil
            let isFile = type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7")
            var nm = clean(name)
            if isDir, nm.hasSuffix("/") { nm.removeLast() }
            if nm.isEmpty { skip = (isFile ? size : 0) + (isFile ? pad : 0); return }
            add(Entry(name: nm, size: isFile ? size : 0, mode: mode, isDir: isDir, link: link), pad: isFile ? pad : 0)
            if !isFile { skip = 0 }
            return
        }
        // cpio: the header comes in two steps (fixed part, then the name).
        let magic = h.fixedStr(0, 6)
        let newc = magic == "070701" || magic == "070702"
        let odc = magic == "070707"
        guard newc || odc else { finished = true; return }
        let fixed = newc ? 110 : 76
        if pending.count < fixed { need = fixed; return }
        func hex(_ at: Int) -> Int { Int(h.fixedStr(at, 8), radix: 16) ?? 0 }
        func oct(_ at: Int, _ len: Int) -> Int { Int(h.fixedStr(at, len), radix: 8) ?? 0 }
        let nameSize = newc ? hex(94) : oct(59, 6)
        guard nameSize > 0, nameSize <= 8192 else { finished = true; return }
        let full = newc ? (fixed + nameSize + 3) & ~3 : fixed + nameSize
        if pending.count < full { need = full; return }
        let size = newc ? hex(54) : oct(65, 11)
        let mode = newc ? hex(14) : oct(18, 6)
        let name = h.fixedStr(fixed, nameSize)
        pending.removeAll(keepingCapacity: true)
        need = 6
        if name == "TRAILER!!!" { finished = true; return }
        let pad = newc ? (4 - size % 4) % 4 : 0
        let kind = mode & 0o170000
        let nm = clean(name)
        if nm.isEmpty || nm == "." { skip = size + pad; return }
        if kind == 0o120000 {
            // The link target is the body; it is short, but not worth keeping.
            total += 1
            if entries.count < listLimit { entries.append(Entry(name: nm, size: 0, mode: mode, isDir: false, link: "")) }
            skip = size + pad
            return
        }
        add(Entry(name: nm, size: kind == 0o100000 ? size : 0, mode: mode & 0o7777, isDir: kind == 0o040000, link: nil), pad: pad)
        if kind != 0o100000 { skip = size + pad }
    }
}
