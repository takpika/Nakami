import Foundation
import CoreGraphics

/// OLE Compound File (the container of .msi): flat list of streams.
struct CompoundFile {
    struct Entry { var rawName: [UInt16]; var type: UInt8; var start: UInt32; var size: Int }
    let r: Reader
    var shift = 9
    var miniShift = 6
    var miniCutoff = 4096
    var fat: [UInt32] = []
    var miniFat: [UInt32] = []
    var entries: [Entry] = []
    var miniStream = Data()

    static func isCFB(_ r: Reader) -> Bool { r.be64(0) == 0xd0cf_11e0_a1b1_1ae1 }

    init?(_ data: Data) {
        r = Reader(data, little: true)
        guard CompoundFile.isCFB(r), data.count >= 512 else { return nil }
        shift = Int(r.u16(30)); miniShift = Int(r.u16(32))
        guard shift == 9 || shift == 12, miniShift == 6 else { return nil }
        miniCutoff = Int(r.u32(56))
        let perSector = (1 << shift) / 4
        // DIFAT: 109 entries in the header, then chained sectors.
        var fatSectors = [UInt32]()
        for i in 0..<109 { let s = r.u32(76 + i * 4); if s < 0xffff_fffc { fatSectors.append(s) } }
        var dif = r.u32(68)
        var guardN = 0
        while dif < 0xffff_fffc, guardN < 100_000 {
            let o = sectorOffset(dif)
            for i in 0..<(perSector - 1) { let s = r.u32(o + i * 4); if s < 0xffff_fffc { fatSectors.append(s) } }
            dif = r.u32(o + (perSector - 1) * 4)
            guardN += 1
        }
        fat.reserveCapacity(fatSectors.count * perSector)
        for s in fatSectors {
            let o = sectorOffset(s)
            guard r.ok(o, 1 << shift) else { break }
            for i in 0..<perSector { fat.append(r.u32(o + i * 4)) }
        }
        // Directory
        let dir = chain(r.u32(48), size: nil, limit: 64 << 20)
        let dr = Reader(dir, little: true)
        for i in 0..<(dir.count / 128) {
            let o = i * 128
            let t = dr.u8(o + 66)
            guard t == 1 || t == 2 || t == 5 else { continue }
            let nlen = Swift.max(0, Swift.min(64, Int(dr.u16(o + 64))) / 2 - 1)
            var name = [UInt16]()
            for k in 0..<nlen { name.append(dr.u16(o + k * 2)) }
            let size = shift == 9 ? Int(dr.u32(o + 120)) : Int(clamping: dr.u64(o + 120))
            entries.append(Entry(rawName: name, type: t, start: dr.u32(o + 116), size: size))
        }
        let mf = chain(r.u32(60), size: nil, limit: 64 << 20)
        let mr = Reader(mf, little: true)
        miniFat = (0..<(mf.count / 4)).map { mr.u32($0 * 4) }
        if let root = entries.first(where: { $0.type == 5 }) { miniStream = chain(root.start, size: root.size, limit: 512 << 20) }
    }

    func sectorOffset(_ s: UInt32) -> Int { (Int(s) + 1) << shift }

    func chain(_ start: UInt32, size: Int?, limit: Int) -> Data {
        var out = Data()
        var s = start
        let ss = 1 << shift
        var n = 0
        let want = Swift.min(size ?? limit, limit)
        while s < 0xffff_fffc, Int(s) < fat.count, out.count < want, n < 8_000_000 {
            out.append(r.bytes(sectorOffset(s), ss))
            s = fat[Int(s)]
            n += 1
        }
        if let size, out.count > size { out.removeSubrange(size...) }
        return out
    }

    func read(_ e: Entry, limit: Int = 256 << 20) -> Data {
        guard e.type == 2 else { return Data() }
        if e.size < miniCutoff {
            var out = Data()
            var s = e.start
            var n = 0
            while s < 0xffff_fffc, Int(s) < miniFat.count, out.count < e.size, n < 100_000 {
                let o = Int(s) << miniShift
                guard o + 64 <= miniStream.count else { break }
                out.append(miniStream.subdata(in: (miniStream.startIndex + o)..<(miniStream.startIndex + o + 64)))
                s = miniFat[Int(s)]
                n += 1
            }
            if out.count > e.size { out.removeSubrange(e.size...) }
            return out
        }
        return chain(e.start, size: e.size, limit: limit)
    }
}

/// Windows Installer database inside a compound file.
struct MSIDatabase {
    let cfb: CompoundFile
    var streams: [String: CompoundFile.Entry] = [:]
    var tables: [String: CompoundFile.Entry] = [:]
    var strings: [(off: Int, len: Int)] = []
    var stringData = Data()
    var encoding = String.Encoding.windowsCP1252
    var codepage = 0
    var refSize = 2
    var columns: [String: [(name: String, type: Int)]] = [:]

    static func decodeName(_ raw: [UInt16]) -> (name: String, isTable: Bool) {
        func mime(_ x: UInt16) -> Character {
            switch x {
            case 0..<10: return Character(UnicodeScalar(UInt8(0x30 + x)))
            case 10..<36: return Character(UnicodeScalar(UInt8(0x41 + x - 10)))
            case 36..<62: return Character(UnicodeScalar(UInt8(0x61 + x - 36)))
            case 62: return "."
            default: return "_"
            }
        }
        var s = ""
        var table = false
        for (i, c) in raw.enumerated() {
            if c == 0x4840, i == 0 { table = true }
            else if c >= 0x3800, c < 0x4800 { let v = c - 0x3800; s.append(mime(v & 0x3f)); s.append(mime((v >> 6) & 0x3f)) }
            else if c >= 0x4800, c < 0x4840 { s.append(mime(c - 0x4800)) }
            else if let u = UnicodeScalar(UInt32(c)) { s.append(Character(u)) }
        }
        return (s, table)
    }

    init?(_ data: Data) {
        guard let c = CompoundFile(data) else { return nil }
        cfb = c
        for e in c.entries where e.type == 2 {
            let (n, t) = MSIDatabase.decodeName(e.rawName)
            if t { tables[n] = e } else { streams[n] = e }
        }
        guard let pool = tables["_StringPool"], let sd = tables["_StringData"] else { return nil }
        let p = Reader(cfb.read(pool), little: true)
        stringData = cfb.read(sd)
        codepage = Int(p.u16(0))
        if p.u16(2) & 0x8000 != 0 { refSize = 3 }
        if codepage == 65001 { encoding = .utf8 }
        else if codepage != 0 {
            let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(codepage))
            if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        strings.append((0, 0))  // id 0 = null
        var off = 0
        var i = 1
        let n = p.count / 4
        while i < n {
            var len = Int(p.u16(i * 4))
            let refs = Int(p.u16(i * 4 + 2))
            if len == 0, refs != 0, i + 1 < n {  // long string: high word in the refcount, real entry follows
                len = refs << 16 | Int(p.u16((i + 1) * 4))
                strings.append((0, 0))
                i += 1
            }
            strings.append((off, len))
            off += len
            i += 1
        }
        // Column catalogue
        if let ce = tables["_Columns"] {
            let d = Reader(cfb.read(ce), little: true)
            let rowSize = refSize * 2 + 4
            let rows = d.count / rowSize
            var tmp = [String: [(Int, String, Int)]]()
            for r in 0..<rows {
                let t = string(ref(d, r * refSize))
                let num = Int(d.u16(rows * refSize + r * 2)) ^ 0x8000
                let name = string(ref(d, rows * (refSize + 2) + r * refSize))
                let type = Int(d.u16(rows * (refSize * 2 + 2) + r * 2)) ^ 0x8000
                tmp[t, default: []].append((num, name, type))
            }
            for (t, cols) in tmp { columns[t] = cols.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) } }
        }
    }

    func ref(_ d: Reader, _ o: Int) -> Int {
        refSize == 3 ? Int(d.u16(o)) | Int(d.u8(o + 2)) << 16 : Int(d.u16(o))
    }

    func string(_ id: Int) -> String {
        guard id > 0, id < strings.count else { return "" }
        let s = strings[id]
        guard s.len > 0, s.off + s.len <= stringData.count else { return "" }
        let d = stringData.subdata(in: (stringData.startIndex + s.off)..<(stringData.startIndex + s.off + s.len))
        return String(data: d, encoding: encoding) ?? String(data: d, encoding: .utf8) ?? String(decoding: d, as: Unicode.ASCII.self)
    }

    /// Rows of a table as strings (integers as decimal, null as "").
    func table(_ name: String, limit: Int = 100_000) -> (cols: [String], rows: [[String]], total: Int)? {
        guard let e = tables[name], let cols = columns[name], !cols.isEmpty else { return nil }
        let d = Reader(cfb.read(e), little: true)
        let widths: [Int] = cols.map { c in
            if c.type & 0x0f00 == 0x0900 { return 2 }             // binary / object
            if c.type & 0x0800 != 0 { return refSize }            // string
            return (c.type & 0xff) == 4 ? 4 : 2                   // integer
        }
        let rowSize = widths.reduce(0, +)
        guard rowSize > 0 else { return nil }
        let total = d.count / rowSize
        var rows = [[String]]()
        var colOff = [Int]()
        var acc = 0
        for w in widths { colOff.append(acc * total); acc += w }
        for r in 0..<Swift.min(total, limit) {
            var row = [String]()
            for (i, c) in cols.enumerated() {
                let o = colOff[i] + r * widths[i]
                if c.type & 0x0f00 == 0x0900 { row.append(d.u16(o) != 0 ? "[binary]" : "") }
                else if c.type & 0x0800 != 0 { row.append(string(ref(d, o))) }
                else if widths[i] == 4 { let v = d.u32(o); row.append(v == 0 ? "" : "\(Int32(bitPattern: v ^ 0x8000_0000))") }
                else { let v = d.u16(o); row.append(v == 0 ? "" : "\(Int(v) - 0x8000)") }
            }
            rows.append(row)
        }
        return (cols.map { $0.name }, rows, total)
    }

    func stream(_ name: String, limit: Int = 64 << 20) -> Data? {
        streams[name].map { cfb.read($0, limit: limit) }
    }

    /// \005SummaryInformation property set → [property id: value]
    func summary() -> [Int: Any] {
        guard let d0 = stream("\u{5}SummaryInformation"), d0.count > 48 else { return [:] }
        let d = Reader(d0, little: true)
        let sec = Int(d.u32(44))
        let count = Int(d.u32(sec + 4))
        var out = [Int: Any]()
        var cp = 1252
        for i in 0..<Swift.min(count, 64) {
            let id = Int(d.u32(sec + 8 + i * 8)), o = sec + Int(d.u32(sec + 12 + i * 8))
            let type = d.u32(o) & 0xffff
            switch type {
            case 2: out[id] = Int(Int16(bitPattern: d.u16(o + 4))); if id == 1 { cp = Int(d.u16(o + 4)) }
            case 3: out[id] = Int(d.i32(o + 4))
            case 30:
                let n = Int(d.u32(o + 4))
                var b = d.bytes(o + 8, Swift.min(n, 1 << 16))
                if let z = b.firstIndex(of: 0) { b = b.prefix(upTo: z) }
                var enc = String.Encoding.windowsCP1252
                if cp == 65001 { enc = .utf8 } else {
                    let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
                    if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
                }
                out[id] = String(data: b, encoding: enc) ?? String(decoding: b, as: Unicode.ASCII.self)
            case 64:
                let ft = d.u64(o + 4)
                if ft > 0 { out[id] = Date(timeIntervalSince1970: Double(ft) / 1e7 - 11_644_473_600) }
            default: break
            }
        }
        return out
    }
}

enum MSI {
    static func iconData(_ db: MSIDatabase, props: [String: String]) -> Data? {
        var names = [String]()
        if let k = props["ARPPRODUCTICON"] { names.append("Icon." + k) }
        names += db.streams.keys.filter { $0.hasPrefix("Icon.") }.sorted()
        for n in names {
            guard let d = db.stream(n, limit: 16 << 20), d.count > 22 else { continue }
            if let pe = PEFile(d) { if let ico = pe.iconData(pe.resources()) { return ico } }
            else { return d }
        }
        return nil
    }

    /// Decodes .ico data ourselves: installers often carry icons whose directory is sloppy enough that ImageIO rejects the file.
    static func image(_ data: Data) -> CGImage? {
        let r = Reader(data, little: true)
        var candidates = [(pixels: Int, data: Data)]()
        if r.u16(0) == 0, r.u16(2) == 1 {
            for i in 0..<Swift.min(Int(r.u16(4)), 64) {
                let e = 6 + i * 16
                let size = Int(r.u32(e + 8)), off = Int(r.u32(e + 12))
                guard size > 16, r.ok(off, size) else { continue }
                let body = r.bytes(off, size)
                if body.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
                    candidates.append((Int(r.be32(off + 16)) * 100 + 99, body))
                } else if r.u32(off) == 40 {
                    // DIB: rebuild a clean one-entry icon from the bitmap header.
                    let w = Int(r.u32(off + 4)), h = Int(r.u32(off + 8)) / 2, bpp = r.u16(off + 14)
                    guard w > 0, w <= 256, h > 0, h <= 256 else { continue }
                    var ico = Data([0, 0, 1, 0, 1, 0, UInt8(w & 0xff), UInt8(h & 0xff), 0, 0, 1, 0])
                    withUnsafeBytes(of: bpp.littleEndian) { ico.append(contentsOf: $0) }
                    withUnsafeBytes(of: UInt32(size).littleEndian) { ico.append(contentsOf: $0) }
                    withUnsafeBytes(of: UInt32(22).littleEndian) { ico.append(contentsOf: $0) }
                    ico.append(body)
                    candidates.append((w * 100 + Int(bpp), ico))
                }
            }
        }
        for c in candidates.sorted(by: { $0.pixels > $1.pixels }) {
            if let img = ImageKit.decode(c.data) { return img }
        }
        return ImageKit.decode(data)
    }

    static func icon(_ data: Data) -> CGImage? {
        guard let db = MSIDatabase(data) else { return nil }
        let props = Dictionary((db.table("Property")?.rows ?? []).filter { $0.count >= 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
        return iconData(db, props: props).flatMap(image)
    }

    static func customActionType(_ t: Int) -> String {
        let base = t & 0x3f
        let names: [Int: String] = [1: "DLL (Binary)", 2: "EXE (Binary)", 5: "JScript (Binary)", 6: "VBScript (Binary)", 17: "DLL (installed file)",
                                    18: "EXE (installed file)", 19: "Error message", 21: "JScript (file)", 22: "VBScript (file)", 34: "EXE (directory + command)",
                                    35: "Set directory", 37: "JScript (inline)", 38: "VBScript (inline)", 50: "EXE (property)", 51: "Set property",
                                    53: "JScript (property)", 54: "VBScript (property)", 7: "Nested install", 23: "Nested install", 39: "Nested install"]
        var s = names[base] ?? "type \(base)"
        var f = [String]()
        if t & 0x400 != 0 { f.append(t & 0x800 != 0 ? L("システム権限で実行", "runs as SYSTEM") : L("遅延実行", "deferred")) }
        if t & 0x40 != 0 { f.append(L("失敗を無視", "ignore failure")) }
        if t & 0x80 != 0 { f.append(L("非同期", "async")) }
        if !f.isEmpty { s += " — " + f.joined(separator: ", ") }
        return s
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        guard let db = MSIDatabase(data) else { return nil }
        var rep = Report(kind: .msi, path: url.path, title: url.lastPathComponent)
        let props = Dictionary((db.table("Property")?.rows ?? []).filter { $0.count >= 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
        let sum = db.summary()
        let isPatch = db.tables["Property"] == nil && url.pathExtension.lowercased() == "msp"
        let isMerge = url.pathExtension.lowercased() == "msm"
        rep.title = props["ProductName"] ?? (sum[2] as? String) ?? rep.title
        let version = props["ProductVersion"]
        let kind = isPatch ? L("Windows Installer パッチ (msp)", "Windows Installer patch (msp)") : isMerge ? L("マージモジュール (msm)", "Merge module (msm)") : L("Windows インストーラー (msi)", "Windows Installer package (msi)")
        rep.subtitle = kind + (version.map { " · " + L("バージョン ", "Version ") + $0 } ?? "")
        rep.icon = iconData(db, props: props).flatMap(image)

        // Template: "x64;1033,1041"
        let template = (sum[7] as? String) ?? ""
        let tp = template.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let platform = ["": "x86", "Intel": "x86", "x64": "x64", "AMD64": "x64", "Intel64": "Itanium", "Arm": "ARM32", "Arm64": "ARM64"][tp.first ?? ""] ?? (tp.first ?? "")
        let langs = (tp.count > 1 ? tp[1] : "").split(separator: ",").compactMap { Int($0) }.map { $0 == 0 ? L("中立", "neutral") : PE.langName($0) }
        let wordCount = (sum[15] as? Int) ?? 0
        let schema = (sum[14] as? Int) ?? 0

        // Signature
        var signer: String?
        var sigSection: ReportSection?
        if let p7 = db.stream("\u{5}DigitalSignature"), let cms = decodeCMS(p7, evaluateTrust: true) {
            signer = cms.names.first
            var rows = [Row]()
            rows.add(L("署名者", "Signed by"), cms.names.first)
            if cms.names.count > 1 { rows.add(L("証明書チェーン", "Certificate chain"), cms.names.joined(separator: "\n← ")) }
            if let t = cms.timestamp ?? cms.signingTime { rows.add(L("署名日時", "Signed"), dateString(t)) }
            switch cms.trusted {
            case true?: rows.add(L("証明書の信頼", "Certificate trust"), L("この Mac の信頼済みルートまで検証できました", "Chains to a root trusted by this Mac"), tone: .good)
            case false?: rows.add(L("証明書の信頼", "Certificate trust"), L("この Mac では検証できません", "Could not be verified on this Mac") + (cms.trustError.map { "\n\($0)" } ?? ""))
            default: break
            }
            sigSection = ReportSection(id: "signature", title: L("デジタル署名 (Authenticode)", "Digital Signature (Authenticode)"), symbol: "checkmark.seal",
                blocks: [.rows(rows), .note(L("署名に含まれる証明書を表示しています。ファイル内容のハッシュ照合は行っていません。", "Shows the certificate in the signature; the file hash is not verified."))])
            rep.badges.append(Badge(text: cms.trusted == true ? L("署名済み", "Signed") : L("署名あり（信頼は未確認）", "Signed (trust unverified)"), tone: cms.trusted == true ? .good : .neutral))
        } else {
            rep.badges.append(Badge(text: L("署名なし", "Unsigned"), tone: .neutral))
        }
        if !platform.isEmpty { rep.badges.append(Badge(text: platform, tone: .info)) }

        // Tables
        let files = db.table("File", limit: opts.deep ? 200_000 : 20_000)
        var totalSize = 0
        var fileRows = [(String, Int, String)]()
        if let f = files, let ni = f.cols.firstIndex(of: "FileName"), let si = f.cols.firstIndex(of: "FileSize") {
            let vi = f.cols.firstIndex(of: "Version")
            for r in f.rows {
                let size = Int(r[si]) ?? 0
                totalSize += size
                let name = r[ni].split(separator: "|").last.map(String.init) ?? r[ni]
                fileRows.append((name, size, vi.map { r[$0] } ?? ""))
            }
        }
        let cas = db.table("CustomAction")
        let media = db.table("Media")
        let cabs = (media.flatMap { m in m.cols.firstIndex(of: "Cabinet").map { i in m.rows.map { $0[i] }.filter { !$0.isEmpty } } }) ?? []
        let embedded = cabs.filter { $0.hasPrefix("#") }.count
        let scope: String? = {
            switch props["ALLUSERS"] {
            case "1": return L("全ユーザー（マシン単位）", "Per-machine")
            case "2": return L("権限に応じて切り替え", "Per-machine if possible")
            case nil: return isPatch || isMerge ? nil : L("現在のユーザー（既定）", "Per-user (default)")
            default: return props["ALLUSERS"]
            }
        }()
        let creator = sum[18] as? String
        if let c = creator {
            for k in ["WiX", "InstallShield", "Advanced Installer", "Visual Studio", "Inno", "InstallAware"] where c.localizedCaseInsensitiveContains(k) {
                rep.badges.append(Badge(text: k == "WiX" ? "WiX Toolset" : k, tone: .info)); break
            }
        }
        if let cas, cas.total > 0 {
            let ti = cas.cols.firstIndex(of: "Type")
            let sys = cas.rows.contains { r in ti.flatMap { Int(r[$0]) }.map { $0 & 0xc00 == 0xc00 } ?? false }
            if sys { rep.badges.append(Badge(text: L("システム権限のカスタム処理あり", "SYSTEM custom actions"), tone: .warn)) }
        }

        var s = [Row]()
        s.add(L("種類", "Kind"), kind)
        s.add(L("製品名", "Product"), props["ProductName"])
        s.add(L("バージョン", "Version"), version)
        s.add(L("製造元", "Manufacturer"), props["Manufacturer"] ?? (sum[4] as? String))
        s.add(L("署名者", "Signed by"), signer)
        s.add(L("アーキテクチャ", "Architecture"), platform)
        s.add(L("言語", "Languages"), langs.joined(separator: ", "))
        s.add(L("インストール範囲", "Install scope"), scope)
        if wordCount & 8 != 0 { s.add(L("管理者権限", "Elevation"), L("不要（UAC 昇格なし）", "Not required")) }
        if let f = files {
            s.add(L("インストールされるファイル", "Files installed"), "\(f.total)" + L(" 個、合計 ", " files, ") + byteSize(totalSize) + (f.total > f.rows.count ? "+" : ""))
        }
        if !cabs.isEmpty {
            s.add(L("キャビネット", "Cabinets"), embedded == cabs.count ? L("\(cabs.count) 個（すべて内蔵）", "\(cabs.count) (all embedded)", "\(cabs.count) 個（全部內嵌）") : L("\(cabs.count) 個（うち外部 \(cabs.count - embedded) 個）", "\(cabs.count) (\(cabs.count - embedded) external)", "\(cabs.count) 個（其中外部 \(cabs.count - embedded) 個）"))
        }
        s.add(L("必要な Windows Installer", "Requires Windows Installer"), schema > 0 ? "\(schema / 100).\(schema % 100 / 10)" + L(" 以降", " or later") : nil)
        s.add(L("作成ツール", "Created with"), creator)
        if let d = (sum[12] ?? sum[13]) as? Date { s.add(L("作成日時", "Created"), dateString(d)) }
        s.add(L("説明", "Comments"), (sum[6] as? String).flatMap { $0.isEmpty ? nil : $0 })
        s.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = s

        if let sigSection { rep.sections.append(sigSection) }

        var idRows = [Row]()
        idRows.add("ProductCode", props["ProductCode"], mono: true)
        idRows.add("UpgradeCode", props["UpgradeCode"], mono: true)
        idRows.add(L("パッケージコード", "Package code"), sum[9] as? String, mono: true)
        idRows.add(L("プラットフォーム;言語", "Template"), template, mono: true)
        idRows.add(L("コードページ", "Code page"), db.codepage == 0 ? L("中立 (0)", "neutral (0)") : "\(db.codepage)")
        idRows.add(L("サポート URL", "Support URL"), props["ARPHELPLINK"] ?? props["ARPURLINFOABOUT"])
        idRows.add(L("連絡先", "Contact"), props["ARPCONTACT"])
        if props["ARPSYSTEMCOMPONENT"] == "1" { idRows.add(L("「アプリと機能」", "Programs list"), L("表示しない", "Hidden")) }
        if props["ARPNOREMOVE"] == "1" { idRows.add(L("アンインストール", "Uninstall"), L("不可に設定", "Disabled"), tone: .warn) }
        if let lc = db.table("LaunchCondition"), !lc.rows.isEmpty {
            idRows.add(L("起動条件", "Launch conditions"), lc.rows.map { $0.joined(separator: " → ") }.joined(separator: "\n"))
        }
        rep.sections.append(ReportSection(id: "identity", title: L("パッケージ情報", "Package Info"), symbol: "doc.badge.gearshape", blocks: [.rows(idRows)]))

        if !props.isEmpty {
            rep.sections.append(ReportSection(id: "properties", title: L("プロパティ", "Properties"), symbol: "list.bullet.rectangle",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("値", "Value")], rows: props.keys.sorted().map { [$0, props[$0]!] }))], count: props.count))
        }
        if let f = files, !fileRows.isEmpty {
            let sorted = fileRows.sorted { $0.1 > $1.1 }.prefix(opts.deep ? 20_000 : 300)
            rep.sections.append(ReportSection(id: "files", title: L("ファイル（大きい順）", "Files (largest first)"), symbol: "doc.on.doc",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size"), L("バージョン", "Version")], rows: sorted.map { [$0.0, byteSize($0.1), $0.2] }, total: f.total))], count: f.total))
        }
        if let ft = db.table("Feature"), !ft.rows.isEmpty {
            let pick = ["Feature", "Title", "Description", "Level"].compactMap { ft.cols.firstIndex(of: $0) }
            rep.sections.append(ReportSection(id: "features", title: L("機能 (Feature)", "Features"), symbol: "square.grid.2x2",
                blocks: [.table(TableData(columns: [L("ID", "ID"), L("名前", "Title"), L("説明", "Description"), L("レベル", "Level")].prefix(pick.count).map { $0 }, rows: ft.rows.map { r in pick.map { r[$0] } }))], count: ft.total))
        }
        if let cas, !cas.rows.isEmpty, let ai = cas.cols.firstIndex(of: "Action"), let ti = cas.cols.firstIndex(of: "Type") {
            let si = cas.cols.firstIndex(of: "Source"), gi = cas.cols.firstIndex(of: "Target")
            rep.sections.append(ReportSection(id: "customactions", title: L("カスタム処理 (CustomAction)", "Custom Actions"), symbol: "gearshape.2",
                blocks: [.table(TableData(columns: [L("名前", "Action"), L("種類", "Type"), L("元", "Source"), L("対象", "Target")],
                                          rows: cas.rows.map { r in [r[ai], customActionType(Int(r[ti]) ?? 0), si.map { r[$0] } ?? "", gi.map { r[$0] } ?? ""] }, total: cas.total)),
                         .note(L("インストール中に実行される独自の処理です。「システム権限で実行」は管理者より強い権限で動きます。", "Code run during installation. \"runs as SYSTEM\" executes with the highest privileges."))],
                count: cas.total))
        }
        if let sv = db.table("ServiceInstall"), !sv.rows.isEmpty {
            let pick = ["Name", "DisplayName", "StartType", "StartName"].compactMap { sv.cols.firstIndex(of: $0) }
            let starts = ["0": "boot", "1": "system", "2": L("自動", "automatic"), "3": L("手動", "manual"), "4": L("無効", "disabled")]
            rep.sections.append(ReportSection(id: "services", title: L("サービス", "Services"), symbol: "server.rack",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("表示名", "Display name"), L("開始", "Start"), L("アカウント", "Account")].prefix(pick.count).map { $0 },
                                          rows: sv.rows.map { r in pick.enumerated().map { $0.offset == 2 ? (starts[r[$0.element]] ?? r[$0.element]) : r[$0.element] } }))], count: sv.total))
        }
        if let sc = db.table("Shortcut"), !sc.rows.isEmpty, let ni = sc.cols.firstIndex(of: "Name"), let di = sc.cols.firstIndex(of: "Directory_") {
            let ti = sc.cols.firstIndex(of: "Target")
            rep.sections.append(ReportSection(id: "shortcuts", title: L("ショートカット", "Shortcuts"), symbol: "arrow.up.forward.app",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("場所", "Location"), L("対象", "Target")],
                                          rows: sc.rows.map { r in [r[ni].split(separator: "|").last.map(String.init) ?? r[ni], r[di], ti.map { r[$0] } ?? ""] }))], count: sc.total))
        }
        // Table overview
        var trows = [[String]]()
        for name in db.tables.keys.sorted() where !name.hasPrefix("_") {
            if let t = db.table(name, limit: 0) { trows.append([name, "\(t.total)", "\(t.cols.count)"]) }
        }
        if !trows.isEmpty {
            rep.sections.append(ReportSection(id: "tables", title: L("テーブル", "Tables"), symbol: "tablecells",
                blocks: [.table(TableData(columns: [L("テーブル", "Table"), L("行数", "Rows"), L("列数", "Columns")], rows: trows))], count: trows.count))
        }
        let srows = db.streams.keys.sorted().map { [$0.replacingOccurrences(of: "\u{5}", with: "[5]"), byteSize(db.streams[$0]!.size)] }
        rep.sections.append(ReportSection(id: "streams", title: L("ストリーム", "Streams"), symbol: "tray.full",
            blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: srows))], count: srows.count))
        return rep
    }
}
