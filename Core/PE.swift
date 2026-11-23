import Foundation
import CryptoKit
import CoreGraphics

struct PESection { var name: String; var vsize: Int; var va: Int; var rawSize: Int; var raw: Int; var chars: UInt32 }
struct PEResource { var type: String; var typeID: Int?; var name: String; var nameID: Int?; var lang: Int; var rva: Int; var size: Int }

struct PEFile {
    let r: Reader
    var pe = 0
    var opt = 0
    var is64 = false
    var machine: UInt16 = 0
    var chars: UInt16 = 0
    var timestamp: UInt32 = 0
    var sections: [PESection] = []
    var imageBase: UInt64 = 0
    var dirs: [(rva: Int, size: Int)] = []

    static let machines: [UInt16: String] = [
        0x14c: "x86", 0x8664: "x64", 0x1c0: "ARM", 0x1c2: "ARM Thumb", 0x1c4: "ARM32 (ARMNT)",
        0xaa64: "ARM64", 0xa641: "ARM64EC", 0xa64e: "ARM64X", 0x200: "Itanium", 0xebc: "EFI Byte Code",
        0x5032: "RISC-V 32", 0x5064: "RISC-V 64", 0x6264: "LoongArch64", 0x166: "MIPS R4000",
        0x1f0: "PowerPC", 0x1a2: "SH3", 0x1a6: "SH4", 0x169: "MIPS WCE v2", 0x184: "Alpha", 0x284: "Alpha64",
    ]

    static let subsystems: [UInt16: String] = [
        0: "Unknown", 1: "Native", 2: "Windows GUI", 3: "Windows Console", 5: "OS/2 Console", 7: "POSIX Console",
        9: "Windows CE GUI", 10: "EFI Application", 11: "EFI Boot Service Driver", 12: "EFI Runtime Driver",
        13: "EFI ROM", 14: "Xbox", 16: "Windows Boot Application",
    ]

    static let resTypes: [Int: String] = [
        1: "CURSOR", 2: "BITMAP", 3: "ICON", 4: "MENU", 5: "DIALOG", 6: "STRING", 7: "FONTDIR", 8: "FONT",
        9: "ACCELERATOR", 10: "RCDATA", 11: "MESSAGETABLE", 12: "GROUP_CURSOR", 14: "GROUP_ICON",
        16: "VERSION", 17: "DLGINCLUDE", 19: "PLUGPLAY", 20: "VXD", 21: "ANICURSOR", 22: "ANIICON",
        23: "HTML", 24: "MANIFEST",
    ]

    init?(_ data: Data) {
        r = Reader(data, little: true)
        guard r.u16(0) == 0x5a4d else { return nil }
        pe = Int(r.u32(0x3c))
        guard r.ok(pe, 24), r.u32(pe) == 0x0000_4550 else { return nil }
        machine = r.u16(pe + 4)
        let nsec = Int(r.u16(pe + 6))
        timestamp = r.u32(pe + 8)
        let optSize = Int(r.u16(pe + 20))
        chars = r.u16(pe + 22)
        opt = pe + 24
        let magic = r.u16(opt)
        is64 = magic == 0x20b
        if optSize >= 96 {
            imageBase = is64 ? r.u64(opt + 24) : UInt64(r.u32(opt + 28))
            let ndirOff = opt + (is64 ? 108 : 92)
            let ndir = Swift.min(Int(r.u32(ndirOff)), 16)
            for i in 0..<ndir where ndirOff + 4 + i * 8 + 8 <= opt + optSize {
                dirs.append((Int(r.u32(ndirOff + 4 + i * 8)), Int(r.u32(ndirOff + 8 + i * 8))))
            }
        }
        let st = opt + optSize
        let strtab = Int(r.u32(pe + 12)) + Int(r.u32(pe + 16)) * 18
        for i in 0..<Swift.min(nsec, 96) {
            let o = st + i * 40
            guard r.ok(o, 40) else { break }
            var name = r.fixedStr(o, 8)
            if name.hasPrefix("/"), let n = Int(name.dropFirst()), r.u32(pe + 12) != 0 {
                let long = r.cstr(strtab + n, max: 128)
                if !long.isEmpty { name = long }
            }
            sections.append(PESection(name: name, vsize: Int(r.u32(o + 8)), va: Int(r.u32(o + 12)),
                                      rawSize: Int(r.u32(o + 16)), raw: Int(r.u32(o + 20)), chars: r.u32(o + 36)))
        }
    }

    var hasOptional: Bool { opt + 96 <= r.count && (r.u16(opt) == 0x10b || r.u16(opt) == 0x20b) }

    func dir(_ i: Int) -> (rva: Int, size: Int)? {
        guard i < dirs.count, dirs[i].rva != 0, dirs[i].size != 0 else { return nil }
        return dirs[i]
    }

    func off(_ rva: Int) -> Int? {
        for s in sections where rva >= s.va && rva < s.va + Swift.max(s.vsize, s.rawSize) {
            let d = rva - s.va
            return d < s.rawSize ? s.raw + d : nil
        }
        // Header area.
        if let first = sections.map({ $0.va }).min(), rva < first, rva < r.count { return rva }
        return nil
    }

    func str(_ rva: Int, max: Int = 512) -> String {
        guard let o = off(rva) else { return "" }
        return r.cstr(o, max: max)
    }

    // MARK: Imports / exports

    func thunks(_ rva: Int, cap: Int) -> ([String], Int) {
        guard rva != 0, var o = off(rva) else { return ([], 0) }
        var names = [String]()
        var n = 0
        let w = is64 ? 8 : 4
        while r.ok(o, w), n < 100_000 {
            let v = is64 ? r.u64(o) : UInt64(r.u32(o))
            if v == 0 { break }
            if names.count < cap {
                if v >> (is64 ? 63 : 31) != 0 {
                    names.append("#\(v & 0xffff)")
                } else if let h = off(Int(v & 0x7fff_ffff)) {
                    names.append(r.cstr(h + 2, max: 512))
                }
            }
            n += 1
            o += w
        }
        return (names, n)
    }

    func imports(cap: Int) -> [(dll: String, funcs: [String], count: Int, delay: Bool)] {
        var out = [(String, [String], Int, Bool)]()
        if let d = dir(1), var o = off(d.rva) {
            while r.ok(o, 20), out.count < 2000 {
                let ilt = Int(r.u32(o)), name = Int(r.u32(o + 12)), iat = Int(r.u32(o + 16))
                if name == 0 && iat == 0 { break }
                let t = thunks(ilt != 0 ? ilt : iat, cap: cap)
                out.append((str(name), t.0, t.1, false))
                o += 20
            }
        }
        if let d = dir(13), var o = off(d.rva) {
            while r.ok(o, 32), out.count < 2000 {
                let attrs = r.u32(o)
                var name = Int(r.u32(o + 4)), int = Int(r.u32(o + 16))
                if name == 0 { break }
                if attrs & 1 == 0 {  // old style: VAs instead of RVAs
                    name -= Int(truncatingIfNeeded: imageBase); int -= Int(truncatingIfNeeded: imageBase)
                }
                let t = thunks(int, cap: cap)
                out.append((str(name), t.0, t.1, true))
                o += 32
            }
        }
        return out
    }

    func exports(cap: Int) -> (name: String, total: Int, items: [[String]])? {
        guard let d = dir(0), let o = off(d.rva), r.ok(o, 40) else { return nil }
        let base = Int(r.u32(o + 16)), nfunc = Int(r.u32(o + 20)), nname = Int(r.u32(o + 24))
        guard let funcs = off(Int(r.u32(o + 28))) else { return (str(Int(r.u32(o + 12))), nfunc, []) }
        let names = off(Int(r.u32(o + 32))), ords = off(Int(r.u32(o + 36)))
        var named = [Int: String]()
        if let names, let ords {
            for i in 0..<Swift.min(nname, cap) {
                named[Int(r.u16(ords + i * 2))] = str(Int(r.u32(names + i * 4)))
            }
        }
        var items = [[String]]()
        for i in 0..<Swift.min(nfunc, cap) {
            let rva = Int(r.u32(funcs + i * 4))
            if rva == 0 { continue }
            let fwd = (rva >= d.rva && rva < d.rva + d.size) ? str(rva) : ""
            items.append(["\(base + i)", named[i] ?? "", fwd.isEmpty ? hex(rva, pad: 8) : "→ " + fwd])
        }
        return (str(Int(r.u32(o + 12))), nfunc, items)
    }

    // MARK: Resources

    func resources() -> [PEResource] {
        guard let d = dir(2), let root = off(d.rva) else { return [] }
        var out = [PEResource]()
        func entries(_ dirOff: Int) -> [(id: Int?, name: String, sub: Bool, target: Int)] {
            guard r.ok(dirOff, 16) else { return [] }
            let n = Int(r.u16(dirOff + 12)) + Int(r.u16(dirOff + 14))
            var a = [(Int?, String, Bool, Int)]()
            for i in 0..<Swift.min(n, 4096) {
                let e = dirOff + 16 + i * 8
                guard r.ok(e, 8) else { break }
                let nm = r.u32(e), tg = r.u32(e + 4)
                var id: Int? = Int(nm)
                var name = ""
                if nm & 0x8000_0000 != 0 {
                    let so = root + Int(nm & 0x7fff_ffff)
                    name = r.utf16(so + 2, units: Int(r.u16(so)))
                    id = nil
                }
                a.append((id, name, tg & 0x8000_0000 != 0, root + Int(tg & 0x7fff_ffff)))
            }
            return a
        }
        for t in entries(root) where t.sub {
            let tname = t.id.map { PEFile.resTypes[$0] ?? "#\($0)" } ?? t.name
            for n in entries(t.target) where n.sub {
                for l in entries(n.target) where !l.sub {
                    guard r.ok(l.target, 16), out.count < 20000 else { continue }
                    out.append(PEResource(type: tname, typeID: t.id, name: n.id.map { "#\($0)" } ?? n.name, nameID: n.id,
                                          lang: l.id ?? 0, rva: Int(r.u32(l.target)), size: Int(r.u32(l.target + 4))))
                }
            }
        }
        return out
    }

    func resData(_ res: PEResource, max: Int = 16 << 20) -> Data {
        guard let o = off(res.rva), res.size <= max else { return Data() }
        return r.bytes(o, res.size)
    }

    /// VS_VERSIONINFO → (fixed file version, product version, string table)
    func versionInfo(_ res: [PEResource]) -> (file: String?, product: String?, strings: [(String, String)], fileFlags: UInt32) {
        guard let v = res.first(where: { $0.typeID == 16 }) else { return (nil, nil, [], 0) }
        let d = Reader(resData(v), little: true)
        var strings = [(String, String)]()
        var file: String?, product: String?
        var fileFlags: UInt32 = 0

        func align(_ x: Int) -> Int { (x + 3) & ~3 }
        func node(_ o: Int, depth: Int) {
            guard d.ok(o, 6), depth < 5 else { return }
            let len = Int(d.u16(o)), vlen = Int(d.u16(o + 2)), type = d.u16(o + 4)
            guard len >= 6, d.ok(o, len) else { return }
            var k = o + 6
            var units = 0
            while d.ok(k + units * 2, 2), d.u16(k + units * 2) != 0, units < 256 { units += 1 }
            let key = d.utf16(k, units: units)
            k = align(k + units * 2 + 2)
            let end = o + len
            if key == "VS_VERSION_INFO", vlen >= 52, d.u32(k) == 0xfeef_04bd {
                func v4(_ ms: UInt32, _ ls: UInt32) -> String { "\(ms >> 16).\(ms & 0xffff).\(ls >> 16).\(ls & 0xffff)" }
                file = v4(d.u32(k + 8), d.u32(k + 12))
                product = v4(d.u32(k + 16), d.u32(k + 20))
                fileFlags = d.u32(k + 28) & d.u32(k + 24)
            }
            var c: Int
            switch depth {
            case 0: c = align(k + vlen)
            case 1:
                guard key == "StringFileInfo" else { return }  // skip VarFileInfo
                c = k
            case 2: c = k
            default:  // String
                let avail = Swift.max(0, (end - k) / 2)
                var s = d.utf16(k, units: Swift.min(vlen, avail))
                if let z = s.firstIndex(of: "\0") { s = String(s[..<z]) }
                strings.append((key, s.trimmingCharacters(in: .whitespacesAndNewlines)))
                return
            }
            _ = type
            var guardN = 0
            while c + 6 <= end, guardN < 512 {
                let cl = Int(d.u16(c))
                if cl < 6 { break }
                node(c, depth: depth + 1)
                c = align(c + cl)
                guardN += 1
            }
        }
        node(0, depth: 0)
        return (file, product, strings, fileFlags)
    }

    /// The application icon: the first icon group, largest image, wrapped as a one-entry .ico.
    func iconData(_ res: [PEResource]) -> Data? {
        guard let g = res.first(where: { $0.typeID == 14 }) else { return nil }
        let d = Reader(resData(g, max: 1 << 16), little: true)
        let n = Int(d.u16(4))
        var best: (score: Int, entry: Int)?
        for i in 0..<Swift.min(n, 64) {
            let e = 6 + i * 14
            guard d.ok(e, 14) else { break }
            let w = d.u8(e) == 0 ? 256 : Int(d.u8(e))
            let score = w * 100 + Int(d.u16(e + 6))
            if best == nil || score > best!.score { best = (score, e) }
        }
        guard let b = best else { return nil }
        let id = Int(d.u16(b.entry + 12))
        guard let ic = res.first(where: { $0.typeID == 3 && $0.nameID == id }) else { return nil }
        let img = resData(ic)
        guard !img.isEmpty else { return nil }
        if img.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return img }
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(d.bytes(b.entry, 8))
        withUnsafeBytes(of: UInt32(img.count).littleEndian) { ico.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(22).littleEndian) { ico.append(contentsOf: $0) }
        ico.append(img)
        return ico
    }

    // MARK: Authenticode

    struct Authenticode {
        var cms: CMSInfo?
        var digestName = ""
        var digestMatches: Bool?
        var count = 0
    }

    func authenticode(verifyHash: Bool) -> Authenticode? {
        guard dirs.count > 4, dirs[4].rva != 0, dirs[4].size > 8 else { return nil }
        let o = dirs[4].rva  // file offset, not an RVA
        let len = Int(r.u32(o))
        guard len > 8, r.ok(o, len), r.u16(o + 6) == 2 else { return Authenticode() }
        let blob = r.bytes(o + 8, len - 8)
        var a = Authenticode()
        a.count = 1
        a.cms = decodeCMS(blob, evaluateTrust: true)
        if let digest = PEFile.spcDigest(blob) {
            a.digestName = [20: "SHA-1", 32: "SHA-256", 48: "SHA-384", 64: "SHA-512"][digest.count] ?? "?"
            if verifyHash { a.digestMatches = authenticodeHash(digest.count, certStart: o, certSize: dirs[4].size) == digest }
        }
        return a
    }

    /// Digest inside SpcIndirectDataContent (OID 1.3.6.1.4.1.311.2.1.4).
    static func spcDigest(_ p7: Data) -> Data? {
        let oid = Data([0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04])
        guard let at = p7.range(of: oid) else { return nil }
        let b = [UInt8](p7)
        var i = at.upperBound - p7.startIndex
        func tlv(_ i: Int) -> (tag: UInt8, start: Int, len: Int)? {
            guard i + 2 <= b.count else { return nil }
            var len = Int(b[i + 1]), s = i + 2
            if len & 0x80 != 0 {
                let n = len & 0x7f
                guard n > 0, n <= 4, s + n <= b.count else { return nil }
                len = 0
                for k in 0..<n { len = len << 8 | Int(b[s + k]) }
                s += n
            }
            guard s + len <= b.count else { return nil }
            return (b[i], s, len)
        }
        guard let ctx = tlv(i), ctx.tag == 0xa0, let seq = tlv(ctx.start), seq.tag == 0x30,
              let attr = tlv(seq.start), let di = tlv(attr.start + attr.len), di.tag == 0x30,
              let alg = tlv(di.start), let oct = tlv(alg.start + alg.len), oct.tag == 0x04 else { return nil }
        i = oct.start
        return Data(b[i..<(i + oct.len)])
    }

    func authenticodeHash(_ n: Int, certStart: Int, certSize: Int) -> Data? {
        let checksum = opt + 64
        let secDir = opt + (is64 ? 112 : 96) + 4 * 8
        let end = certStart
        guard checksum < secDir, secDir + 8 <= end, end <= r.count else { return nil }
        let ranges = [(0, checksum), (checksum + 4, secDir), (secDir + 8, end), (certStart + certSize, r.count)]
        func run<H: HashFunction>(_ h: inout H) -> Data {
            for (a, b) in ranges where b > a {
                var p = a
                while p < b {
                    let c = Swift.min(4 << 20, b - p)
                    h.update(data: r.bytes(p, c))
                    p += c
                }
            }
            return Data(h.finalize())
        }
        switch n {
        case 20: var h = Insecure.SHA1(); return run(&h)
        case 32: var h = SHA256(); return run(&h)
        case 48: var h = SHA384(); return run(&h)
        case 64: var h = SHA512(); return run(&h)
        default: return nil
        }
    }
}

enum PE {
    static func isMZ(_ r: Reader) -> Bool { r.le16(0) == 0x5a4d }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report {
        var rep = reportPE(url: url, data: data, opts: opts)
        // EFI programs that are Linux kernels (other CPUs, compressed wrappers, unified kernel images).
        if rep.kind == .pe, !opts.light, let f = PEFile(data), f.hasOptional, (10...12).contains(Int(f.r.u16(f.opt + 68))) {
            Kernels.augmentEFI(&rep, data: data, url: url, sections: f.sections)
        }
        return rep
    }

    static func reportPE(url: URL, data: Data, opts: AnalyzeOptions) -> Report {
        // A Linux kernel with the EFI stub also starts like a Windows program: tell it apart first.
        if Kernels.isLinuxBoot(Reader(data, little: true)) { return Kernels.linux(url: url, data: data) }
        var rep = Report(kind: .pe, path: url.path, title: url.lastPathComponent)
        guard let f = PEFile(data) else { return legacy(rep, data) }
        let r = f.r
        let opt = f.opt
        let isDLL = f.chars & 0x2000 != 0
        let subsystem = f.hasOptional ? r.u16(opt + 68) : 0
        let dllChars = f.hasOptional ? r.u16(opt + 70) : 0
        let res = f.resources()
        let ver = f.versionInfo(res)
        let vs = Dictionary(ver.strings, uniquingKeysWith: { a, _ in a })

        // ARM64EC / ARM64X via the load config's CHPE metadata pointer.
        var machine = PEFile.machines[f.machine] ?? "machine \(hex(f.machine))"
        if f.is64, let lc = f.dir(10), let lo = f.off(lc.rva), Int(r.u32(lo)) >= 0xd0, r.u64(lo + 0xc8) != 0 {
            if f.machine == 0x8664 { machine = "ARM64EC" }
            if f.machine == 0xaa64 { machine = "ARM64X (ARM64 + ARM64EC)" }
        }

        // .NET
        var dotnet: String?
        var dotnetFlags: UInt32 = 0
        if let clr = f.dir(14), let co = f.off(clr.rva) {
            dotnetFlags = r.u32(co + 16)
            dotnet = ".NET"
            if let mo = f.off(Int(r.u32(co + 8))), r.u32(mo) == 0x424a_5342 {
                dotnet = ".NET (CLR " + r.fixedStr(mo + 16, Swift.min(Int(r.u32(mo + 12)), 64)) + ")"
            }
        }

        let ext = url.pathExtension.lowercased()
        var kind: String
        switch subsystem {
        case 1: kind = ext == "sys" ? L("Windows ドライバー", "Windows driver") : L("Windows ネイティブ実行ファイル", "Windows native image")
        case 10, 11, 12, 13: kind = PEFile.subsystems[subsystem]!
        case 16: kind = "Windows Boot Application"
        default:
            if isDLL { kind = L("Windows ライブラリ (DLL)", "Windows library (DLL)") }
            else if subsystem == 3 { kind = L("Windows コンソールアプリ", "Windows console app") }
            else if subsystem == 9 { kind = L("Windows CE アプリ", "Windows CE app") }
            else { kind = L("Windows アプリ", "Windows app") }
        }
        if !f.hasOptional { kind = L("COFF イメージ", "COFF image") }
        rep.subtitle = [kind, machine, f.is64 ? "PE32+" : "PE32"].joined(separator: " · ")
        if let d = vs["FileDescription"], !d.isEmpty { rep.title = d }

        if let ico = f.iconData(res) { rep.icon = MSI.image(ico) }

        // Signature
        let big = data.count > (opts.deep ? 4 << 30 : 600 << 20)
        let auth = f.authenticode(verifyHash: !big)
        var sigText = L("なし", "None")
        if let a = auth {
            let who = a.cms?.names.first ?? L("（署名者を読めません）", "(unreadable signer)")
            sigText = who
            if a.digestMatches == false {
                rep.badges.append(Badge(text: L("署名が一致しません", "Signature mismatch"), tone: .bad))
            } else if a.cms?.trusted == true {
                rep.badges.append(Badge(text: L("署名済み", "Signed"), tone: .good))
            } else {
                rep.badges.append(Badge(text: L("署名あり（信頼は未確認）", "Signed (trust unverified)"), tone: .neutral))
            }
        } else {
            rep.badges.append(Badge(text: L("署名なし", "Unsigned"), tone: .neutral))
        }
        if let dotnet { rep.badges.append(Badge(text: dotnet, tone: .info)) }

        let secNames = Set(f.sections.map { $0.name })
        var packer: String?
        if secNames.contains("UPX0") || secNames.contains("UPX1") { packer = "UPX" }
        else if secNames.contains(".ndata") { packer = L("NSIS インストーラー", "NSIS installer") }
        else if secNames.contains(".themida") { packer = "Themida" }
        else if secNames.contains(".vmp0") { packer = "VMProtect" }
        else if secNames.contains(".aspack") { packer = "ASPack" }
        if let packer { rep.badges.append(Badge(text: packer, tone: .warn)) }

        // Timestamp
        var debugRows = [Row]()
        var repro = false
        var pdb: String?
        var cet = false
        if let dd = f.dir(6), let dof = f.off(dd.rva) {
            for i in 0..<Swift.min(dd.size / 28, 32) {
                let e = dof + i * 28
                let type = r.u32(e + 12), raw = Int(r.u32(e + 24)), size = Int(r.u32(e + 16))
                if type == 16 { repro = true }
                if type == 2, r.u32(raw) == 0x5344_5352 {
                    pdb = r.cstr(raw + 24, max: 1024)
                    let g = r.bytes(raw + 4, 16)
                    if g.count == 16 {
                        let b = [UInt8](g)
                        let guid = String(format: "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                                          b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
                        debugRows.add("PDB GUID / Age", "\(guid) / \(r.u32(raw + 20))", mono: true)
                    }
                }
                if type == 20, size >= 4, r.u32(raw) & 1 != 0 { cet = true }
            }
        }
        let stamp: String = repro
            ? hex(f.timestamp, pad: 8) + L("（再現可能ビルドのハッシュ値）", " (reproducible-build hash)")
            : (f.timestamp == 0 ? "0" : dateString(Date(timeIntervalSince1970: TimeInterval(f.timestamp))) + " UTC" )

        // Summary
        var sum = [Row]()
        sum.add(L("種類", "Kind"), kind)
        sum.add(L("アーキテクチャ", "Architecture"), machine + (f.is64 ? L("（64 ビット）", " (64-bit)") : L("（32 ビット）", " (32-bit)")))
        sum.add(L("製品名", "Product"), vs["ProductName"])
        sum.add(L("バージョン", "Version"), vs["FileVersion"] ?? ver.file)
        sum.add(L("会社名", "Company"), vs["CompanyName"])
        sum.add(L("著作権", "Copyright"), vs["LegalCopyright"])
        sum.add(L("署名", "Signature"), sigText)
        if f.hasOptional {
            sum.add(L("必要な Windows", "Requires Windows"), osName(r.u16(opt + 48), r.u16(opt + 50)))
        }
        sum.add(L("ビルド日時", "Built"), stamp)
        sum.add(L("ランタイム", "Runtime"), dotnet)
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum

        // Header section
        var hdr = [Row]()
        hdr.add(L("マシン", "Machine"), "\(machine) (\(hex(f.machine, pad: 4)))")
        if f.hasOptional {
            hdr.add(L("サブシステム", "Subsystem"), (PEFile.subsystems[subsystem] ?? "\(subsystem)") + " \(r.u16(opt + 48)).\(r.u16(opt + 50))")
            hdr.add(L("OS バージョン", "OS version"), "\(r.u16(opt + 40)).\(r.u16(opt + 42))")
            hdr.add(L("イメージバージョン", "Image version"), "\(r.u16(opt + 44)).\(r.u16(opt + 46))")
            hdr.add(L("リンカー", "Linker"), linkerName(r.u8(opt + 2), r.u8(opt + 3)))
            hdr.add(L("エントリーポイント", "Entry point"), hex(r.u32(opt + 16), pad: 8), mono: true)
            hdr.add(L("イメージベース", "Image base"), hex(f.imageBase, pad: f.is64 ? 16 : 8), mono: true)
            hdr.add(L("イメージサイズ", "Image size"), byteSize(Int(r.u32(opt + 56))))
            hdr.add(L("アラインメント", "Alignment"), L("セクション ", "section ") + hex(r.u32(opt + 32)) + L("、ファイル ", ", file ") + hex(r.u32(opt + 36)))
            let stackRes = f.is64 ? r.u64(opt + 72) : UInt64(r.u32(opt + 72))
            hdr.add(L("スタック予約", "Stack reserve"), byteSize(Int(clamping: stackRes)))
            hdr.add(L("チェックサム", "Checksum"), hex(r.u32(opt + 64), pad: 8), mono: true)
        }
        hdr.add(L("タイムスタンプ", "Timestamp"), stamp)
        let cnames: [(UInt16, String)] = [(0x1, "RELOCS_STRIPPED"), (0x2, "EXECUTABLE_IMAGE"), (0x20, "LARGE_ADDRESS_AWARE"),
                                          (0x100, "32BIT_MACHINE"), (0x200, "DEBUG_STRIPPED"), (0x1000, "SYSTEM"), (0x2000, "DLL")]
        hdr.add(L("特性", "Characteristics"), cnames.filter { f.chars & $0.0 != 0 }.map { $0.1 }.joined(separator: ", "), mono: true)
        var hblocks: [Block] = [.rows(hdr)]

        if f.hasOptional {
            func yn(_ on: Bool, good: Bool = true) -> (String, Tone) {
                (on ? L("有効", "Enabled") : L("無効", "Disabled"), on == good ? .good : .warn)
            }
            var sec = [Row]()
            let aslr = yn(dllChars & 0x40 != 0); sec.add("ASLR (DYNAMIC_BASE)", aslr.0, tone: aslr.1)
            if f.is64 { let he = yn(dllChars & 0x20 != 0); sec.add(L("高エントロピー ASLR", "High-entropy ASLR"), he.0, tone: he.1) }
            let nx = yn(dllChars & 0x100 != 0); sec.add("DEP (NX_COMPAT)", nx.0, tone: nx.1)
            let cfg = dllChars & 0x4000 != 0
            sec.add("Control Flow Guard", cfg ? L("有効", "Enabled") : L("無効", "Disabled"), tone: cfg ? .good : .neutral)
            sec.add("CET Shadow Stack", cet ? L("対応", "Compatible") : L("非対応", "Not marked"), tone: cet ? .good : .neutral)
            if dllChars & 0x80 != 0 { sec.add(L("整合性の強制", "Force integrity"), L("有効", "Enabled")) }
            if dllChars & 0x1000 != 0 { sec.add("AppContainer", L("必須", "Required")) }
            if dllChars & 0x400 != 0 { sec.add("SEH", L("不使用 (NO_SEH)", "Not used (NO_SEH)")) }
            if !f.is64, let lc = f.dir(10), let lo = f.off(lc.rva), r.u32(lo) >= 0x48 {
                sec.add("SafeSEH", r.u32(lo + 0x40) != 0 ? L("有効", "Enabled") : L("無効", "Disabled"))
            }
            hblocks.append(.heading(L("保護機能", "Mitigations")))
            hblocks.append(.rows(sec))
        }
        rep.sections.append(ReportSection(id: "header", title: L("ヘッダー", "Header"), symbol: "doc.badge.gearshape", blocks: hblocks))

        // Version info
        if !ver.strings.isEmpty || ver.file != nil {
            var vrows = [Row]()
            vrows.add(L("ファイルバージョン（数値）", "File version (binary)"), ver.file)
            vrows.add(L("製品バージョン（数値）", "Product version (binary)"), ver.product)
            if ver.fileFlags & 1 != 0 { vrows.add(L("ビルド種別", "Build"), L("デバッグビルド", "Debug build"), tone: .warn) }
            if ver.fileFlags & 2 != 0 { vrows.add(L("ビルド種別", "Build"), L("プレリリース", "Prerelease")) }
            for (k, v) in ver.strings where !v.isEmpty { vrows.add(k, v) }
            rep.sections.append(ReportSection(id: "version", title: L("バージョン情報", "Version Info"), symbol: "info.circle", blocks: [.rows(vrows)]))
        }

        // Signature section
        if let a = auth {
            var rows = [Row]()
            rows.add(L("署名者", "Signed by"), a.cms?.names.first)
            if let names = a.cms?.names, names.count > 1 { rows.add(L("証明書チェーン", "Certificate chain"), names.joined(separator: "\n← ")) }
            if let t = a.cms?.timestamp ?? a.cms?.signingTime { rows.add(L("署名日時", "Signed"), dateString(t)) }
            rows.add(L("ダイジェスト", "Digest"), a.digestName)
            switch a.digestMatches {
            case true?: rows.add(L("ファイルのハッシュ", "File hash"), L("署名と一致（改変なし）", "Matches the signature (unmodified)"), tone: .good)
            case false?: rows.add(L("ファイルのハッシュ", "File hash"), L("署名と一致しません（署名後に改変）", "Does NOT match (modified after signing)"), tone: .bad)
            default: rows.add(L("ファイルのハッシュ", "File hash"), L("未確認", "Not checked"))
            }
            switch a.cms?.trusted {
            case true?: rows.add(L("証明書の信頼", "Certificate trust"), L("この Mac の信頼済みルートまで検証できました", "Chains to a root trusted by this Mac"), tone: .good)
            case false?: rows.add(L("証明書の信頼", "Certificate trust"), L("この Mac では検証できません", "Could not be verified on this Mac") + (a.cms?.trustError.map { "\n\($0)" } ?? ""))
            default: break
            }
            rep.sections.append(ReportSection(id: "signature", title: L("デジタル署名 (Authenticode)", "Digital Signature (Authenticode)"), symbol: "checkmark.seal",
                blocks: [.rows(rows), .note(L("証明書の失効確認と、署名の暗号学的な検証は行っていません。", "Revocation and the cryptographic signature itself are not checked."))]))
        }

        // Sections
        let fileEnd = f.sections.map { $0.raw + $0.rawSize }.max() ?? 0
        let srows: [[String]] = f.sections.map { s in
            var p = ""
            p += s.chars & 0x4000_0000 != 0 ? "r" : "-"
            p += s.chars & 0x8000_0000 != 0 ? "w" : "-"
            p += s.chars & 0x2000_0000 != 0 ? "x" : "-"
            var kind = [String]()
            if s.chars & 0x20 != 0 { kind.append("code") }
            if s.chars & 0x40 != 0 { kind.append("data") }
            if s.chars & 0x80 != 0 { kind.append("bss") }
            if s.chars & 0x0200_0000 != 0 { kind.append("discardable") }
            let e = entropy(r, s.raw, s.rawSize).map { String(format: "%.2f", $0) } ?? ""
            return [s.name, hex(s.va, pad: 8), byteSize(s.vsize), byteSize(s.rawSize), p, e, kind.joined(separator: ", ")]
        }
        var sblocks: [Block] = [.table(TableData(columns: [L("名前", "Name"), "RVA", L("メモリ上", "Virtual"), L("ファイル上", "Raw"), L("保護", "Prot"), L("エントロピー", "Entropy"), L("内容", "Contents")], rows: srows))]
        let certSize = auth != nil ? f.dirs[4].size : 0
        let overlay = data.count - fileEnd - certSize
        if fileEnd > 0, overlay > 0 {
            sblocks.append(.note(L("末尾にセクション外のデータ（オーバーレイ）が \(byteSize(overlay)) あります。インストーラーや自己展開書庫でよく見られます。", "\(byteSize(overlay)) of overlay data follows the last section (common in installers and self-extractors).", "最後一個區段之後有 \(byteSize(overlay)) 的區段外資料（覆蓋層）。常見於安裝程式與自我解壓縮檔。")))
        }
        if f.sections.contains(where: { $0.chars & 0xa000_0000 == 0xa000_0000 }) {
            sblocks.append(.note(L("書き込みと実行の両方が可能なセクションがあります。", "A section is both writable and executable.")))
        }
        rep.sections.append(ReportSection(id: "sections", title: L("セクション", "Sections"), symbol: "square.stack.3d.up", blocks: sblocks, count: f.sections.count))

        // Imports
        let imps = f.imports(cap: opts.deep ? 5000 : 400)
        if !imps.isEmpty {
            var blocks: [Block] = [.table(TableData(
                columns: ["DLL", L("関数の数", "Functions"), L("種別", "Kind")],
                rows: imps.map { [$0.dll, "\($0.count)", $0.delay ? L("遅延読み込み", "delay-load") : ""] }))]
            var frows = [[String]]()
            let total = imps.reduce(0) { $0 + $1.count }
            for i in imps { for fn in i.funcs { frows.append([i.dll, fn]) } }
            blocks.append(.heading(L("関数", "Functions")))
            blocks.append(.table(TableData(columns: ["DLL", L("関数", "Function")], rows: frows, total: total)))
            rep.sections.append(ReportSection(id: "imports", title: L("インポート", "Imports"), symbol: "arrow.down.to.line", blocks: blocks, count: imps.count))
        }

        // The kernel itself (and the HAL) rather than a driver.
        var isKernel = false
        if subsystem == 1, let ex = f.exports(cap: 20_000), ex.total > 20,
           let k = Kernels.ntKernel(exports: ex.items.map { $0[1] }.filter { !$0.isEmpty }, total: ex.total, strings: vs, imports: imps.map { $0.dll }, isDLL: isDLL) {
            isKernel = true
            rep.subtitle = [k.kind, machine, f.is64 ? "PE32+" : "PE32"].joined(separator: " · ")
            if let i = rep.summary.firstIndex(where: { $0.key == L("種類", "Kind") }) { rep.summary[i] = Row(L("種類", "Kind"), k.kind) }
            rep.sections.insert(k.section, at: 0)
            rep.badges.insert(Badge(text: L("カーネル", "Kernel"), tone: .info), at: 0)
        }
        // Kernel drivers: what kind of driver, from what it links against.
        if subsystem == 1, !isKernel, let drv = Drivers.windowsSection(
            name: vs["OriginalFilename"].flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent, imports: imps.map { $0.dll },
            functions: Set(f.imports(cap: 20_000).flatMap { $0.funcs }), exported: f.exports(cap: 1)?.total ?? 0,
            microsoft: (vs["CompanyName"] ?? "").contains("Microsoft"), is64: f.is64 || f.machine == 0xaa64,
            signer: auth?.cms?.names.first, sections: f.sections.map { $0.name }) {
            rep.sections.insert(drv.section, at: Swift.min(1, rep.sections.count))
            if !drv.model.isEmpty { rep.summary.insert(Row(L("ドライバーの種類", "Driver model"), drv.model), at: Swift.min(1, rep.summary.count)) }
        }

        // Exports
        if let ex = f.exports(cap: opts.deep ? 20000 : 1500), ex.total > 0 {
            var rows = [Row]()
            rows.add(L("内部名", "Internal name"), ex.name, mono: true)
            rep.sections.append(ReportSection(id: "exports", title: L("エクスポート", "Exports"), symbol: "arrow.up.to.line",
                blocks: [.rows(rows), .table(TableData(columns: [L("序数", "Ordinal"), L("名前", "Name"), L("アドレス / 転送先", "Address / Forwarder")], rows: ex.items, total: ex.total))],
                count: ex.total))
        }

        // Resources
        if !res.isEmpty {
            var byType = [(String, Int, Int)]()
            for x in res {
                if let i = byType.firstIndex(where: { $0.0 == x.type }) { byType[i].1 += 1; byType[i].2 += x.size }
                else { byType.append((x.type, 1, x.size)) }
            }
            var blocks: [Block] = [.table(TableData(columns: [L("種類", "Type"), L("個数", "Count"), L("合計サイズ", "Total size")],
                                                    rows: byType.map { [$0.0, "\($0.1)", byteSize($0.2)] }))]
            let langs = Set(res.map { $0.lang }).filter { $0 != 0 }.sorted()
            if !langs.isEmpty {
                blocks.append(.rows([Row(L("言語", "Languages"), langs.map { langName($0) }.joined(separator: ", "))]))
            }
            if opts.deep {
                blocks.append(.heading(L("すべてのリソース", "All resources")))
                blocks.append(.table(TableData(columns: [L("種類", "Type"), L("名前", "Name"), L("言語", "Language"), L("サイズ", "Size")],
                                               rows: res.prefix(5000).map { [$0.type, $0.name, langName($0.lang), byteSize($0.size)] }, total: res.count)))
            }
            rep.sections.append(ReportSection(id: "resources", title: L("リソース", "Resources"), symbol: "photo.on.rectangle", blocks: blocks, count: res.count))
        }

        // Manifest
        if let m = res.first(where: { $0.typeID == 24 }) {
            let xml = Reader.decode(f.resData(m, max: 1 << 20)).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}").union(.whitespacesAndNewlines))
            var rows = [Row]()
            if let lv = firstMatch(xml, #"requestedExecutionLevel[^>]*level\s*=\s*["']([^"']+)"#) {
                let t = ["asInvoker": L("通常の権限 (asInvoker)", "Normal (asInvoker)"),
                         "requireAdministrator": L("管理者権限が必要 (requireAdministrator)", "Requires administrator"),
                         "highestAvailable": L("使える最高の権限 (highestAvailable)", "Highest available")][lv] ?? lv
                rows.add(L("実行権限", "Execution level"), t, tone: lv == "requireAdministrator" ? .warn : .neutral)
            }
            rows.add(L("高 DPI 対応", "DPI awareness"), firstMatch(xml, #"<(?:\w+:)?dpiAwareness[^>]*>([^<]+)<"#) ?? firstMatch(xml, #"<(?:\w+:)?dpiAware[^>]*>([^<]+)<"#))
            if xml.contains("Microsoft.Windows.Common-Controls") { rows.add(L("ビジュアルスタイル", "Visual styles"), "Common Controls v6") }
            rows.add(L("長いパス", "Long paths"), firstMatch(xml, #"<(?:\w+:)?longPathAware[^>]*>([^<]+)<"#))
            var blocks = [Block]()
            if !rows.isEmpty { blocks.append(.rows(rows)) }
            blocks.append(.text(xml))
            rep.sections.append(ReportSection(id: "manifest", title: L("マニフェスト", "Manifest"), symbol: "doc.text", blocks: blocks))
        }

        // Debug
        if pdb != nil || !debugRows.isEmpty {
            var rows = [Row]()
            rows.add(L("PDB パス", "PDB path"), pdb, mono: true)
            rows.append(contentsOf: debugRows)
            rep.sections.append(ReportSection(id: "debug", title: L("デバッグ情報", "Debug Info"), symbol: "ladybug", blocks: [.rows(rows)]))
        }

        if dotnet != nil {
            var rows = [Row]()
            rows.add(L("ランタイム", "Runtime"), dotnet)
            rows.add(L("内容", "Contents"), dotnetFlags & 1 != 0 ? L("IL のみ", "IL only") : L("ネイティブコード混在", "Mixed native code"))
            if dotnetFlags & 2 != 0 { rows.add(L("32 ビット", "32-bit"), dotnetFlags & 0x20000 != 0 ? L("32 ビット優先", "32-bit preferred") : L("32 ビット必須", "32-bit required")) }
            if dotnetFlags & 8 != 0 { rows.add(L("厳密名署名", "Strong name"), L("あり", "Signed")) }
            rep.sections.append(ReportSection(id: "dotnet", title: ".NET", symbol: "shippingbox", blocks: [.rows(rows)]))
        }

        if opts.deep, let s = f.sections.first(where: { $0.name == ".rdata" }) ?? f.sections.first(where: { $0.name == ".data" }) {
            let strs = asciiStrings(r, s.raw, s.rawSize)
            if !strs.isEmpty {
                rep.sections.append(ReportSection(id: "strings", title: L("文字列", "Strings"), symbol: "text.quote",
                    blocks: [.table(TableData(columns: [L("文字列 (\(s.name))", "String (\(s.name))", "字串 (\(s.name))")], rows: strs.map { [$0] }))], count: strs.count))
            }
        }
        return rep
    }

    /// MZ files without a PE header: DOS, NE (16-bit Windows), LE/LX.
    static func legacy(_ rep0: Report, _ data: Data) -> Report {
        var rep = rep0
        let r = Reader(data, little: true)
        let lfanew = Int(r.u32(0x3c))
        let sig = r.ok(lfanew, 2) && lfanew >= 0x40 ? r.fixedStr(lfanew, 2) : ""
        var sum = [Row]()
        switch sig {
        case "NE":
            let target = r.u8(lfanew + 0x36)
            let os = [1: "OS/2", 2: "Windows", 3: "European MS-DOS 4.x", 4: "Windows 386", 5: "Borland Operating System Services"][Int(target)] ?? "?"
            let isDLL = r.u16(lfanew + 0x0c) & 0x8000 != 0
            rep.subtitle = L("16 ビット \(os) ", "16-bit \(os) ", "16 位元 \(os)  ") + (isDLL ? L("ライブラリ", "library") : L("アプリ", "app")) + " · NE"
            sum.add(L("種類", "Kind"), L("16 ビット実行ファイル (New Executable)", "16-bit New Executable"))
            sum.add(L("対象 OS", "Target OS"), os)
            sum.add(L("想定 Windows", "Expected Windows"), "\(r.u8(lfanew + 0x3f)).\(r.u8(lfanew + 0x3e))")
            sum.add(L("リンカー", "Linker"), "\(r.u8(lfanew + 2)).\(r.u8(lfanew + 3))")
            // Module name = first entry of the resident-name table.
            let rn = lfanew + Int(r.u16(lfanew + 0x26))
            let n = Int(r.u8(rn))
            if n > 0 { sum.add(L("モジュール名", "Module name"), r.fixedStr(rn + 1, n), mono: true) }
            let nr = Int(r.u32(lfanew + 0x2c))
            let dn = Int(r.u8(nr))
            if nr > 0, dn > 0 { sum.add(L("説明", "Description"), r.fixedStr(nr + 1, dn)) }
        case "LE", "LX":
            rep.subtitle = L("リニア実行ファイル (\(sig))", "Linear Executable (\(sig))", "線性可執行檔 (\(sig))")
            sum.add(L("種類", "Kind"), sig == "LE" ? L("Windows VxD / DOS エクステンダー (LE)", "Windows VxD / DOS extender (LE)") : L("OS/2 実行ファイル (LX)", "OS/2 executable (LX)"))
        default:
            rep.subtitle = L("MS-DOS 実行ファイル", "MS-DOS executable")
            sum.add(L("種類", "Kind"), L("MS-DOS 実行ファイル (MZ)", "MS-DOS executable (MZ)"))
            let pages = Int(r.u16(4)), last = Int(r.u16(2))
            sum.add(L("プログラムサイズ", "Program size"), byteSize(Swift.max(0, pages * 512 - (last == 0 ? 0 : 512 - last))))
            sum.add(L("再配置", "Relocations"), "\(r.u16(6))")
            sum.add(L("開始位置 (CS:IP)", "Entry (CS:IP)"), String(format: "%04X:%04X", r.u16(0x16), r.u16(0x14)), mono: true)
        }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        return rep
    }

    static func osName(_ major: UInt16, _ minor: UInt16) -> String {
        let names: [String: String] = ["4.0": "95 / NT 4.0", "5.0": "2000", "5.1": "XP", "5.2": "XP x64 / Server 2003", "6.0": "Vista",
                                       "6.1": "7", "6.2": "8", "6.3": "8.1", "10.0": "10"]
        let k = "\(major).\(minor)"
        return (names[k].map { "Windows \($0) " + L("以降", "or later") + " (\(k))" }) ?? k
    }

    static func linkerName(_ major: UInt8, _ minor: UInt8) -> String {
        var s = "\(major).\(minor)"
        if major == 14 {
            let vs = minor >= 50 ? "2026" : minor >= 30 ? "2022" : minor >= 20 ? "2019" : minor >= 10 ? "2017" : "2015"
            s += " (MSVC / Visual Studio \(vs)" + L(" 相当)", " toolset)")
        } else if [6: "6.0", 7: "2002/2003", 8: "2005", 9: "2008", 10: "2010", 11: "2012", 12: "2013"][Int(major)] != nil {
            s += " (Visual Studio \([6: "6.0", 7: "2002/2003", 8: "2005", 9: "2008", 10: "2010", 11: "2012", 12: "2013"][Int(major)]!))"
        } else if major == 2 && minor >= 20 {
            s += " (GNU ld / MinGW)"
        }
        return s
    }

    static func langName(_ id: Int) -> String {
        let known: [Int: String] = [0x409: "en-US", 0x411: "ja-JP", 0x804: "zh-CN", 0x404: "zh-TW", 0x412: "ko-KR", 0x407: "de-DE",
                                    0x40c: "fr-FR", 0x410: "it-IT", 0xc0a: "es-ES", 0x419: "ru-RU", 0x416: "pt-BR", 0x809: "en-GB",
                                    0x413: "nl-NL", 0x415: "pl-PL", 0x41d: "sv-SE", 0x41f: "tr-TR", 0x405: "cs-CZ", 0x400: "default"]
        if id == 0 { return L("中立", "neutral") }
        return known[id] ?? hex(id, pad: 4)
    }
}

func firstMatch(_ s: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
          let rg = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[rg]).trimmingCharacters(in: .whitespacesAndNewlines)
}
