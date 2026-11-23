import Foundation

/// Read-only FAT12 / FAT16 / FAT32: floppy images, EFI system partitions, SD cards.
final class FAT {
    struct Item { var name: String; var isDir: Bool; var size: Int; var cluster: Int }

    let dev: BlockDevice
    var bytesPerSector = 512
    var sectorsPerCluster = 1
    var fatStart = 0
    var fatSize = 0
    var rootStart = 0          // FAT12/16: fixed root directory
    var rootEntries = 0
    var dataStart = 0
    var rootCluster = 0        // FAT32
    var bits = 12
    var label = ""
    var totalBytes = 0
    /// Who formatted the disk ("NEC  5.0", "MSDOS5.0", "IBM  20.0").
    var oem = ""
    private var fat = Data()

    /// DOS names are in the machine's code page; Japanese DOS used Shift-JIS.
    static func name(_ d: Data) -> String {
        let t: String
        if d.contains(where: { $0 >= 0x80 }), let s = String(data: d, encoding: .shiftJIS) { t = s } else { t = String(decoding: d, as: Unicode.ASCII.self) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    init?(_ device: BlockDevice) {
        dev = device
        guard let b = dev.reader(0, 512, little: true) else { return nil }
        var bps = Int(b.u16(11)), spc = Int(b.u8(13)), reserved = Int(b.u16(14)), nfats = Int(b.u8(16))
        var rootCnt = Int(b.u16(17)), total = Int(b.u16(19)), fatsz = Int(b.u16(22))
        if total == 0 { total = Int(b.u32(32)) }
        let jump = b.u8(0)
        var valid = (jump == 0xeb || jump == 0xe9) && [256, 512, 1024, 2048, 4096].contains(bps) && spc > 0 && spc & (spc - 1) == 0 && reserved > 0 && (1...2).contains(nfats) && b.u8(21) >= 0xf0
        if !valid {
            // DOS 1.x floppies have no parameter block: the geometry follows from the media byte in the FAT.
            // PC-98 1.25 MB floppies written by early DOS versions: 1024-byte sectors, no parameter block.
            if dev.size == 1_261_568, let f = dev.reader(1024, 3), f.u8(0) == 0xfe, f.u8(1) == 0xff, f.u8(2) == 0xff {
                bps = 1024; spc = 1; reserved = 1; nfats = 2; rootCnt = 192; fatsz = 2; total = 1232
                valid = true
            }
            guard valid || (dev.reader(512, 3).map { $0.u8(1) == 0xff && $0.u8(2) == 0xff } == true && dev.size <= 370_000) else { return nil }
            if !valid, let f = dev.reader(512, 3) {
            let table: [UInt8: (Int, Int, Int)] = [0xfe: (1, 64, 1), 0xfc: (2, 64, 1), 0xff: (1, 112, 2), 0xfd: (2, 112, 2)]   // FAT sectors, root entries, sectors per cluster
            guard let g = table[f.u8(0)] else { return nil }
            bps = 512; spc = g.2; reserved = 1; nfats = 2; rootCnt = g.1; fatsz = g.0; total = dev.size / 512
            valid = true
            }
        }
        oem = PC98.text(b.bytes(3, 8))
        bytesPerSector = bps; sectorsPerCluster = spc
        fatStart = reserved * bps
        if fatsz == 0 { fatsz = Int(b.u32(36)); rootCluster = Int(b.u32(44)) }
        fatSize = fatsz * bps
        rootEntries = rootCnt
        rootStart = fatStart + nfats * fatSize
        dataStart = rootStart + rootCnt * 32
        if dataStart % bps != 0 { dataStart += bps - dataStart % bps }
        totalBytes = total * bps
        let clusters = Swift.max(0, (total * bps - dataStart) / (spc * bps))
        bits = rootCluster != 0 && rootCnt == 0 ? 32 : clusters < 4085 ? 12 : 16
        guard fatSize > 0, fatSize <= 64 << 20, let f = dev.read(fatStart, Swift.min(fatSize, dev.size - fatStart)) else { return nil }
        fat = f
        guard !list().isEmpty || !label.isEmpty else { return nil }
    }

    private func next(_ c: Int) -> Int {
        let r = Reader(fat, little: true)
        switch bits {
        case 12:
            let v = Int(r.u16(c * 3 / 2))
            let n = c & 1 == 0 ? v & 0xfff : v >> 4
            return n >= 0xff8 ? -1 : n
        case 16:
            let n = Int(r.u16(c * 2))
            return n >= 0xfff8 ? -1 : n
        default:
            let n = Int(r.u32(c * 4) & 0x0fff_ffff)
            return n >= 0x0fff_fff8 ? -1 : n
        }
    }

    private func chain(_ start: Int, max: Int) -> Data? {
        var out = Data()
        var c = start
        let csize = sectorsPerCluster * bytesPerSector
        var hops = 0
        while c >= 2, out.count < max, hops < 1_000_000 {
            guard let d = dev.read(dataStart + (c - 2) * csize, csize) else { return nil }
            out.append(d)
            c = next(c)
            hops += 1
        }
        return out
    }

    private func parse(_ d: Data) -> [Item] {
        let r = Reader(d, little: true)
        var out = [Item]()
        var long = [UInt16]()
        var o = 0
        while o + 32 <= d.count, out.count < 5000 {
            defer { o += 32 }
            let first = r.u8(o), attr = r.u8(o + 11)
            if first == 0 { break }
            if first == 0xe5 { long = []; continue }
            if attr == 0x0f {   // long file name piece (stored last piece first)
                var part = [UInt16]()
                for k in [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30] { part.append(r.u16(o + k)) }
                long = part + long
                continue
            }
            var base = FAT.name(r.bytes(o, 8))
            let ext = FAT.name(r.bytes(o + 8, 3))
            if attr & 0x08 != 0 {
                if attr & 0x10 == 0, label.isEmpty { label = FAT.name(r.bytes(o, 11)) }
                long = []
                continue
            }
            if base == "." || base == ".." { long = []; continue }
            if first == 0x05 { base = "\u{e5}" + base.dropFirst() }
            var name = ext.isEmpty ? base : base + "." + ext
            if !long.isEmpty {
                let cut = long.firstIndex(of: 0).map { Array(long[..<$0]) } ?? long
                let s = String(decoding: cut.filter { $0 != 0xffff }, as: UTF16.self)
                if !s.isEmpty { name = s }
            }
            long = []
            out.append(Item(name: name, isDir: attr & 0x10 != 0, size: Int(r.u32(o + 28)), cluster: Int(r.u16(o + 26)) | (bits == 32 ? Int(r.u16(o + 20)) << 16 : 0)))
        }
        return out
    }

    func list(_ dir: Item? = nil) -> [Item] {
        if let dir { return chain(dir.cluster, max: 4 << 20).map(parse) ?? [] }
        if bits == 32 { return chain(rootCluster, max: 4 << 20).map(parse) ?? [] }
        return dev.read(rootStart, rootEntries * 32).map(parse) ?? []
    }

    func item(_ path: String) -> Item? {
        var cur: Item?
        for part in path.split(separator: "/") {
            guard let n = list(cur).first(where: { $0.name.caseInsensitiveCompare(String(part)) == .orderedSame }) else { return nil }
            cur = n
        }
        return cur
    }

    func read(_ i: Item, max: Int = 8 << 20) -> Data? {
        guard !i.isDir, i.size <= max else { return nil }
        if i.size == 0 { return Data() }
        return chain(i.cluster, max: i.size).map { $0.prefix(i.size) }.map { Data($0) }
    }
}
