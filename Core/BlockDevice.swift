import Foundation
import Compression

/// bzip2 comes from the system's libbz2 (the Compression framework has no bzip2 decoder).
@_silgen_name("BZ2_bzBuffToBuffDecompress")
private func BZ2_bzBuffToBuffDecompress(_ dest: UnsafeMutablePointer<CChar>?, _ destLen: UnsafeMutablePointer<UInt32>?, _ source: UnsafeMutablePointer<CChar>?,
                                        _ sourceLen: UInt32, _ small: Int32, _ verbosity: Int32) -> Int32

func bunzip2(_ src: Data, expected: Int) -> Data? {
    var out = Data(count: expected)
    var outLen = UInt32(expected)
    var input = src
    let rc: Int32 = out.withUnsafeMutableBytes { dst in
        input.withUnsafeMutableBytes { s in
            BZ2_bzBuffToBuffDecompress(dst.bindMemory(to: CChar.self).baseAddress, &outLen, s.bindMemory(to: CChar.self).baseAddress, UInt32(src.count), 0, 0)
        }
    }
    guard rc == 0 else { return nil }
    if Int(outLen) < expected { out.removeSubrange(Int(outLen)...) }
    return out
}

/// Random access to something disk-like: a file, a partition inside it, the expanded contents of a .dmg,
/// or a file stored inside another volume (so images nested in images can be read too).
protocol BlockDevice {
    var size: Int { get }
    func read(_ offset: Int, _ length: Int) -> Data?
}

extension BlockDevice {
    func reader(_ offset: Int, _ length: Int, little: Bool = false) -> Reader? {
        read(offset, length).map { Reader($0, little: little) }
    }
    func string(_ offset: Int, _ length: Int) -> String {
        read(offset, length).map { Reader($0).fixedStr(0, length) } ?? ""
    }
}

struct DataDevice: BlockDevice {
    let r: Reader
    init(_ data: Data) { r = Reader(data) }
    var size: Int { r.count }
    func read(_ offset: Int, _ length: Int) -> Data? { r.ok(offset, length) ? r.bytes(offset, length) : nil }
}

struct SubDevice: BlockDevice {
    let parent: BlockDevice
    let base: Int
    let size: Int
    func read(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= size else { return nil }
        return parent.read(base + offset, length)
    }
}

/// Apple disk image (.dmg, UDIF): the "koly" trailer points at a property list describing each partition
/// as a run of chunks, each stored raw, zero-filled or compressed.
final class DMGDevice: BlockDevice {
    struct Chunk { var type: UInt32; var sector: Int; var sectors: Int; var offset: Int; var length: Int }
    struct Part { var name: String; var firstSector: Int; var sectors: Int }

    let source: BlockDevice
    var chunks: [Chunk] = []
    var parts: [Part] = []
    var sectorCount = 0
    var hasLicense = false
    var checksumType: UInt32 = 0
    private var cache: [(index: Int, data: Data)] = []
    private let lock = NSLock()

    var size: Int { sectorCount * 512 }

    static func hasTrailer(_ dev: BlockDevice) -> Bool {
        dev.size > 512 && dev.string(dev.size - 512, 4) == "koly"
    }

    init?(_ dev: BlockDevice) {
        source = dev
        guard DMGDevice.hasTrailer(dev), let k = dev.reader(dev.size - 512, 512) else { return nil }
        let dataFork = Int(clamping: k.u64(24))
        let xmlOff = Int(clamping: k.u64(216)), xmlLen = Int(clamping: k.u64(224))
        checksumType = k.u32(352)
        sectorCount = Int(Swift.min(k.u64(492), 1 << 48))
        guard xmlLen > 0, xmlLen < 64 << 20, let xml = dev.read(xmlOff, xmlLen),
              let plist = (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any],
              let rf = plist["resource-fork"] as? [String: Any] else { return nil }
        hasLicense = rf["LPic"] != nil || rf["TEXT"] != nil
        for b in (rf["blkx"] as? [[String: Any]]) ?? [] {
            guard let d = b["Data"] as? Data, d.count >= 204 else { continue }
            let m = Reader(d, little: false)
            guard m.fixedStr(0, 4) == "mish" else { continue }
            let first = Int(clamping: m.u64(8)), count = Int(clamping: m.u64(16))
            let partDataOffset = Int(clamping: m.u64(24))
            parts.append(Part(name: (b["Name"] as? String) ?? (b["CFName"] as? String) ?? "", firstSector: first, sectors: count))
            let n = Int(m.u32(200))
            for i in 0..<Swift.min(n, (d.count - 204) / 40) {
                let c = 204 + i * 40
                let type = m.u32(c)
                if type == 0xffff_ffff || type == 0x7fff_fffe { continue }   // end marker, comment
                guard m.u64(c + 8) < 1 << 48, m.u64(c + 16) < 1 << 40, first < 1 << 48, m.u64(c + 24) < 1 << 50, m.u64(c + 32) < 1 << 40, partDataOffset < 1 << 50, dataFork < 1 << 50 else { continue }
                chunks.append(Chunk(type: type, sector: first + Int(clamping: m.u64(c + 8)), sectors: Int(clamping: m.u64(c + 16)),
                                    offset: dataFork + partDataOffset + Int(clamping: m.u64(c + 24)), length: Int(clamping: m.u64(c + 32))))
            }
        }
        chunks.sort { $0.sector < $1.sector }
        if sectorCount == 0 { sectorCount = chunks.last.map { $0.sector + $0.sectors } ?? 0 }
        guard !chunks.isEmpty else { return nil }
    }

    static func compressionName(_ type: UInt32) -> String? {
        switch type {
        case 0x8000_0004: return "ADC"
        case 0x8000_0005: return "zlib"
        case 0x8000_0006: return "bzip2"
        case 0x8000_0007: return "LZFSE"
        case 0x8000_0008: return "LZMA"
        default: return nil
        }
    }

    /// Compression methods used, most common first.
    var compressions: [String] {
        var counts = [String: Int]()
        for c in chunks { if let n = DMGDevice.compressionName(c.type) { counts[n, default: 0] += 1 } }
        return counts.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// True when some chunks use a method that cannot be decoded here (ADC, used by very old images).
    var hasUnreadableChunks: Bool { chunks.contains { $0.type == 0x8000_0004 } }

    private func decode(_ i: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache.first(where: { $0.index == i }) { return hit.data }
        let c = chunks[i]
        let outSize = c.sectors * 512
        guard outSize <= 256 << 20 else { return nil }
        var out: Data?
        switch c.type {
        case 0, 2: out = Data(count: outSize)
        case 1: out = source.read(c.offset, Swift.min(c.length, outSize))
        case 0x8000_0005, 0x8000_0007, 0x8000_0008:
            guard var src = source.read(c.offset, c.length) else { return nil }
            var algo = COMPRESSION_LZFSE
            if c.type == 0x8000_0005 { algo = COMPRESSION_ZLIB; src = src.dropFirst(2).withUnsafeBytes { Data($0) } }   // skip the zlib header
            if c.type == 0x8000_0008 { algo = COMPRESSION_LZMA }
            var buf = Data(count: outSize)
            let n: Int = buf.withUnsafeMutableBytes { dst in
                src.withUnsafeBytes { s in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, outSize, s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algo)
                }
            }
            if n > 0 { out = buf }
        case 0x8000_0006:
            guard let src = source.read(c.offset, c.length) else { return nil }
            out = bunzip2(src, expected: outSize)
        default: out = nil
        }
        if let out {
            cache.append((i, out))
            if cache.count > 12 { cache.removeFirst() }
        }
        return out
    }

    func read(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= size else { return nil }
        var out = Data()
        var pos = offset
        // Binary search for the chunk holding `pos`.
        var lo = 0, hi = chunks.count - 1, idx = -1
        let sector = pos / 512
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chunks[mid].sector > sector { hi = mid - 1 }
            else if chunks[mid].sector + chunks[mid].sectors <= sector { lo = mid + 1 }
            else { idx = mid; break }
        }
        while out.count < length {
            if idx < 0 || idx >= chunks.count || chunks[idx].sector * 512 > pos {
                // A hole between chunks reads as zeros.
                let next = (idx >= 0 && idx < chunks.count) ? chunks[idx].sector * 512 : size
                let n = Swift.min(length - out.count, Swift.max(next - pos, 0))
                if n == 0 { if idx < 0 { idx = lo } else { return nil }; if idx >= chunks.count { out.append(Data(count: length - out.count)); break }; continue }
                out.append(Data(count: n)); pos += n
                continue
            }
            guard let d = decode(idx) else { return nil }
            let inChunk = pos - chunks[idx].sector * 512
            let n = Swift.min(length - out.count, d.count - inChunk)
            guard n > 0 else { return nil }
            out.append(d.subdata(in: (d.startIndex + inChunk)..<(d.startIndex + inChunk + n)))
            pos += n
            idx += 1
        }
        return out
    }
}

/// Partition tables: GPT, Apple Partition Map and MBR.
struct Partition {
    var name: String
    var type: String
    var start: Int
    var size: Int
}

enum PartitionMap {
    static let gptTypes: [String: String] = [
        "48465300-0000-11AA-AA11-00306543ECAC": "Apple HFS+", "7C3457EF-0000-11AA-AA11-00306543ECAC": "Apple APFS",
        "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": "EFI System", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7": "Microsoft Basic Data",
        "E3C9E316-0B5C-4DB8-817D-F92DF00215AE": "Microsoft Reserved", "DE94BBA4-06D1-4D40-A16A-BFD50179D6AC": "Windows Recovery",
        "0FC63DAF-8483-4772-8E79-3D69D8477DE4": "Linux Filesystem", "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": "Linux Swap",
        "E6D6D379-F507-44C2-A23C-238F2A3DF928": "Linux LVM", "426F6F74-0000-11AA-AA11-00306543ECAC": "Apple Boot",
        "52414944-0000-11AA-AA11-00306543ECAC": "Apple RAID", "5265636F-7665-11AA-AA11-00306543ECAC": "Apple Recovery",
        "21686148-6449-6E6F-744E-656564454649": "BIOS Boot", "FE3A2A5D-4F32-41A7-B725-ACCC3285A309": "ChromeOS Kernel",
        "3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC": "ChromeOS Root", "516E7CB4-6ECF-11D6-8FF8-00022D09712B": "FreeBSD Disklabel",
    ]
    static let mbrTypes: [UInt8: String] = [0x01: "FAT12", 0x04: "FAT16", 0x06: "FAT16", 0x0e: "FAT16 (LBA)", 0x0b: "FAT32", 0x0c: "FAT32 (LBA)", 0x07: "NTFS / exFAT",
                                            0x82: "Linux Swap", 0x83: "Linux", 0x8e: "Linux LVM", 0xa5: "FreeBSD", 0xa8: "Apple UFS", 0xab: "Apple Boot", 0xaf: "Apple HFS+",
                                            0xef: "EFI System", 0x27: "Windows Recovery", 0x0f: "Extended", 0x05: "Extended", 0x17: "Hidden NTFS", 0xcd: "ISO hybrid"]

    static func guid(_ r: Reader, _ o: Int) -> String {
        String(format: "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X", r.le32(o), r.le16(o + 4), r.le16(o + 6),
               r.u8(o + 8), r.u8(o + 9), r.u8(o + 10), r.u8(o + 11), r.u8(o + 12), r.u8(o + 13), r.u8(o + 14), r.u8(o + 15))
    }

    static func detect(_ dev: BlockDevice) -> (scheme: String, parts: [Partition])? {
        // GPT (512- or 4096-byte sectors)
        for ss in [512, 4096] {
            guard let h = dev.reader(ss, 92, little: true), h.fixedStr(0, 8) == "EFI PART" else { continue }
            let lba = Int(clamping: h.u64(72)), n = Swift.min(Int(h.u32(80)), 256), es = Int(h.u32(84))
            guard es >= 128, es <= 4096, lba >= 0, lba < 1 << 40, let t = dev.reader(lba * ss, n * es, little: true) else { continue }
            var parts = [Partition]()
            for i in 0..<n {
                let e = i * es
                let type = guid(t, e)
                guard type != "00000000-0000-0000-0000-000000000000" else { continue }
                let first = Int(clamping: t.u64(e + 32)), last = Int(clamping: t.u64(e + 40))
                guard first < 1 << 48, last < 1 << 48, last >= first else { continue }
                var name = t.utf16(e + 56, units: 36)
                if let z = name.firstIndex(of: "\0") { name = String(name[..<z]) }
                parts.append(Partition(name: name, type: gptTypes[type] ?? type, start: first * ss, size: (last - first + 1) * ss))
            }
            if !parts.isEmpty { return ("GPT", parts) }
        }
        // Apple Partition Map (512-byte blocks, or 2048 on CD-style media)
        for bs in [512, 2048] {
            guard let first = dev.reader(bs, 512), first.fixedStr(0, 2) == "PM" else { continue }
            let count = Swift.min(Int(first.u32(4)), 64)
            var parts = [Partition]()
            for i in 0..<count {
                guard let e = dev.reader(bs * (i + 1), 512), e.fixedStr(0, 2) == "PM" else { break }
                let type = e.fixedStr(48, 32)
                if type == "Apple_partition_map" || type == "Apple_Free" || type.hasPrefix("Apple_Driver") || type == "Apple_Patches" { continue }
                parts.append(Partition(name: e.fixedStr(16, 32), type: type, start: Int(e.u32(8)) * bs, size: Int(e.u32(12)) * bs))
            }
            if !parts.isEmpty { return ("Apple Partition Map", parts) }
        }
        // MBR
        if let m = dev.reader(0, 512, little: true), m.u16(510) == 0xaa55 {
            var parts = [Partition]()
            for i in 0..<4 {
                let e = 446 + i * 16
                let type = m.u8(e + 4), start = Int(m.u32(e + 8)), count = Int(m.u32(e + 12))
                guard type != 0, type != 0xee, count > 0, start > 0, start * 512 < dev.size else { continue }
                parts.append(Partition(name: "", type: mbrTypes[type] ?? "0x" + String(type, radix: 16), start: start * 512, size: Swift.min(count * 512, dev.size - start * 512)))
            }
            if !parts.isEmpty { return ("MBR", parts) }
        }
        return nil
    }

    /// File system at the start of a volume, with its label when that is cheap to read.
    static func fileSystem(_ dev: BlockDevice) -> (name: String, label: String?)? {
        guard let b = dev.reader(0, Swift.min(4096, dev.size), little: true), b.count >= 2048 else { return nil }
        let sig = b.fixedStr(1024, 2)
        if sig == "H+" || sig == "HX" { return (sig == "HX" ? "HFSX" : "HFS+", nil) }
        if sig == "BD" { return (b.fixedStr(1024 + 0x7c, 2) == "H+" ? L("HFS+（HFS ラッパー内）", "HFS+ (in an HFS wrapper)") : "HFS", b.fixedStr(1024 + 37, Int(b.u8(1024 + 36)))) }
        if b.be16(1024) == 0xd2d7 { return ("MFS", ClassicMac.pstring(Reader(b.data, little: false), 1024 + 36, max: 27)) }
        if b.fixedStr(32, 4) == "NXSB" { return ("APFS", nil) }
        if b.fixedStr(3, 8) == "NTFS    " { return ("NTFS", nil) }
        if b.fixedStr(3, 8) == "EXFAT   " { return ("exFAT", nil) }
        if b.fixedStr(82, 5) == "FAT32" { return ("FAT32", FAT.name(b.bytes(71, 11))) }
        if b.fixedStr(54, 3) == "FAT" { return (b.fixedStr(54, 5), FAT.name(b.bytes(43, 11))) }
        if b.u16(1080) == 0xef53 { return ("ext2/3/4", b.fixedStr(1144, 16)) }
        if dev.size <= 3 << 20, let f = FAT(dev) { return ("FAT12", f.label) }   // floppy without the newer boot record
        // Boot records that do not spell out "FAT" (NEC's DOS for the PC-98, among others).
        if b.u8(0) == 0xeb || b.u8(0) == 0xe9, [256, 512, 1024, 2048].contains(Int(b.u16(11))), let f = FAT(dev) { return ("FAT\(f.bits)", f.label) }
        if b.fixedStr(0, 4) == "XFSB" { return ("XFS", b.fixedStr(108, 12)) }
        if b.fixedStr(0, 4) == "hsqs" { return ("SquashFS", nil) }
        if dev.string(32769, 5) == "CD001" { return ("ISO 9660", nil) }
        if dev.string(65600, 8) == "_BHRfS_M" { return ("Btrfs", nil) }
        return nil
    }
}
