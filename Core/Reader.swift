import Foundation

/// Bounds-checked reader over a (memory-mapped) file. Out-of-range reads return 0.
struct Reader {
    let data: Data
    var little: Bool

    init(_ data: Data, little: Bool = true) {
        self.data = data
        self.little = little
    }

    var count: Int { data.count }

    func ok(_ o: Int, _ n: Int) -> Bool { o >= 0 && n >= 0 && o <= data.count - n }

    func u8(_ o: Int) -> UInt8 {
        guard ok(o, 1) else { return 0 }
        return data[data.startIndex + o]
    }

    private func load<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
        let n = MemoryLayout<T>.size
        guard ok(o, n) else { return 0 }
        let v: T = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: T.self) }
        return little ? T(littleEndian: v) : T(bigEndian: v)
    }

    func u16(_ o: Int) -> UInt16 { load(o, UInt16.self) }
    func u32(_ o: Int) -> UInt32 { load(o, UInt32.self) }
    func u64(_ o: Int) -> UInt64 { load(o, UInt64.self) }
    func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }

    func be16(_ o: Int) -> UInt16 { var r = self; r.little = false; return r.u16(o) }
    func be32(_ o: Int) -> UInt32 { var r = self; r.little = false; return r.u32(o) }
    func be64(_ o: Int) -> UInt64 { var r = self; r.little = false; return r.u64(o) }
    func le16(_ o: Int) -> UInt16 { var r = self; r.little = true; return r.u16(o) }
    func le32(_ o: Int) -> UInt32 { var r = self; r.little = true; return r.u32(o) }

    func bytes(_ o: Int, _ n: Int) -> Data {
        guard ok(o, n), n > 0 else { return Data() }
        return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + n))
    }

    /// NUL-terminated string.
    func cstr(_ o: Int, max: Int = 4096) -> String {
        guard o >= 0, o < data.count else { return "" }
        let end = Swift.min(data.count, o + max)
        var e = o
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            while e < end, p[e] != 0 { e += 1 }
        }
        return Reader.decode(bytes(o, e - o))
    }

    /// Fixed-width field, trimmed at the first NUL.
    func fixedStr(_ o: Int, _ n: Int) -> String {
        let d = bytes(o, n)
        let cut = d.firstIndex(of: 0).map { d.distance(from: d.startIndex, to: $0) } ?? d.count
        return Reader.decode(d.prefix(cut))
    }

    func utf16(_ o: Int, units: Int) -> String {
        guard units > 0, ok(o, units * 2) else { return "" }
        var a = [UInt16]()
        a.reserveCapacity(units)
        for i in 0..<units { a.append(le16(o + i * 2)) }
        return String(decoding: a, as: UTF16.self)
    }

    static func decode(_ d: Data) -> String {
        String(data: d, encoding: .utf8) ?? String(decoding: d, as: Unicode.ASCII.self)
    }
}

func hex<T: BinaryInteger>(_ v: T, pad: Int = 0) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: Swift.max(0, pad - s.count)) + s
}

func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

func byteSize(_ n: Int) -> String {
    if n < 1024 { return "\(n) B" }
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: Int64(n))
}

func byteSizeExact(_ n: Int) -> String {
    let nf = NumberFormatter()
    nf.numberStyle = .decimal
    let exact = (nf.string(from: NSNumber(value: n)) ?? "\(n)") + " B"
    return n < 1024 ? exact : "\(byteSize(n)) (\(exact))"
}

func dateString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: d)
}

/// Shannon entropy (bits/byte) over at most `cap` bytes, sampled evenly.
func entropy(_ r: Reader, _ off: Int, _ size: Int, cap: Int = 1 << 20) -> Double? {
    guard size > 0, r.ok(off, size) else { return nil }
    var hist = [Int](repeating: 0, count: 256)
    let step = Swift.max(1, size / cap)
    var n = 0
    r.data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        var i = off
        while i < off + size {
            hist[Int(p[i])] += 1
            n += 1
            i += step
        }
    }
    var e = 0.0
    for c in hist where c > 0 {
        let q = Double(c) / Double(n)
        e -= q * log2(q)
    }
    return e
}

/// Printable ASCII runs in a region (used for the "strings" section).
func asciiStrings(_ r: Reader, _ off: Int, _ size: Int, minLen: Int = 6, cap: Int = 4000) -> [String] {
    guard size > 0, r.ok(off, size) else { return [] }
    var out = [String]()
    r.data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        var start = -1
        var i = off
        let end = off + size
        while i <= end {
            let c: UInt8 = i < end ? p[i] : 0
            if c >= 0x20 && c < 0x7f {
                if start < 0 { start = i }
            } else {
                if start >= 0, i - start >= minLen, out.count < cap {
                    let len = Swift.min(i - start, 400)
                    out.append(String(decoding: UnsafeRawBufferPointer(rebasing: p[start..<(start + len)]), as: Unicode.ASCII.self))
                }
                start = -1
                if out.count >= cap { break }
            }
            i += 1
        }
    }
    return out
}
