import Foundation

/// Zstandard decoder (RFC 8878). The system has no public zstd library, and newer Linux packages,
/// kernel modules and SquashFS images are compressed with it. Dictionaries are not supported.
enum Zstd {
    static func isZstd(_ r: Reader, _ o: Int = 0) -> Bool { r.le32(o) == 0xfd2f_b528 }

    // MARK: bit reading

    /// `num` bits (at most 56) starting at bit `off`, little-endian.
    @inline(__always) static func bits(_ p: UnsafePointer<UInt8>, _ n: Int, _ off: Int, _ num: Int) -> Int {
        if num <= 0 { return 0 }
        let byte = off >> 3
        var v: UInt64 = 0
        if byte + 8 <= n {
            v = UnsafeRawPointer(p + byte).loadUnaligned(as: UInt64.self).littleEndian
        } else {
            var i = 0
            while i < 8, byte + i < n { v |= UInt64(p[byte + i]) << UInt64(8 * i); i += 1 }
        }
        v >>= UInt64(off & 7)
        return Int(v & ((1 << UInt64(num)) - 1))
    }

    /// A stream read from its end towards its start; the highest set bit of the last byte marks where data begins.
    struct Back {
        let p: UnsafePointer<UInt8>
        let n: Int
        var off: Int
        init?(_ p: UnsafePointer<UInt8>, _ n: Int) {
            guard n > 0, p[n - 1] != 0 else { return nil }
            self.p = p
            self.n = n
            off = n * 8 - p[n - 1].leadingZeroBitCount - 1
        }
        @inline(__always) mutating func read(_ num: Int) -> Int {
            off -= num
            if off >= 0 { return Zstd.bits(p, n, off, num) }
            let actual = num + off
            return actual > 0 ? Zstd.bits(p, n, 0, actual) << (-off) : 0
        }
        /// Like `read`, without moving.
        @inline(__always) func peek(_ num: Int) -> Int {
            let o = off - num
            if o >= 0 { return Zstd.bits(p, n, o, num) }
            let actual = num + o
            return actual > 0 ? Zstd.bits(p, n, 0, actual) << (-o) : 0
        }
    }

    @inline(__always) static func highbit(_ v: Int) -> Int { v <= 0 ? 0 : 63 - v.leadingZeroBitCount }

    // MARK: FSE

    struct FSE {
        var symbol: [UInt8]
        var nbits: [UInt8]
        var base: [UInt16]
        var log: Int
        static func rle(_ s: UInt8) -> FSE { FSE(symbol: [s], nbits: [0], base: [0], log: 0) }
    }

    static func buildFSE(_ freqs: [Int], log: Int) -> FSE? {
        let size = 1 << log
        var symbol = [UInt8](repeating: 0, count: size), nbits = [UInt8](repeating: 0, count: size), base = [UInt16](repeating: 0, count: size)
        var desc = [Int](repeating: 0, count: freqs.count)
        var high = size
        for (s, f) in freqs.enumerated() where f == -1 {
            high -= 1
            guard high >= 0 else { return nil }
            symbol[high] = UInt8(s)
            desc[s] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3, mask = size - 1
        var pos = 0
        for (s, f) in freqs.enumerated() where f > 0 {
            desc[s] = f
            for _ in 0..<f {
                symbol[pos] = UInt8(s)
                repeat { pos = (pos + step) & mask } while pos >= high
            }
        }
        guard pos == 0 else { return nil }
        for i in 0..<size {
            let s = Int(symbol[i])
            let d = desc[s]
            desc[s] += 1
            let nb = log - highbit(d)
            nbits[i] = UInt8(nb)
            base[i] = UInt16((d << nb) - size)
        }
        return FSE(symbol: symbol, nbits: nbits, base: base, log: log)
    }

    /// Reads a table description; returns the table and the bytes it took.
    static func readFSE(_ p: UnsafePointer<UInt8>, _ n: Int, maxLog: Int, maxSymbol: Int) -> (FSE, Int)? {
        guard n >= 1 else { return nil }
        let log = bits(p, n, 0, 4) + 5
        guard log <= maxLog else { return nil }
        var bit = 4
        var remaining = 1 << log
        var freqs = [Int]()
        while remaining > 0, freqs.count <= maxSymbol {
            let nb = highbit(remaining + 1) + 1
            var val = bits(p, n, bit, nb)
            let lower = (1 << (nb - 1)) - 1
            let threshold = (1 << nb) - 1 - (remaining + 1)
            if (val & lower) < threshold { bit += nb - 1; val &= lower }
            else { bit += nb; if val > lower { val -= threshold } }
            let proba = val - 1
            remaining -= proba < 0 ? 1 : proba
            freqs.append(proba)
            if proba == 0 {
                var rep = bits(p, n, bit, 2)
                bit += 2
                while true {
                    for _ in 0..<rep { freqs.append(0) }
                    if rep == 3 { rep = bits(p, n, bit, 2); bit += 2 } else { break }
                    if freqs.count > maxSymbol + 1 { return nil }
                }
            }
            if bit > n * 8 { return nil }
        }
        guard remaining == 0, freqs.count <= maxSymbol + 1 else { return nil }
        guard let t = buildFSE(freqs, log: log) else { return nil }
        return (t, (bit + 7) / 8)
    }

    // MARK: Huffman

    struct Huffman {
        var symbol: [UInt8]
        var nbits: [UInt8]
        var maxBits: Int
    }

    static func readHuffman(_ p: UnsafePointer<UInt8>, _ n: Int) -> (Huffman, Int)? {
        guard n >= 1 else { return nil }
        let h = Int(p[0])
        var weights = [UInt8]()
        var consumed = 0
        if h >= 128 {
            let count = h - 127, bytes = (count + 1) / 2
            guard 1 + bytes <= n else { return nil }
            for i in 0..<count {
                let b = p[1 + i / 2]
                weights.append(i % 2 == 0 ? b >> 4 : b & 0xf)
            }
            consumed = 1 + bytes
        } else {
            guard h > 0, 1 + h <= n, let (t, used) = readFSE(p + 1, h, maxLog: 6, maxSymbol: 255), used < h, var bs = Back(p + 1 + used, h - used) else { return nil }
            var s1 = bs.read(t.log), s2 = bs.read(t.log)
            while weights.count < 255 {
                weights.append(t.symbol[s1])
                s1 = Int(t.base[s1]) + bs.read(Int(t.nbits[s1]))
                if bs.off < 0 { weights.append(t.symbol[s2]); break }
                weights.append(t.symbol[s2])
                s2 = Int(t.base[s2]) + bs.read(Int(t.nbits[s2]))
                if bs.off < 0 { weights.append(t.symbol[s1]); break }
            }
            consumed = 1 + h
        }
        var sum = 0
        for w in weights where w > 0 { guard w <= 12 else { return nil }; sum += 1 << (Int(w) - 1) }
        guard sum > 0, weights.count <= 255 else { return nil }
        let maxBits = highbit(sum) + 1
        let left = (1 << maxBits) - sum
        guard maxBits <= 11, left > 0, left & (left - 1) == 0 else { return nil }
        weights.append(UInt8(highbit(left) + 1))
        var rankCount = [Int](repeating: 0, count: maxBits + 2)
        var lens = [Int](repeating: 0, count: weights.count)
        for (i, w) in weights.enumerated() where w > 0 { lens[i] = maxBits + 1 - Int(w); rankCount[lens[i]] += 1 }
        var rankIdx = [Int](repeating: 0, count: maxBits + 2)
        var i = maxBits
        while i >= 1 { rankIdx[i - 1] = rankIdx[i] + rankCount[i] * (1 << (maxBits - i)); i -= 1 }
        let size = 1 << maxBits
        var symbol = [UInt8](repeating: 0, count: size), nbits = [UInt8](repeating: 0, count: size)
        for (s, l) in lens.enumerated() where l > 0 {
            let len = 1 << (maxBits - l)
            guard rankIdx[l] + len <= size else { return nil }
            for k in rankIdx[l]..<(rankIdx[l] + len) { symbol[k] = UInt8(s); nbits[k] = UInt8(l) }
            rankIdx[l] += len
        }
        return (Huffman(symbol: symbol, nbits: nbits, maxBits: maxBits), consumed)
    }

    static func huffmanStream(_ h: Huffman, _ p: UnsafePointer<UInt8>, _ n: Int, count: Int, into out: inout [UInt8]) -> Bool {
        guard var bs = Back(p, n) else { return false }
        let mb = h.maxBits
        return h.symbol.withUnsafeBufferPointer { sym in
            h.nbits.withUnsafeBufferPointer { nb in
                for _ in 0..<count {
                    let idx = bs.peek(mb)
                    out.append(sym[idx])
                    bs.off -= Int(nb[idx])
                    if bs.off < -mb { return false }
                }
                return true
            }
        }
    }

    // MARK: sequences

    static let llBase: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let llBits: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let mlBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
                                35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
    static let mlBits: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    static let llDefault = buildFSE([4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1], log: 6)!
    static let mlDefault = buildFSE([1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                     -1, -1, -1, -1, -1, -1, -1], log: 6)!
    static let ofDefault = buildFSE([1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1], log: 5)!

    struct State {
        var huffman: Huffman?
        var ll: FSE?, of: FSE?, ml: FSE?
        var rep = [1, 4, 8]
        /// Everything produced so far that later matches may still refer to.
        var out = [UInt8]()
        var lits = [UInt8]()
    }

    /// Decodes one compressed block, appending to `st.out`.
    static func block(_ p: UnsafePointer<UInt8>, _ n: Int, _ st: inout State) -> Bool {
        guard n >= 1 else { return false }
        // ---- literals
        let b0 = Int(p[0])
        let type = b0 & 3, sf = (b0 >> 2) & 3
        st.lits.removeAll(keepingCapacity: true)
        var used = 0
        if type < 2 {
            var regen = 0, hs = 1
            switch sf {
            case 1: guard n >= 2 else { return false }; regen = (b0 >> 4) + (Int(p[1]) << 4); hs = 2
            case 3: guard n >= 3 else { return false }; regen = (b0 >> 4) + (Int(p[1]) << 4) + (Int(p[2]) << 12); hs = 3
            default: regen = b0 >> 3
            }
            if type == 0 {
                guard hs + regen <= n else { return false }
                st.lits.append(contentsOf: UnsafeBufferPointer(start: p + hs, count: regen))
                used = hs + regen
            } else {
                guard hs + 1 <= n else { return false }
                st.lits.append(contentsOf: repeatElement(p[hs], count: regen))
                used = hs + 1
            }
        } else {
            var regen = 0, comp = 0, hs = 3
            guard n >= 5 || (sf < 2 && n >= 3) || (sf == 2 && n >= 4) else { return false }
            switch sf {
            case 0, 1:
                let v = b0 | Int(p[1]) << 8 | Int(p[2]) << 16
                regen = (v >> 4) & 0x3ff; comp = (v >> 14) & 0x3ff
            case 2:
                let v = b0 | Int(p[1]) << 8 | Int(p[2]) << 16 | Int(p[3]) << 24
                regen = (v >> 4) & 0x3fff; comp = (v >> 18) & 0x3fff; hs = 4
            default:
                let v = b0 | Int(p[1]) << 8 | Int(p[2]) << 16 | Int(p[3]) << 24 | Int(p[4]) << 32
                regen = (v >> 4) & 0x3ffff; comp = (v >> 22) & 0x3ffff; hs = 5
            }
            guard hs + comp <= n, regen <= 1 << 18 else { return false }
            var q = p + hs, m = comp
            if type == 2 {
                guard let (h, c) = readHuffman(q, m) else { return false }
                st.huffman = h
                q += c; m -= c
            }
            guard let h = st.huffman, m > 0 else { return false }
            st.lits.reserveCapacity(regen)
            if sf == 0 {
                guard huffmanStream(h, q, m, count: regen, into: &st.lits) else { return false }
            } else {
                guard m >= 6 else { return false }
                let s1 = Int(q[0]) | Int(q[1]) << 8, s2 = Int(q[2]) | Int(q[3]) << 8, s3 = Int(q[4]) | Int(q[5]) << 8
                let s4 = m - 6 - s1 - s2 - s3
                guard s4 > 0, s1 > 0, s2 > 0, s3 > 0 else { return false }
                let each = (regen + 3) / 4
                guard regen - 3 * each >= 0 else { return false }
                var at = q + 6
                for (size, count) in [(s1, each), (s2, each), (s3, each), (s4, regen - 3 * each)] {
                    guard huffmanStream(h, at, size, count: count, into: &st.lits) else { return false }
                    at += size
                }
            }
            used = hs + comp
        }

        // ---- sequences
        var q = p + used, m = n - used
        guard m >= 1 else { return false }
        var nseq = Int(q[0])
        if nseq == 0 { st.out.append(contentsOf: st.lits); return true }
        if nseq < 128 { q += 1; m -= 1 }
        else if nseq < 255 { guard m >= 2 else { return false }; nseq = ((nseq - 128) << 8) + Int(q[1]); q += 2; m -= 2 }
        else { guard m >= 3 else { return false }; nseq = Int(q[1]) + (Int(q[2]) << 8) + 0x7f00; q += 3; m -= 3 }
        guard m >= 1 else { return false }
        let modes = Int(q[0])
        q += 1; m -= 1
        func table(_ mode: Int, _ def: FSE, _ prev: FSE?, maxLog: Int, maxSymbol: Int) -> FSE? {
            switch mode {
            case 0: return def
            case 1:
                guard m >= 1 else { return nil }
                let t = FSE.rle(q[0]); q += 1; m -= 1
                return t
            case 2:
                guard let (t, c) = readFSE(q, m, maxLog: maxLog, maxSymbol: maxSymbol) else { return nil }
                q += c; m -= c
                return t
            default: return prev
            }
        }
        guard let ll = table(modes >> 6, llDefault, st.ll, maxLog: 9, maxSymbol: 35),
              let of = table((modes >> 4) & 3, ofDefault, st.of, maxLog: 8, maxSymbol: 31),
              let ml = table((modes >> 2) & 3, mlDefault, st.ml, maxLog: 9, maxSymbol: 52) else { return false }
        st.ll = ll; st.of = of; st.ml = ml
        guard m > 0, var bs = Back(q, m) else { return false }
        var sl = bs.read(ll.log), so = bs.read(of.log), sm = bs.read(ml.log)
        var lit = 0
        let lits = st.lits
        for i in 0..<nseq {
            let oc = Int(of.symbol[so]), lc = Int(ll.symbol[sl]), mc = Int(ml.symbol[sm])
            guard oc <= 31, lc <= 35, mc <= 52 else { return false }
            let ov = (1 << oc) + bs.read(oc)
            let mlen = mlBase[mc] + bs.read(mlBits[mc])
            let llen = llBase[lc] + bs.read(llBits[lc])
            if i + 1 < nseq {
                sl = Int(ll.base[sl]) + bs.read(Int(ll.nbits[sl]))
                sm = Int(ml.base[sm]) + bs.read(Int(ml.nbits[sm]))
                so = Int(of.base[so]) + bs.read(Int(of.nbits[so]))
            }
            if bs.off < -64 { return false }
            var offset: Int
            if ov > 3 {
                offset = ov - 3
                st.rep[2] = st.rep[1]; st.rep[1] = st.rep[0]; st.rep[0] = offset
            } else {
                let idx = ov + (llen == 0 ? 1 : 0)
                switch idx {
                case 1: offset = st.rep[0]
                case 2: offset = st.rep[1]; st.rep[1] = st.rep[0]; st.rep[0] = offset
                case 3: offset = st.rep[2]; st.rep[2] = st.rep[1]; st.rep[1] = st.rep[0]; st.rep[0] = offset
                default: offset = st.rep[0] - 1; st.rep[2] = st.rep[1]; st.rep[1] = st.rep[0]; st.rep[0] = offset
                }
            }
            guard lit + llen <= lits.count else { return false }
            st.out.append(contentsOf: lits[lit..<(lit + llen)])
            lit += llen
            guard offset > 0, offset <= st.out.count else { return false }
            let start = st.out.count - offset
            // Grow first, then copy in place (a slice of the array itself would force a full copy of it).
            st.out.append(contentsOf: repeatElement(0, count: mlen))
            st.out.withUnsafeMutableBufferPointer { b in
                let q = b.baseAddress!
                if offset >= mlen { memcpy(q + start + offset, q + start, mlen) }
                else { for k in 0..<mlen { q[start + offset + k] = q[start + k] } }
            }
        }
        if lit < lits.count { st.out.append(contentsOf: lits[lit...]) }
        return true
    }

    // MARK: frames

    /// Decodes the frames in `data[start ..< start+length]`, handing each block's output to `sink`
    /// until it returns false or `deadline` passes. Returns true when the input was decoded to its end.
    @discardableResult
    static func stream(_ data: Data, at start: Int = 0, length: Int? = nil, deadline: Date? = nil, sink: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        let total = Swift.min(length ?? (data.count - start), data.count - start)
        guard total >= 8, start >= 0 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            let p = raw.bindMemory(to: UInt8.self).baseAddress! + start
            var o = 0
            func le32(_ at: Int) -> UInt32 { UInt32(p[at]) | UInt32(p[at + 1]) << 8 | UInt32(p[at + 2]) << 16 | UInt32(p[at + 3]) << 24 }
            var any = false
            while o + 4 <= total {
                let magic = le32(o)
                if magic & 0xffff_fff0 == 0x184d_2a50 {   // skippable frame
                    guard o + 8 <= total else { return false }
                    o += 8 + Int(le32(o + 4))
                    continue
                }
                guard magic == 0xfd2f_b528, o + 6 <= total else { return any }
                any = true
                let fhd = Int(p[o + 4])
                o += 5
                let single = fhd & 0x20 != 0
                var window = 0
                if !single {
                    let wd = Int(p[o]); o += 1
                    let base = 1 << (10 + (wd >> 3))
                    window = base + (base >> 3) * (wd & 7)
                }
                let dictSize = [0, 1, 2, 4][fhd & 3]
                if dictSize > 0 {
                    guard o + dictSize <= total else { return false }
                    var id = 0
                    for i in 0..<dictSize { id |= Int(p[o + i]) << (8 * i) }
                    if id != 0 { return false }   // needs an external dictionary
                    o += dictSize
                }
                let fcsSize = [single ? 1 : 0, 2, 4, 8][fhd >> 6]
                guard o + fcsSize <= total else { return false }
                var fcs = 0
                for i in 0..<fcsSize { fcs |= Int(p[o + i]) << (8 * i) }
                if fcsSize == 2 { fcs += 256 }
                o += fcsSize
                if single { window = fcs }
                window = Swift.max(window, 1 << 17)
                guard window <= 1 << 30 else { return false }
                var st = State()
                var emitted = 0   // index into st.out already handed to the sink
                var last = false
                while !last {
                    guard o + 3 <= total else { return false }
                    let bh = Int(p[o]) | Int(p[o + 1]) << 8 | Int(p[o + 2]) << 16
                    o += 3
                    last = bh & 1 != 0
                    let type = (bh >> 1) & 3, size = bh >> 3
                    switch type {
                    case 0:
                        guard o + size <= total else { return false }
                        st.out.append(contentsOf: UnsafeBufferPointer(start: p + o, count: size))
                        o += size
                    case 1:
                        guard o + 1 <= total, size <= 1 << 17 else { return false }
                        st.out.append(contentsOf: repeatElement(p[o], count: size))
                        o += 1
                    case 2:
                        guard o + size <= total, size <= 1 << 17, block(p + o, size, &st) else { return false }
                        o += size
                    default: return false
                    }
                    let go = st.out.withUnsafeBytes { sink(UnsafeRawBufferPointer(rebasing: $0[emitted...])) }
                    emitted = st.out.count
                    if !go { return false }
                    if let deadline, Date() > deadline { return false }
                    // Keep only what later matches can still reach.
                    if st.out.count > window * 2 + (8 << 20) {
                        st.out.removeFirst(st.out.count - window)
                        emitted = st.out.count
                    }
                }
                if fhd & 4 != 0 { o += 4 }   // content checksum
            }
            return any
        }
    }

    /// Whole-buffer decode, refusing outputs larger than `max`.
    static func decode(_ data: Data, max: Int = 512 << 20) -> Data? {
        var out = Data()
        var tooBig = false
        let ok = stream(data) { chunk in
            if out.count + chunk.count > max { tooBig = true; return false }
            out.append(contentsOf: chunk)
            return true
        }
        return ok && !tooBig ? out : nil
    }
}
