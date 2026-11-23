import Foundation

/// Disk images of NEC PC-9800 (and PC-8800) emulators: floppy formats FDI / D88 / NFD / DIM and raw
/// 1232 KB dumps (HDM), hard disk formats HDI / NHD / THD / Virtual98, and the PC-98's own partition table.
enum PC98 {
    struct Image {
        var device: BlockDevice
        var format: String
        var rows: [Row] = []
        /// Hard disks: cylinders, heads, sectors per track, bytes per sector.
        var geometry: (cylinders: Int, heads: Int, sectors: Int, sectorSize: Int)?
        var hardDisk = false
        var name = ""
    }

    static func text(_ d: Data) -> String {
        let cut = d.prefix { $0 != 0 }
        return (String(data: cut, encoding: .shiftJIS) ?? String(decoding: cut, as: Unicode.ASCII.self)).trimmingCharacters(in: .whitespaces)
    }

    static func floppyKind(_ size: Int, sectorSize: Int) -> String? {
        switch (size, sectorSize) {
        case (1_261_568, _): return L("2HD（1.25 MB、PC-98 標準）", "2HD (1.25 MB, PC-98 standard)")
        case (1_228_800, _): return L("2HC（1.2 MB）", "2HC (1.2 MB)")
        case (1_474_560, _): return L("2HD（1.44 MB）", "2HD (1.44 MB)")
        case (737_280, _): return L("2DD（720 KB）", "2DD (720 KB)")
        case (655_360, _): return L("2DD（640 KB）", "2DD (640 KB)")
        case (327_680, _), (348_160, _): return L("2D（320 KB、PC-88 系）", "2D (320 KB, PC-88 family)")
        default: return nil
        }
    }

    static func open(_ data: Data, ext: String) -> Image? {
        let r = Reader(data, little: true)
        let n = data.count
        guard n > 512 else { return nil }
        let file = DataDevice(data)
        func geomOK(_ ss: Int, _ spt: Int, _ heads: Int, _ cyl: Int) -> Bool { [256, 512, 1024, 2048].contains(ss) && (1...255).contains(spt) && (1...64).contains(heads) && (1...65535).contains(cyl) }

        // ---- T98-Next hard disk
        if r.fixedStr(0, 15) == "T98HDDIMAGE.R0" {
            let head = Int(r.u32(0x110)), cyl = Int(r.u32(0x114)), heads = Int(r.u16(0x118)), spt = Int(r.u16(0x11a)), ss = Int(r.u16(0x11c))
            guard head >= 512, head < n, geomOK(ss, spt, heads, cyl) else { return nil }
            var img = Image(device: SubDevice(parent: file, base: head, size: n - head), format: "NHD (T98-Next)", geometry: (cyl, heads, spt, ss), hardDisk: true)
            img.rows.add(L("コメント", "Comment"), text(r.bytes(0x10, 0x100)))
            return img
        }
        // ---- T98-Next floppy
        if r.fixedStr(0, 14) == "T98FDDIMAGE.R0" {
            let head = Int(r.u32(0x110))
            guard head >= 0x120, head <= n else { return nil }
            var out = Data()
            var sizes = Set<Int>(), odd = 0
            var o = 0x120
            var pos = head
            for _ in 0..<(163 * 26) {
                guard o + 16 <= head else { break }
                let c = r.u8(o), nn = Int(r.u8(o + 3))
                if c != 0xff, nn <= 7 {
                    let len = 128 << nn
                    guard pos + len <= n else { break }
                    out.append(r.bytes(pos, len)); pos += len
                    sizes.insert(len)
                    if r.u8(o + 5) != 0 || r.u8(o + 6) != 0 { odd += 1 }
                }
                o += 16
            }
            guard !out.isEmpty else { return nil }
            var img = Image(device: DataDevice(out), format: "NFD (T98-Next)")
            img.rows.add(L("コメント", "Comment"), text(r.bytes(0x10, 0x100)))
            img.rows.add(L("ディスクの種類", "Media"), floppyKind(out.count, sectorSize: sizes.first ?? 0))
            if odd > 0 { img.rows.add(L("特殊なセクター", "Unusual sectors"), L("\(odd) 個（コピープロテクトの可能性）", "\(odd) (possibly copy protection)")) }
            return img
        }
        if r.fixedStr(0, 14) == "T98FDDIMAGE.R1" {
            var img = Image(device: DataDevice(Data()), format: "NFD r1 (T98-Next)")
            img.rows.add(L("コメント", "Comment"), text(r.bytes(0x10, 0x100)))
            img.rows.add(L("中身の読み取り", "Reading the contents"), L("この形式（r1）の中身は読んでいません", "The contents of this variant (r1) are not read"))
            return img
        }
        // ---- Virtual98 hard disk
        if r.fixedStr(0, 7) == "VHD1.00" {
            let ss = Int(r.u16(0x8c)), spt = Int(r.u8(0x8e)), heads = Int(r.u8(0x8f)), cyl = Int(r.u16(0x90))
            guard geomOK(ss, spt, heads, cyl), n > 220 else { return nil }
            return Image(device: SubDevice(parent: file, base: 220, size: n - 220), format: "HDD (Virtual98)", geometry: (cyl, heads, spt, ss), hardDisk: true)
        }
        // ---- Anex86: FDI (floppy) and HDI (hard disk) share one header layout
        let hsize = Int(r.u32(8)), dsize = Int(r.u32(12)), ss = Int(r.u32(16)), spt = Int(r.u32(20)), heads = Int(r.u32(24)), cyl = Int(r.u32(28))
        if r.u32(0) == 0, hsize >= 32, hsize <= 65536, hsize % 256 == 0, dsize > 0, hsize + dsize <= n + ss, geomOK(ss, spt, heads, cyl), abs(ss * spt * heads * cyl - dsize) <= ss * spt * heads {
            let hard = dsize > 3 << 20 || ext == "hdi"
            var img = Image(device: SubDevice(parent: file, base: hsize, size: Swift.min(dsize, n - hsize)), format: hard ? "HDI (Anex86)" : "FDI (Anex86)", hardDisk: hard)
            if hard { img.geometry = (cyl, heads, spt, ss) }
            else {
                img.rows.add(L("ディスクの種類", "Media"), floppyKind(dsize, sectorSize: ss))
                img.rows.add(L("記録の形", "Geometry"), L("\(cyl) シリンダー × \(heads) 面 × \(spt) セクター、1 セクター \(ss) バイト", "\(cyl) cylinders × \(heads) sides × \(spt) sectors of \(ss) bytes"))
            }
            return img
        }
        // ---- T98 hard disk: a 256-byte header holding only the cylinder count
        if ext == "thd", n > 256 {
            let cyl = Int(r.u16(0))
            guard cyl > 0, 256 + cyl * 8 * 33 * 256 <= n + 65536 else { return nil }
            return Image(device: SubDevice(parent: file, base: 256, size: n - 256), format: "THD (T98)", geometry: (cyl, 8, 33, 256), hardDisk: true)
        }
        // ---- DIM (DIFC): a 256-byte header, then the tracks
        if n > 256 + 1024, r.fixedStr(0xab, 11) == "DIFC HEADER" {
            let kinds = [0: "2HD", 1: "2HS", 2: "2HC", 3: "2HDE", 9: "2HQ"]
            var img = Image(device: SubDevice(parent: file, base: 256, size: n - 256), format: "DIM (DIFC)")
            img.rows.add(L("ディスクの種類", "Media"), kinds[Int(r.u8(0))])
            return img
        }
        // ---- D88 / D68 / 88D: per-sector headers, so odd formats and protections survive
        if ["d88", "d68", "88d", "d77", "d98"].contains(ext) || (n > 0x2b0 && Int(r.u32(0x1c)) == n && [0x00, 0x10, 0x20, 0x30, 0x40].contains(r.u8(0x1b)) && Int(r.u32(0x20)) == 0x2b0) {
            let size = Swift.min(Int(r.u32(0x1c)), n)
            guard size > 0x2b0, [0x00, 0x10, 0x20, 0x30, 0x40].contains(r.u8(0x1b)) else { return nil }
            var out = Data()
            var tracks = 0, sectors = 0, odd = 0
            var sizes = [Int: Int]()
            for t in 0..<164 {
                var o = Int(r.u32(0x20 + t * 4))
                guard o >= 0x2a0, o + 16 <= size else { continue }
                tracks += 1
                var list = [(r: Int, data: Data)]()
                let count = Int(r.u16(o + 4))
                for _ in 0..<Swift.min(count, 64) {
                    guard o + 16 <= size else { break }
                    let len = Int(r.u16(o + 14))
                    guard o + 16 + len <= size else { break }
                    list.append((Int(r.u8(o + 2)), r.bytes(o + 16, len)))
                    sizes[len, default: 0] += 1
                    if r.u8(o + 7) != 0 || r.u8(o + 8) != 0 { odd += 1 }
                    o += 16 + len
                }
                sectors += list.count
                for s in list.sorted(by: { $0.r < $1.r }) { out.append(s.data) }
            }
            guard sectors > 0 else { return nil }
            var img = Image(device: DataDevice(out), format: "D88")
            img.name = text(r.bytes(0, 17))
            let media = [0x00: L("2D（PC-88 系など）", "2D (PC-88 family)"), 0x10: "2DD", 0x20: L("2HD（PC-98 など）", "2HD (PC-98 etc.)"), 0x30: "1D", 0x40: "1DD"][Int(r.u8(0x1b))]
            img.rows.add(L("ディスク名", "Disk name"), img.name)
            img.rows.add(L("ディスクの種類", "Media"), media)
            img.rows.add(L("書き込み禁止", "Write-protected"), r.u8(0x1a) != 0 ? L("はい", "Yes") : nil)
            img.rows.add(L("トラックとセクター", "Tracks and sectors"), L("\(tracks) トラック、\(sectors) セクター", "\(tracks) tracks, \(sectors) sectors"))
            img.rows.add(L("セクターの大きさ", "Sector sizes"), sizes.sorted { $0.value > $1.value }.map { "\($0.key) B × \($0.value)" }.joined(separator: ", "))
            if odd > 0 || sizes.count > 1 { img.rows.add(L("特殊なセクター", "Unusual sectors"), L("あり（大きさの違うセクターや、消去マーク・エラーつきが \(odd) 個。コピープロテクトの可能性）", "Yes (mixed sizes, or \(odd) with deleted marks / errors: possibly copy protection)")) }
            if size < n { img.rows.add(L("収録枚数", "Disks in this file"), L("複数（最初の 1 枚を表示）", "Several (showing the first)")) }
            return img
        }
        return nil
    }

    /// The PC-98's own partition table (second sector): 16 entries of 32 bytes, addressed by cylinder / head / sector.
    static func partitions(_ dev: BlockDevice, geometry g: (cylinders: Int, heads: Int, sectors: Int, sectorSize: Int)) -> [Partition]? {
        guard let t = dev.reader(g.sectorSize, 512, little: true) else { return nil }
        var parts = [Partition]()
        let kinds: [UInt8: String] = [0x01: "FAT12", 0x11: "FAT16", 0x21: "FAT16", 0x61: "FAT32", 0x31: "NTFS", 0x04: "PC-UX", 0x14: "BSD", 0x44: "FreeBSD (386BSD)", 0x62: "Linux", 0x63: "Linux swap", 0x05: "N88-BASIC", 0x06: "N88-BASIC(86)"]
        for i in 0..<16 {
            let e = i * 32
            let mid = t.u8(e), sid = t.u8(e + 1)
            guard mid != 0 || sid != 0 else { continue }
            func lba(_ o: Int) -> Int { ((Int(t.u16(o + 2)) * g.heads + Int(t.u8(o + 1))) * g.sectors + Int(t.u8(o))) * g.sectorSize }
            let start = lba(e + 8), end = lba(e + 12) + g.sectorSize * g.sectors * g.heads
            guard start > 0, start < dev.size, end > start else { continue }
            let name = text(t.bytes(e + 16, 16))
            guard name.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { continue }
            let state = (mid & 0x80 != 0 ? L("起動可", "bootable") : "") + (sid & 0x80 == 0 ? L(" スリープ", " inactive") : "")
            parts.append(Partition(name: name, type: (kinds[sid & 0x7f] ?? String(format: "0x%02X", sid & 0x7f)) + (state.isEmpty ? "" : L("（\(state.trimmingCharacters(in: .whitespaces))）", " (\(state.trimmingCharacters(in: .whitespaces)))")),
                                   start: start, size: Swift.min(end, dev.size) - start))
        }
        return parts.isEmpty ? nil : parts
    }
}
