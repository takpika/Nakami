import Foundation
import CoreGraphics

/// Classic Mac OS: files with a resource fork (applications, extensions, control panels …), the wrappers
/// that carry them across other systems (MacBinary, BinHex, AppleSingle / AppleDouble), and what the
/// resources say — version, icon, CPU, memory.
enum ClassicMac {
    // MARK: text and dates

    static func text(_ d: Data) -> String {
        if d.contains(where: { $0 >= 0x80 }) {
            // Archives made on Mac OS X store names as UTF-8; a valid multi-byte sequence is no accident.
            if let u = String(data: d, encoding: .utf8) { return u }
            // Japanese systems wrote names in MacJapanese; accept it when it decodes to real kana / kanji.
            let ja = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.macJapanese.rawValue)))
            if let s = String(data: d, encoding: ja), !s.unicodeScalars.contains(where: { $0.value == 0xfffd }) {
                // One stray kanji next to half-width kana is what "™" or "ƒ" turn into: not Japanese.
                let kana = s.unicodeScalars.filter { (0x3040...0x30ff).contains($0.value) }.count
                let kanji = s.unicodeScalars.filter { (0x4e00...0x9fff).contains($0.value) }.count
                let half = s.unicodeScalars.contains { (0xff61...0xff9f).contains($0.value) }
                if kana >= 1 || (kanji >= 2 && !half) { return s }
            }
        }
        return String(data: d, encoding: .macOSRoman) ?? String(decoding: d, as: Unicode.ASCII.self)
    }

    static func pstring(_ r: Reader, _ o: Int, max: Int = 255) -> String { text(r.bytes(o + 1, Swift.min(Int(r.u8(o)), max))) }

    /// Seconds since 1904. Values that land before the Macintosh existed are leftovers, not dates.
    static func date(_ v: UInt32) -> Date? { v < 2_500_000_000 || v == 0xffff_ffff ? nil : Date(timeIntervalSince1970: Double(v) - 2_082_844_800) }

    static func code(_ r: Reader, _ o: Int) -> String {
        let d = r.bytes(o, 4)
        return d.allSatisfy({ $0 == 0 }) ? "" : (String(data: d, encoding: .macOSRoman) ?? "????")
    }

    static let typeNames: [String: (ja: String, en: String)] = [
        "APPL": ("アプリケーション", "Application"), "appe": ("バックグラウンドで動くアプリケーション", "Background application"), "INIT": ("機能拡張", "System extension"),
        "cdev": ("コントロールパネル", "Control panel"), "DRVR": ("デスクアクセサリ / ドライバー", "Desk accessory / driver"), "dfil": ("デスクアクセサリ", "Desk accessory"),
        "RDEV": ("セレクタ用の機能拡張", "Chooser extension"), "PRER": ("プリンタードライバー", "Printer driver"), "PRES": ("プリンタードライバー", "Printer driver"),
        "FFIL": ("フォントスーツケース", "Font suitcase"), "tfil": ("TrueType フォント", "TrueType font"), "LWFN": ("PostScript フォント", "PostScript font"), "sfnt": ("フォント", "Font"),
        "ZSYS": ("システムファイル", "System file"), "zsys": ("システムファイル", "System file"), "FNDR": ("Finder", "Finder"), "shlb": ("共有ライブラリ", "Shared library"),
        "thng": ("コンポーネント", "Component"), "scri": ("システムの言語資源", "Script system resources"), "PACT": ("Compact Pro アーカイブ", "Compact Pro archive"),
        "SIT!": ("StuffIt アーカイブ", "StuffIt archive"), "SITD": ("StuffIt アーカイブ", "StuffIt archive"), "SIT5": ("StuffIt 5 アーカイブ", "StuffIt 5 archive"),
        "dImg": ("ディスクイメージ", "Disk image"), "dimg": ("ディスクイメージ", "Disk image"), "rohd": ("ディスクイメージ", "Disk image"), "hdro": ("ディスクイメージ", "Disk image"),
        "TEXT": ("テキスト書類", "Text document"), "ttro": ("読み出し専用のテキスト書類", "Read-only text document"), "PICT": ("PICT 画像", "PICT picture"),
        "rsrc": ("リソースファイル", "Resource file"), "RSRC": ("リソースファイル", "Resource file"), "ZIVM": ("インストーラーの手順書", "Installer script"),
        "clpp": ("クリップボード", "Clipboard file"), "PREF": ("初期設定ファイル", "Preferences file"), "pref": ("初期設定ファイル", "Preferences file"),
        "MooV": ("QuickTime ムービー", "QuickTime movie"), "snd ": ("サウンド", "System sound"), "sfil": ("サウンド", "Sound file"), "STAK": ("HyperCard スタック", "HyperCard stack"),
        "ndrv": ("ネイティブドライバー", "Native driver"), "expt": ("システム拡張部品", "System enabler part"), "gbly": ("System Enabler", "System Enabler"), "adrp": ("エイリアス", "Alias"),
        "fdrp": ("フォルダーのエイリアス", "Folder alias"), "kcs#": ("キーボード配列", "Keyboard layout"), "fext": ("ファイルシステムの拡張", "File system extension"),
    ]

    static let creatorNames: [String: String] = [
        "MACS": "Mac OS (Finder / System)", "ttxt": "SimpleText", "MSWD": "Microsoft Word", "XCEL": "Microsoft Excel", "MPNT": "MacPaint", "MDRW": "MacDraw", "MWII": "MacWrite II",
        "MACA": "MacWrite", "WILD": "HyperCard", "SIT!": "StuffIt", "SITx": "StuffIt Expander", "CPCT": "Compact Pro", "dCpy": "Disk Copy", "ddsk": "Disk Copy", "oneb": "Disk Copy (self-mounting image)",
        "8BIM": "Adobe Photoshop", "ART5": "Adobe Illustrator", "CARO": "Adobe Acrobat", "MOSS": "Netscape", "MSIE": "Internet Explorer", "CWIE": "CodeWarrior", "MPS ": "MPW",
        "R*ch": "BBEdit", "RSED": "ResEdit", "TVOD": "QuickTime Player", "hscd": "iTunes", "BOBO": "ClarisWorks / AppleWorks", "FMP3": "FileMaker Pro", "aust": "Sound Jam / audio", "STi0": "Stuffit InstallerMaker",
        "bbkr": "Installer", "MSNT": "Microsoft Network", "Doug": "Disk Doubler", "DDAP": "DiskDoubler", "JVWS": "Applet Runner", "ALD3": "PageMaker", "XPR3": "QuarkXPress", "MMDR": "Macromedia Director",
    ]

    static func kindName(_ type: String) -> String {
        typeNames[type].map { L($0.ja, $0.en) } ?? (type.isEmpty ? L("ファイル", "File") : L("書類（タイプ \(type)）", "Document (type \(type))", "文件（類型 \(type)）"))
    }

    // MARK: resource fork

    struct Resources {
        struct Entry { var type: String; var id: Int; var name: String; var offset: Int; var length: Int }
        let r: Reader
        var entries: [Entry] = []

        init?(_ data: Data) {
            r = Reader(data, little: false)
            guard data.count >= 286 else { return nil }
            let dataOff = Int(r.u32(0)), mapOff = Int(r.u32(4)), dataLen = Int(r.u32(8)), mapLen = Int(r.u32(12))
            guard dataOff >= 16, mapOff >= dataOff, mapLen >= 28, mapLen < 16 << 20, r.ok(mapOff, mapLen), dataOff + dataLen <= data.count + 256 else { return nil }
            let typeList = mapOff + Int(r.u16(mapOff + 24)), nameList = mapOff + Int(r.u16(mapOff + 26))
            let types = (Int(r.u16(typeList)) + 1) & 0xffff
            guard types <= 2727, r.ok(typeList + 2, types * 8) else { return nil }
            for t in 0..<types {
                let e = typeList + 2 + t * 8
                let type = String(data: r.bytes(e, 4), encoding: .macOSRoman) ?? "????"
                let count = Int(r.u16(e + 4)) + 1, refs = typeList + Int(r.u16(e + 6))
                for i in 0..<Swift.min(count, 65536) {
                    let ref = refs + i * 12
                    guard r.ok(ref, 12), entries.count < 100_000 else { break }
                    let nameOff = Int(r.u16(ref + 2))
                    let off = dataOff + (Int(r.u32(ref + 4)) & 0x00ff_ffff)
                    guard r.ok(off, 4) else { continue }
                    let len = Int(r.u32(off))
                    guard len >= 0, r.ok(off + 4, len) else { continue }
                    let name = nameOff == 0xffff ? "" : ClassicMac.pstring(r, nameList + nameOff)
                    entries.append(Entry(type: type, id: Int(Int16(bitPattern: r.u16(ref))), name: name, offset: off + 4, length: len))
                }
            }
            guard !entries.isEmpty else { return nil }
        }

        func get(_ type: String, _ id: Int? = nil) -> Data? {
            let hit = id == nil ? entries.filter { $0.type == type }.min { $0.id < $1.id } : entries.first { $0.type == type && $0.id == id }
            return hit.map { r.bytes($0.offset, $0.length) }
        }
        func has(_ type: String) -> Bool { entries.contains { $0.type == type } }
        func ids(_ type: String) -> [Int] { entries.filter { $0.type == type }.map { $0.id }.sorted() }
    }

    /// 'vers' resource: numeric version, stage, and the two strings shown by Get Info.
    static func version(_ d: Data) -> (short: String, long: String)? {
        let r = Reader(d, little: false)
        guard d.count >= 8 else { return nil }
        let short = pstring(r, 6)
        let long = pstring(r, 7 + Int(r.u8(6)))
        if !short.isEmpty { return (short, long) }
        // No string: build "1.2.3b4" from the BCD fields.
        let major = Int(r.u8(0) >> 4) * 10 + Int(r.u8(0) & 0xf), minor = Int(r.u8(1) >> 4), bug = Int(r.u8(1) & 0xf)
        let stage = [0x20: "d", 0x40: "a", 0x60: "b"][Int(r.u8(2))] ?? ""
        return ("\(major).\(minor)" + (bug > 0 ? ".\(bug)" : "") + (stage.isEmpty ? "" : "\(stage)\(r.u8(3))"), long)
    }

    // MARK: icons

    static let clut8: [(UInt8, UInt8, UInt8)] = {
        var c = [(UInt8, UInt8, UInt8)]()
        for i in 0..<215 { c.append((UInt8((5 - i / 36) * 51), UInt8((5 - (i / 6) % 6) * 51), UInt8((5 - i % 6) * 51))) }
        let ramp: [UInt8] = [0xee, 0xdd, 0xbb, 0xaa, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11]
        for v in ramp { c.append((v, 0, 0)) }
        for v in ramp { c.append((0, v, 0)) }
        for v in ramp { c.append((0, 0, v)) }
        for v in ramp { c.append((v, v, v)) }
        c.append((0, 0, 0))
        return c
    }()
    static let clut4: [(UInt8, UInt8, UInt8)] = [
        (255, 255, 255), (252, 243, 5), (255, 100, 2), (221, 8, 6), (242, 8, 132), (70, 0, 165), (0, 0, 212), (2, 171, 234),
        (31, 183, 20), (0, 100, 17), (86, 44, 5), (144, 113, 58), (192, 192, 192), (128, 128, 128), (64, 64, 64), (0, 0, 0)]

    /// A 32×32 icon from the classic icon family: 8-bit colour, 4-bit colour or black and white, with the mask from 'ICN#'.
    static func icon(_ res: Resources, id: Int? = nil) -> CGImage? {
        if let d = res.get("icns", id) ?? res.get("icns"), let img = ImageKit.decode(d) { return img }
        let candidates = id.map { [$0] } ?? (res.ids("ICN#") + res.ids("icl8"))
        // Application icons live at 128 and up; negative IDs belong to the system.
        guard let pick = id ?? candidates.first(where: { $0 >= 128 }) ?? candidates.first else { return nil }
        let bw = res.get("ICN#", pick).map { [UInt8]($0) } ?? []
        let c8 = res.get("icl8", pick).map { [UInt8]($0) } ?? [], c4 = res.get("icl4", pick).map { [UInt8]($0) } ?? []
        guard bw.count >= 128 || c8.count >= 1024 || c4.count >= 512 else { return nil }
        let mask: [UInt8]? = bw.count >= 256 ? Array(bw[128..<256]) : nil
        return Console.image(width: 32, height: 32, scale: 8) { x, y in
            let bit = UInt8(0x80) >> UInt8(x & 7), at = y * 4 + x / 8
            var opaque = mask.map { $0[at] & bit != 0 } ?? true
            if c8.count >= 1024 {
                let c = clut8[Int(c8[y * 32 + x])]
                if mask == nil { opaque = c8[y * 32 + x] != 0 }
                return (c.0, c.1, c.2, opaque ? 255 : 0)
            }
            if c4.count >= 512 {
                let b = c4[y * 16 + x / 2]
                let c = clut4[Int(x & 1 == 0 ? b >> 4 : b & 0xf)]
                return (c.0, c.1, c.2, opaque ? 255 : 0)
            }
            let on = bw[at] & bit != 0
            if mask == nil { opaque = on }
            return on ? (0, 0, 0, opaque ? 255 : 0) : (255, 255, 255, opaque ? 255 : 0)
        }
    }

    /// The icon the Finder would show for this file: its bundle ('BNDL') says which icon belongs to which file type.
    static func bundleIcon(_ res: Resources, type: String) -> CGImage? {
        if let b = res.get("BNDL") {
            let r = Reader(b, little: false)
            var icnMap = [Int: Int](), frefMap = [Int: Int]()
            var o = 8
            for _ in 0..<Swift.min(Int(r.u16(6)) + 1, 8) {
                let t = code(r, o), n = Int(r.u16(o + 4)) + 1
                o += 6
                for _ in 0..<Swift.min(n, 256) {
                    if t == "ICN#" { icnMap[Int(r.u16(o))] = Int(Int16(bitPattern: r.u16(o + 2))) } else if t == "FREF" { frefMap[Int(r.u16(o))] = Int(Int16(bitPattern: r.u16(o + 2))) }
                    o += 4
                }
            }
            for (_, frefID) in frefMap.sorted(by: { $0.key < $1.key }) {
                guard let f = res.get("FREF", frefID), f.count >= 6 else { continue }
                let fr = Reader(f, little: false)
                if code(fr, 0) == type, let iconID = icnMap[Int(fr.u16(4))], let img = icon(res, id: iconID) { return img }
            }
        }
        return icon(res)
    }

    // MARK: code

    /// PowerPC / CFM-68K executable in the data fork ("Joy!peff"): CPU and the libraries it imports.
    static func pef(_ d: Data) -> (arch: String, libraries: [String], built: Date?)? {
        let r = Reader(d, little: false)
        guard d.count > 40, r.fixedStr(0, 8) == "Joy!peff" else { return nil }
        let arch = code(r, 8) == "pwpc" ? "PowerPC" : code(r, 8) == "m68k" ? "68K (CFM)" : code(r, 8)
        var libs = [String]()
        let sections = Int(r.u16(32))
        for i in 0..<Swift.min(sections, 64) {
            let s = 40 + i * 28
            guard r.u8(s + 24) == 4 else { continue }   // loader section
            let off = Int(r.u32(s + 20)), len = Int(r.u32(s + 16))
            guard r.ok(off, 56), len >= 56 else { break }
            let count = Int(r.u32(off + 24)), strings = off + Int(r.u32(off + 40))
            for k in 0..<Swift.min(count, 256) { libs.append(r.cstr(strings + Int(r.u32(off + 56 + k * 24)), max: 128)) }
        }
        return (arch, libs.filter { !$0.isEmpty }, date(r.u32(16)))
    }

    static func architecture(res: Resources?, data: Data?) -> (name: String, libraries: [String]) {
        var parts = [String]()
        var libs = [String]()
        if res?.has("CODE") == true { parts.append("68K") }
        var carbon = res?.has("carb") == true
        if let d = data, let p = pef(d) { if !parts.contains(p.arch) { parts.append(p.arch) }; libs = p.libraries }
        else if let c = res?.get("cfrg"), c.count > 40 {
            // The code fragment resource names the CPU of each fragment.
            let r = Reader(c, little: false)
            var o = 32
            for _ in 0..<Swift.min(Int(r.u32(28)), 16) {
                let a = code(r, o)
                if a == "pwpc", !parts.contains("PowerPC") { parts.append("PowerPC") }
                if a == "m68k", !parts.contains("68K (CFM)") { parts.append("68K (CFM)") }
                let size = Int(r.u16(o + 40))
                guard size >= 43 else { break }
                o += size
            }
        }
        if libs.contains(where: { $0.hasPrefix("CarbonLib") || $0 == "CarbonFrameworkLib" }) { carbon = true }
        var name = parts.joined(separator: " + ")
        if parts.count > 1 { name += L("（両対応）", " (fat)") }
        if carbon { name += name.isEmpty ? "Carbon" : L("、Carbon（Mac OS X でも動作）", ", Carbon (also runs on Mac OS X)") }
        return (name, libs)
    }

    // MARK: wrappers

    struct Fork {
        var name = ""
        var type = "", creator = ""
        var data = Data(), resource = Data()
        var created: Date?, modified: Date?
        var wrapper = ""
    }

    static func crc16(_ b: [UInt8], _ n: Int) -> UInt16 {
        var crc: UInt16 = 0
        for i in 0..<n {
            crc ^= UInt16(b[i]) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    static func macBinary(_ data: Data) -> Fork? {
        let r = Reader(data, little: false)
        guard data.count >= 128, r.u8(0) == 0, r.u8(74) == 0, r.u8(82) == 0 else { return nil }
        let nameLen = Int(r.u8(1))
        let dlen = Int(r.u32(83)), rlen = Int(r.u32(87))
        guard nameLen >= 1, nameLen <= 63, dlen >= 0, rlen >= 0, dlen < 1 << 31, rlen < 1 << 31, dlen + rlen > 0 else { return nil }
        let dpad = (dlen + 127) & ~127
        guard 128 + dpad + rlen <= data.count + 128, 128 + dlen <= data.count else { return nil }
        let isIII = r.fixedStr(102, 4) == "mBIN"
        let crcOK = crc16([UInt8](data.prefix(124)), 124) == r.u16(124)
        // MacBinary I has neither signature nor checksum: require a plausible header instead.
        if !isIII && !crcOK {
            guard r.bytes(99, 27).allSatisfy({ $0 == 0 }), r.bytes(2, nameLen).allSatisfy({ $0 >= 0x20 && $0 != 0x3a }),
                  r.bytes(65, 8).allSatisfy({ $0 >= 0x20 }), 128 + dpad + ((rlen + 127) & ~127) == ((data.count + 127) & ~127) else { return nil }
        }
        var f = Fork(name: text(r.bytes(2, nameLen)), type: code(r, 65), creator: code(r, 69))
        f.data = r.bytes(128, dlen)
        f.resource = r.bytes(128 + dpad, Swift.min(rlen, Swift.max(0, data.count - 128 - dpad)))
        f.created = date(r.u32(91)); f.modified = date(r.u32(95))
        f.wrapper = isIII ? "MacBinary III" : crcOK ? "MacBinary II" : "MacBinary"
        return f
    }

    static func binHex(_ data: Data) -> Fork? {
        guard data.count > 60, let marker = data.prefix(8192).range(of: Data("(This file must be converted with BinHex".utf8)) else { return nil }
        let table = Array("!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr".utf8)
        var map = [UInt8](repeating: 0xff, count: 256)
        for (i, c) in table.enumerated() { map[Int(c)] = UInt8(i) }
        var out = [UInt8]()
        out.reserveCapacity(data.count * 3 / 4)
        var acc = 0, bits = 0, started = false, last: UInt8 = 0, pendingRun = false
        for c in data[marker.upperBound...] {
            if !started { if c == 0x3a { started = true }; continue }
            if c == 0x3a { break }
            let v = map[Int(c)]
            if v == 0xff { continue }
            acc = acc << 6 | Int(v); bits += 6
            guard bits >= 8 else { continue }
            bits -= 8
            let byte = UInt8((acc >> bits) & 0xff)
            // Run-length coding: 0x90 n repeats the previous byte (n = 0 means a literal 0x90).
            if pendingRun {
                pendingRun = false
                if byte == 0 { out.append(0x90); last = 0x90 } else if byte > 1 { out.append(contentsOf: repeatElement(last, count: Int(byte) - 1)) }
            } else if byte == 0x90 { pendingRun = true }
            else { out.append(byte); last = byte }
            if out.count > 512 << 20 { return nil }
        }
        guard out.count > 26 else { return nil }
        let r = Reader(Data(out), little: false)
        let n = Int(r.u8(0))
        guard n >= 1, n <= 63, out.count >= n + 22 else { return nil }
        var f = Fork(name: text(r.bytes(1, n)), type: code(r, n + 2), creator: code(r, n + 6))
        let dlen = Int(r.u32(n + 12)), rlen = Int(r.u32(n + 16))
        let start = n + 22
        // Files cut a little short in transit are still worth reading.
        guard dlen >= 0, rlen >= 0, start + dlen <= out.count + 4096, start < out.count else { return nil }
        f.data = r.bytes(start, Swift.min(dlen, out.count - start))
        f.resource = r.bytes(start + dlen + 2, Swift.min(rlen, Swift.max(0, out.count - start - dlen - 2)))
        f.wrapper = "BinHex 4.0"
        return f
    }

    static func appleSingle(_ data: Data, name: String) -> Fork? {
        let r = Reader(data, little: false)
        guard data.count > 26, r.u32(0) == 0x0005_1600 || r.u32(0) == 0x0005_1607 else { return nil }
        let double = r.u32(0) == 0x0005_1607
        var f = Fork(name: double && name.hasPrefix("._") ? String(name.dropFirst(2)) : name)
        for i in 0..<Swift.min(Int(r.u16(24)), 64) {
            let e = 26 + i * 12
            let id = r.u32(e), off = Int(r.u32(e + 4)), len = Int(r.u32(e + 8))
            guard r.ok(off, len) else { continue }
            switch id {
            case 1: f.data = r.bytes(off, len)
            case 2: f.resource = r.bytes(off, len)
            case 3: f.name = text(r.bytes(off, len))
            case 9 where len >= 8: f.type = code(r, off); f.creator = code(r, off + 4)
            case 8 where len >= 8:
                // Dates count from 2000-01-01, signed.
                func d(_ v: UInt32) -> Date? { v == 0x8000_0000 ? nil : Date(timeIntervalSince1970: 946_684_800 + Double(Int32(bitPattern: v))) }
                f.created = d(r.u32(off)); f.modified = d(r.u32(off + 4))
            default: break
            }
        }
        f.wrapper = double ? L("AppleDouble（リソースフォーク側のファイル）", "AppleDouble (the resource-fork half)") : "AppleSingle"
        return f
    }

    /// A file on this Mac that still has its resource fork (reachable through the named fork).
    static func native(_ url: URL, data: Data) -> Fork? {
        #if os(macOS)
        guard let rsrc = try? Data(contentsOf: url.appendingPathComponent("..namedfork/rsrc")), rsrc.count >= 286 else { return nil }
        var f = Fork(name: url.lastPathComponent)
        f.data = data
        f.resource = rsrc
        var info = [UInt8](repeating: 0, count: 32)
        if getxattr(url.path, "com.apple.FinderInfo", &info, 32, 0, 0) >= 8 {
            let r = Reader(Data(info), little: false)
            f.type = code(r, 0); f.creator = code(r, 4)
        }
        return f
        #else
        return nil
        #endif
    }

    // MARK: report

    static func describe(_ f: Fork, url: URL, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .bundle, path: url.path, title: f.name.isEmpty ? url.lastPathComponent : f.name)
        let res = Resources(f.resource)
        var type = f.type
        if type.isEmpty, let res { type = res.has("CODE") || res.has("cfrg") ? "APPL" : res.has("INIT") ? "INIT" : res.has("cdev") ? "cdev" : "" }
        let kind = "Classic Mac OS " + L("の", "") + kindName(type)
        rep.subtitle = kind
        rep.badges = [Badge(text: "Classic Mac OS", tone: .info)]
        var sum = [Row(L("種類", "Kind"), kind)]
        if let res {
            let v1 = res.get("vers", 1).flatMap { version($0) }, v2 = res.get("vers", 2).flatMap { version($0) }
            sum.add(L("バージョン", "Version"), v1?.short)
            sum.add(L("バージョンの説明", "Version text"), v1?.long == v1?.short ? nil : v1?.long)
            sum.add(L("製品", "Part of"), v2.map { $0.long.isEmpty ? $0.short : $0.long })
            rep.icon = bundleIcon(res, type: type)
        }
        let arch = architecture(res: res, data: f.data)
        sum.add(L("CPU", "CPU"), arch.name)
        if !arch.name.isEmpty { for a in ["68K", "PowerPC", "Carbon"] where arch.name.contains(a) { rep.badges.append(Badge(text: a)) } }
        sum.add(L("ファイルタイプ", "File type"), type.isEmpty ? nil : type, mono: true)
        sum.add(L("クリエーター", "Creator"), f.creator.isEmpty ? nil : f.creator + (creatorNames[f.creator].map { " (\($0))" } ?? ""), mono: true)
        if let res, let s = res.get("SIZE", -1) ?? res.get("SIZE", 0) ?? res.get("SIZE", 1), s.count >= 10 {
            let r = Reader(s, little: false)
            sum.add(L("使用メモリー", "Memory"), L("推奨 \(byteSize(Int(r.u32(2))))、最小 \(byteSize(Int(r.u32(6))))", "preferred \(byteSize(Int(r.u32(2)))), minimum \(byteSize(Int(r.u32(6))))", "建議 \(byteSize(Int(r.u32(2))))、最小 \(byteSize(Int(r.u32(6))))"))
            let flags = r.u16(0)
            sum.add(L("32 ビットアドレス", "32-bit addressing"), flags & 0x0080 != 0 ? L("対応", "Compatible") : L("非対応（24 ビットモードが必要）", "Not compatible (needs 24-bit mode)"))
            if flags & 0x1000 != 0 { sum.add(L("バックグラウンド動作", "Background"), L("可能", "Can run in the background")) }
        }
        if let res, let owner = res.get(f.creator, 0), !f.creator.isEmpty, owner.count > 1 {
            // The signature resource usually holds a one-line description of the program.
            let s = pstring(Reader(owner, little: false), 0)
            if s.count > 3 { sum.add(L("署名の文言", "Signature text"), s.replacingOccurrences(of: "\r", with: "\n")) }
        }
        sum.add(L("包み方", "Wrapped as"), f.wrapper)
        sum.add(L("データフォーク", "Data fork"), byteSize(f.data.count))
        sum.add(L("リソースフォーク", "Resource fork"), byteSize(f.resource.count) + (res.map { L("（リソース \($0.entries.count) 個）", " (\($0.entries.count) resources)", "（資源 \($0.entries.count) 個）") } ?? ""))
        if let c = f.created { sum.add(L("作成日時", "Created"), dateString(c)) }
        if let m = f.modified { sum.add(L("変更日時", "Modified"), dateString(m)) }
        sum.add(L("サイズ", "Size"), byteSizeExact(fileSize))
        rep.summary = sum

        if !arch.libraries.isEmpty {
            rep.sections.append(ReportSection(id: "libraries", title: L("使っている共有ライブラリ", "Imported Libraries"), symbol: "books.vertical",
                                              blocks: [.text(arch.libraries.joined(separator: "\n"))], count: arch.libraries.count))
        }
        if let res {
            // Text the program carries: its about / owner strings are often the only description there is.
            var by = [String: (count: Int, size: Int)]()
            for e in res.entries { let c = by[e.type] ?? (0, 0); by[e.type] = (c.count + 1, c.size + e.length) }
            let rows = by.sorted { $0.value.size > $1.value.size }.map { [$0.key, resourceNames[$0.key].map { L($0.ja, $0.en) } ?? "", "\($0.value.count)", byteSize($0.value.size)] }
            rep.sections.append(ReportSection(id: "resources", title: L("リソース", "Resources"), symbol: "square.grid.3x3",
                blocks: [.table(TableData(columns: [L("タイプ", "Type"), L("内容", "What it is"), L("個数", "Count"), L("サイズ", "Size")], rows: rows))], count: res.entries.count))
            let named = res.entries.filter { !$0.name.isEmpty && ["CODE", "DRVR", "INIT", "cdev", "WDEF", "MDEF", "CDEF", "PACK", "FOND", "snd "].contains($0.type) }
            if !named.isEmpty {
                rep.sections.append(ReportSection(id: "named", title: L("名前のついた部品", "Named Parts"), symbol: "tag",
                    blocks: [.table(TableData(columns: [L("タイプ", "Type"), "ID", L("名前", "Name"), L("サイズ", "Size")], rows: named.prefix(500).map { [$0.type, "\($0.id)", $0.name, byteSize($0.length)] }))], count: named.count))
            }
        }
        return rep
    }

    static let resourceNames: [String: (ja: String, en: String)] = [
        "CODE": ("68K のプログラム", "68K code"), "cfrg": ("PowerPC コードの所在", "Code fragment map"), "DLOG": ("ダイアログ", "Dialogs"), "DITL": ("ダイアログの部品", "Dialog items"),
        "ALRT": ("警告ダイアログ", "Alerts"), "MENU": ("メニュー", "Menus"), "MBAR": ("メニューバー", "Menu bars"), "WIND": ("ウインドウ", "Windows"), "STR ": ("文字列", "Strings"),
        "STR#": ("文字列の一覧", "String lists"), "TEXT": ("テキスト", "Text"), "styl": ("書体情報", "Text styles"), "PICT": ("画像", "Pictures"), "ICON": ("アイコン（白黒）", "Icons (b/w)"),
        "ICN#": ("アイコン（白黒 + マスク）", "Icons (b/w with mask)"), "icl8": ("アイコン（256 色）", "Icons (256 colours)"), "icl4": ("アイコン（16 色）", "Icons (16 colours)"),
        "ics#": ("小さいアイコン", "Small icons"), "ics8": ("小さいアイコン（256 色）", "Small icons (256 colours)"), "ics4": ("小さいアイコン（16 色）", "Small icons (16 colours)"),
        "icns": ("アイコン（新形式）", "Icons (icns)"), "cicn": ("カラーアイコン", "Colour icons"), "BNDL": ("Finder への登録情報", "Finder bundle"), "FREF": ("扱うファイルタイプ", "File references"),
        "vers": ("バージョン", "Version"), "SIZE": ("メモリーの設定", "Memory settings"), "snd ": ("サウンド", "Sounds"), "FONT": ("ビットマップフォント", "Bitmap fonts"),
        "NFNT": ("ビットマップフォント", "Bitmap fonts"), "FOND": ("フォントファミリー", "Font families"), "sfnt": ("TrueType フォント", "TrueType fonts"), "CURS": ("カーソル", "Cursors"),
        "crsr": ("カラーカーソル", "Colour cursors"), "PAT ": ("模様", "Patterns"), "PAT#": ("模様の一覧", "Pattern lists"), "ppat": ("カラー模様", "Colour patterns"),
        "clut": ("色の表", "Colour tables"), "pltt": ("パレット", "Palettes"), "INIT": ("起動時に読み込まれるコード", "Startup code"), "cdev": ("コントロールパネルのコード", "Control panel code"),
        "DRVR": ("ドライバー / デスクアクセサリ", "Drivers / desk accessories"), "WDEF": ("ウインドウの描画コード", "Window definitions"), "MDEF": ("メニューの描画コード", "Menu definitions"),
        "CDEF": ("コントロールの描画コード", "Control definitions"), "LDEF": ("リストの描画コード", "List definitions"), "PACK": ("システムのパッケージ", "Packages"),
        "CNTL": ("コントロール", "Controls"), "aete": ("AppleScript の用語", "AppleScript terminology"), "kind": ("Finder に出す種類名", "Finder kind strings"),
        "open": ("開けるファイルタイプ", "Openable types"), "carb": ("Carbon 対応の印", "Carbon flag"), "plst": ("プロパティリスト", "Property list"), "hmnu": ("バルーンヘルプ（メニュー）", "Balloon help (menus)"),
        "hdlg": ("バルーンヘルプ（ダイアログ）", "Balloon help (dialogs)"), "actb": ("警告の色", "Alert colours"), "dctb": ("ダイアログの色", "Dialog colours"), "wctb": ("ウインドウの色", "Window colours"),
        "KCHR": ("キーボード配列", "Keyboard layout"), "itl0": ("数値と日付の書式", "Number / date formats"), "itl1": ("日付の書式", "Long date formats"), "mach": ("対応機種の指定", "Machine filter"),
        "sysz": ("システムヒープの要求", "System heap request"), "thng": ("コンポーネントの登録", "Component registration"), "TMPL": ("ResEdit のテンプレート", "ResEdit templates"),
    ]

    /// Wrapped or forked classic file → report. `inner` lets the caller look inside the data fork first
    /// (a MacBinary file very often just wraps an archive or a disk image).
    static func report(url: URL, data: Data, opts: AnalyzeOptions, inner: (Data, String) -> Report?) -> Report? {
        let name = url.lastPathComponent
        guard let f = macBinary(data) ?? binHex(data) ?? appleSingle(data, name: name) else { return nil }
        if f.data.count > 64, var rep = inner(f.data, f.name) {
            rep.path = url.path
            let at = rep.summary.firstIndex { $0.key == L("サイズ", "Size") } ?? rep.summary.count
            rep.summary.insert(Row(L("包み方", "Wrapped as"), f.wrapper + L("（中のファイル: \(f.name)）", " (file inside: \(f.name))", "（內含檔案：\(f.name)）")), at: at)
            if at < rep.summary.count - 0, let s = rep.summary.firstIndex(where: { $0.key == L("サイズ", "Size") }) { rep.summary[s] = Row(L("サイズ", "Size"), byteSizeExact(data.count)) }
            if rep.icon == nil, let res = Resources(f.resource) { rep.icon = bundleIcon(res, type: f.type) }
            return rep
        }
        return describe(f, url: url, fileSize: data.count, opts: opts)
    }

    static func icon(_ data: Data, name: String) -> CGImage? {
        guard let f = macBinary(data) ?? binHex(data) ?? appleSingle(data, name: name), let res = Resources(f.resource) else { return nil }
        return bundleIcon(res, type: f.type)
    }
}
