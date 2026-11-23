import Foundation

/// Minimal ISO 9660 reader over cooked (2048-byte) images and raw CD dumps (2352-byte sectors, .bin).
struct ISO9660 {
    let r: Reader
    var sectorSize = 2048
    var dataOffset = 0          // offset of the user data inside one raw sector
    var pvd = 0
    var rootLBA = 0
    var rootSize = 0
    /// Names come from the Joliet tree (UTF-16) instead of the primary one.
    var joliet = false
    /// Volume name from the Joliet descriptor (UTF-16), when the disc has one.
    var jolietVolume = ""
    var raw: Bool { sectorSize != 2048 }

    struct Entry { var name: String; var lba: Int; var size: Int; var isDir: Bool }

    init?(_ data: Data) {
        r = Reader(data, little: true)
        // Raw CD image: every sector starts with the sync pattern 00 FF×10 00.
        if data.count >= 2352 * 17, r.be32(0) == 0x00ff_ffff, r.be32(4) == 0xffff_ffff, r.be32(8) == 0xffff_ff00 {
            sectorSize = 2352
            dataOffset = r.u8(15) == 2 ? 24 : 16
        }
        pvd = offset(16)
        guard r.ok(pvd, 2048), r.u8(pvd) == 1, r.fixedStr(pvd + 1, 5) == "CD001" else { return nil }
        rootLBA = Int(r.u32(pvd + 156 + 2))
        rootSize = Int(r.u32(pvd + 156 + 10))
        // Without Rock Ridge the primary tree only has short DOS-style names ("README~1.DIS").
        // If the disc also has a Joliet tree, use that one: it keeps the real names.
        let dot = offset(rootLBA)
        let su = dot + 34
        let hasRockRidge = r.ok(dot, 64) && Int(r.u8(dot)) >= 41 && r.u8(su) == 0x53 && r.u8(su + 1) == 0x50
        for sct in 17..<32 {
            let d = offset(sct)
            guard r.ok(d, 2048), r.fixedStr(d + 1, 5) == "CD001" else { break }
            if r.u8(d) == 255 { break }
            if r.u8(d) == 2, r.u8(d + 88) == 0x25, r.u8(d + 89) == 0x2f, [0x40, 0x43, 0x45].contains(r.u8(d + 90)) {
                var u = [UInt16]()
                for k in stride(from: 0, to: 32, by: 2) { u.append(r.be16(d + 40 + k)) }
                jolietVolume = String(decoding: u, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
                if !hasRockRidge {
                    joliet = true
                    rootLBA = Int(r.u32(d + 156 + 2))
                    rootSize = Int(r.u32(d + 156 + 10))
                }
                break
            }
        }
    }

    func offset(_ lba: Int) -> Int { lba * sectorSize + dataOffset }

    func field(_ off: Int, _ len: Int) -> String {
        r.fixedStr(pvd + off, len).trimmingCharacters(in: .whitespaces)
    }

    /// Part of a file (cooked images only need one slice; raw images are read sector by sector).
    func read(_ e: Entry, offset: Int, length: Int) -> Data? {
        guard !e.isDir, offset >= 0, offset < e.size else { return nil }
        let n = Swift.min(length, e.size - offset)
        if !raw { return r.ok(self.offset(e.lba) + offset, n) ? r.bytes(self.offset(e.lba) + offset, n) : nil }
        var out = Data()
        var pos = offset
        while out.count < n {
            let lba = e.lba + pos / 2048, inSector = pos % 2048
            let c = Swift.min(2048 - inSector, n - out.count)
            guard r.ok(self.offset(lba) + inSector, c) else { return nil }
            out.append(r.bytes(self.offset(lba) + inSector, c))
            pos += c
        }
        return out
    }

    /// File contents (limited), reading sector by sector for raw images.
    func read(_ e: Entry, max: Int = 16 << 20) -> Data? {
        guard !e.isDir, e.size <= max else { return nil }
        if !raw { return r.ok(offset(e.lba), e.size) ? r.bytes(offset(e.lba), e.size) : nil }
        var out = Data()
        var lba = e.lba
        while out.count < e.size {
            let n = Swift.min(2048, e.size - out.count)
            guard r.ok(offset(lba), n) else { return nil }
            out.append(r.bytes(offset(lba), n))
            lba += 1
        }
        return out
    }

    func list(lba: Int, size: Int, limit: Int = 60_000) -> [Entry] {
        var out = [Entry]()
        var sector = 0
        let sectors = (Swift.min(size, 16 << 20) + 2047) / 2048
        while sector < sectors, out.count < limit {
            let base = offset(lba + sector)
            var p = 0
            while p < 2048 {
                let len = Int(r.u8(base + p))
                if len < 34 { break }
                let nlen = Int(r.u8(base + p + 32))
                let flags = r.u8(base + p + 25)
                var name = r.fixedStr(base + p + 33, nlen)
                if joliet, nlen >= 2 {
                    var u = [UInt16]()
                    for k in stride(from: 0, to: nlen - 1, by: 2) { u.append(r.be16(base + p + 33 + k)) }
                    name = String(decoding: u, as: UTF16.self)
                }
                if nlen == 1, r.u8(base + p + 33) <= 1 { p += len; continue }   // "." and ".."
                if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
                if name.hasSuffix(".") { name.removeLast() }
                // Rock Ridge "NM" entries carry the real (long, mixed-case) name used by Linux discs.
                var q = base + p + 33 + nlen + (nlen % 2 == 0 ? 1 : 0)
                let end = base + p + len
                var long = ""
                while q + 4 <= end {
                    let l = Int(r.u8(q + 2))
                    if l < 4 { break }
                    if r.u8(q) == 0x4e, r.u8(q + 1) == 0x4d, l > 5 { long += Reader.decode(r.bytes(q + 5, l - 5)) }
                    q += l
                }
                if !long.isEmpty { name = long }
                out.append(Entry(name: name, lba: Int(r.u32(base + p + 2)), size: Int(r.u32(base + p + 10)), isDir: flags & 2 != 0))
                p += len
            }
            sector += 1
        }
        return out
    }

    func root() -> [Entry] { list(lba: rootLBA, size: rootSize) }

    /// "PSP_GAME/PARAM.SFO" (case-insensitive; a leading dot may have been stored as "_").
    func find(_ path: String) -> Entry? {
        var dir = root()
        let parts = path.split(separator: "/").map { $0.uppercased() }
        for (i, part) in parts.enumerated() {
            let alt = part.hasPrefix(".") ? "_" + part.dropFirst() : part
            guard let e = dir.first(where: { $0.name.uppercased() == part || $0.name.uppercased() == alt }) else { return nil }
            if i == parts.count - 1 { return e }
            guard e.isDir else { return nil }
            dir = list(lba: e.lba, size: e.size)
        }
        return nil
    }

    /// El Torito boot record in sector 17, UDF descriptors after the volume descriptors.
    var bootable: Bool { r.u8(offset(17)) == 0 && r.fixedStr(offset(17) + 7, 23) == "EL TORITO SPECIFICATION" }

    /// Platforms listed in the El Torito boot catalog ("BIOS", "UEFI").
    var bootPlatforms: [String] {
        guard bootable else { return [] }
        let cat = offset(Int(r.u32(offset(17) + 0x47)))
        guard r.ok(cat, 2048), r.u8(cat) == 1 else { return [] }
        var out = [String]()
        func add(_ id: UInt8) {
            let n = id == 0xef ? "UEFI" : id == 0 ? "BIOS" : id == 1 ? "PowerPC" : id == 2 ? "Mac" : "0x" + String(id, radix: 16)
            if !out.contains(n) { out.append(n) }
        }
        add(r.u8(cat + 1))
        var p = cat + 64
        while p + 32 <= cat + 2048 {
            let h = r.u8(p)
            if h == 0x90 || h == 0x91 { add(r.u8(p + 1)); p += 32 * (1 + Int(r.u16(p + 2))); if h == 0x91 { break } } else { break }
        }
        return out
    }
    var hasUDF: Bool {
        for s in 17..<32 where r.ok(offset(s), 8) {
            let id = r.fixedStr(offset(s) + 1, 5)
            if id == "NSR02" || id == "NSR03" { return true }
        }
        return false
    }

    /// "2026112213450000" → date string
    func date(_ off: Int) -> String? {
        let s = r.fixedStr(pvd + off, 16)
        guard s.count >= 14, let y = Int(s.prefix(4)), y > 1900 else { return nil }
        let a = Array(s)
        return "\(String(a[0..<4]))-\(String(a[4..<6]))-\(String(a[6..<8])) \(String(a[8..<10])):\(String(a[10..<12])):\(String(a[12..<14]))"
    }
}

/// PlayStation PARAM.SFO (PSP, PS3, PS Vita, PS4).
enum SFO {
    static func parse(_ d: Data) -> [String: String] {
        let r = Reader(d, little: true)
        guard d.count > 20, r.be32(0) == 0x0050_5346 else { return [:] }
        let keys = Int(r.u32(8)), vals = Int(r.u32(12)), n = Int(r.u32(16))
        var out = [String: String]()
        for i in 0..<Swift.min(n, 256) {
            let e = 20 + i * 16
            let fmt = r.u16(e + 2), len = Int(r.u32(e + 4))
            let key = r.cstr(keys + Int(r.u16(e)), max: 64)
            let v = vals + Int(r.u32(e + 12))
            out[key] = fmt == 0x0404 ? "\(r.u32(v))" : r.fixedStr(v, len)
        }
        return out
    }
}
