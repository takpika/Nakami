import Foundation
import CryptoKit
import Security
import CoreGraphics

/// Android resource string pool (shared by binary XML and resources.arsc).
struct ResStringPool {
    let r: Reader
    let base: Int
    let count: Int
    let utf8: Bool
    let stringsStart: Int
    let size: Int

    init?(_ r: Reader, at base: Int) {
        guard r.ok(base, 28), r.u16(base) == 0x0001 else { return nil }
        self.r = r
        self.base = base
        size = Int(r.u32(base + 4))
        count = Int(r.u32(base + 8))
        utf8 = r.u32(base + 16) & 0x100 != 0
        stringsStart = Int(r.u32(base + 20))
    }

    func string(_ i: Int) -> String {
        guard i >= 0, i < count else { return "" }
        let hsize = Int(r.u16(base + 2))
        var o = base + stringsStart + Int(r.u32(base + hsize + i * 4))
        if utf8 {
            if r.u8(o) & 0x80 != 0 { o += 2 } else { o += 1 }  // character count
            var n = Int(r.u8(o))
            if n & 0x80 != 0 { n = (n & 0x7f) << 8 | Int(r.u8(o + 1)); o += 2 } else { o += 1 }
            return Reader.decode(r.bytes(o, Swift.min(n, 1 << 16)))
        }
        var n = Int(r.u16(o))
        o += 2
        if n & 0x8000 != 0 { n = (n & 0x7fff) << 16 | Int(r.u16(o)); o += 2 }
        return r.utf16(o, units: Swift.min(n, 1 << 15))
    }
}

/// Android binary XML, flattened to elements with their attributes.
struct AXML {
    struct Value { var type: UInt8; var data: UInt32; var string: String? }
    struct Element { var name: String; var depth: Int; var attrs: [String: Value] }

    var elements: [Element] = []

    static let attrIDs: [UInt32: String] = [
        0x0101_0001: "label", 0x0101_0002: "icon", 0x0101_0003: "name", 0x0101_0006: "permission", 0x0101_000f: "debuggable",
        0x0101_0010: "exported", 0x0101_020c: "minSdkVersion", 0x0101_021b: "versionCode", 0x0101_021c: "versionName",
        0x0101_0270: "targetSdkVersion", 0x0101_0271: "maxSdkVersion", 0x0101_0280: "allowBackup", 0x0101_028e: "required",
        0x0101_0281: "glEsVersion", 0x0101_04ec: "usesCleartextTraffic", 0x0101_0572: "compileSdkVersion",
        0x0101_0573: "compileSdkVersionCodename", 0x0101_052c: "roundIcon",
    ]

    init?(_ data: Data) {
        let r = Reader(data, little: true)
        guard r.u16(0) == 0x0003 else { return nil }
        var pool: ResStringPool?
        var resMap = [UInt32]()
        var depth = 0
        var p = Int(r.u16(2))
        while r.ok(p, 8), elements.count < 20000 {
            let type = r.u16(p), hsize = Int(r.u16(p + 2)), size = Int(r.u32(p + 4))
            guard size >= 8 else { break }
            switch type {
            case 0x0001: pool = ResStringPool(r, at: p)
            case 0x0180:
                for i in 0..<((size - hsize) / 4) { resMap.append(r.u32(p + hsize + i * 4)) }
            case 0x0102:
                guard let pool else { break }
                let b = p + hsize
                let attrStart = Int(r.u16(b + 8)), attrSize = Int(r.u16(b + 10)), attrCount = Int(r.u16(b + 12))
                var attrs = [String: Value]()
                for i in 0..<Swift.min(attrCount, 256) {
                    let a = b + attrStart + i * Swift.max(attrSize, 20)
                    let nameIdx = Int(r.u32(a + 4))
                    var name = pool.string(nameIdx)
                    if name.isEmpty, nameIdx < resMap.count, let known = AXML.attrIDs[resMap[nameIdx]] { name = known }  // names stripped by obfuscators
                    let raw = Int(r.i32(a + 8))
                    let dtype = r.u8(a + 15), d = r.u32(a + 16)
                    var str: String? = raw >= 0 ? pool.string(raw) : nil
                    if dtype == 3 { str = pool.string(Int(d)) }
                    attrs[name] = Value(type: dtype, data: d, string: str)
                }
                elements.append(Element(name: pool.string(Int(r.u32(b + 4))), depth: depth, attrs: attrs))
                depth += 1
            case 0x0103: depth = Swift.max(0, depth - 1)
            default: break
            }
            p += size
        }
        guard !elements.isEmpty else { return nil }
    }
}

/// resources.arsc: just enough to resolve a resource id to its values per configuration.
struct ARSC {
    struct Hit { var language: String; var density: Int; var type: UInt8; var data: UInt32; var string: String? }
    let r: Reader
    var global: ResStringPool?
    var types: [(pkg: UInt32, type: Int, chunk: Int)] = []
    /// Set when the table came from an app bundle's resources.pb instead of resources.arsc.
    var proto: [UInt32: [Hit]]?

    init?(proto data: Data) {
        r = Reader(Data())
        guard let t = ARSC.protoTable(data) else { return nil }
        proto = t
    }

    init?(_ data: Data) {
        r = Reader(data, little: true)
        guard r.u16(0) == 0x0002 else { return nil }
        var p = Int(r.u16(2))
        while r.ok(p, 8) {
            let type = r.u16(p), size = Int(r.u32(p + 4))
            guard size >= 8 else { break }
            if type == 0x0001, global == nil { global = ResStringPool(r, at: p) }
            if type == 0x0200 {
                let pkg = r.u32(p + 8)
                var q = p + Int(r.u16(p + 2))
                let end = p + size
                while q + 8 <= end, r.ok(q, 8), types.count < 200_000 {
                    let t = r.u16(q), s = Int(r.u32(q + 4))
                    guard s >= 8 else { break }
                    if t == 0x0201 { types.append((pkg, Int(r.u8(q + 8)), q)) }
                    q += s
                }
            }
            p += size
        }
    }

    func lookup(_ id: UInt32, depth: Int = 0) -> [Hit] {
        if let proto {
            var out = [Hit]()
            for h in proto[id] ?? [] {
                if h.type == 1, depth < 4, h.data != id { out += lookup(h.data, depth: depth + 1).map { var x = $0; if x.language.isEmpty { x.language = h.language }; return x } }
                else { out.append(h) }
            }
            return out
        }
        let pkg = id >> 24, type = Int((id >> 16) & 0xff), entry = Int(id & 0xffff)
        var hits = [Hit]()
        for t in types where t.pkg == pkg && t.type == type {
            let c = t.chunk
            let hsize = Int(r.u16(c + 2)), flags = r.u8(c + 9)
            let count = Int(r.u32(c + 12)), start = Int(r.u32(c + 16))
            let cfg = c + 20
            let langBytes = r.bytes(cfg + 8, 2)
            let language = langBytes.first == 0 || langBytes.isEmpty ? "" : Reader.decode(langBytes)
            let density = Int(r.u16(cfg + 14))
            var off = -1
            if flags & 0x01 != 0 {  // sparse
                for i in 0..<count where Int(r.u16(c + hsize + i * 4)) == entry { off = Int(r.u16(c + hsize + i * 4 + 2)) * 4; break }
            } else if flags & 0x02 != 0 {  // 16-bit offsets
                guard entry < count else { continue }
                let v = r.u16(c + hsize + entry * 2)
                if v != 0xffff { off = Int(v) * 4 }
            } else {
                guard entry < count else { continue }
                let v = r.u32(c + hsize + entry * 4)
                if v != 0xffff_ffff { off = Int(v) }
            }
            guard off >= 0 else { continue }
            let e = c + start + off
            let eflags = r.u16(e + 2)
            var dtype: UInt8, data: UInt32
            if eflags & 0x4 != 0 { dtype = UInt8(eflags >> 8); data = r.u32(e + 4) }  // compact entry
            else if eflags & 0x1 != 0 { continue }  // complex (map) entry
            else { dtype = r.u8(e + 8 + 3); data = r.u32(e + 8 + 4) }
            if dtype == 1, depth < 4, data != id {
                hits += lookup(data, depth: depth + 1).map { var h = $0; if h.language.isEmpty { h.language = language }; return h }
            } else {
                hits.append(Hit(language: language, density: density, type: dtype, data: data, string: dtype == 3 ? global?.string(Int(data)) : nil))
            }
        }
        return hits
    }
}

enum APK {
    static func isAPK(_ zip: Zip) -> Bool { zip.entry("AndroidManifest.xml") != nil }

    static let sdkNames: [Int: String] = [
        1: "1.0", 3: "1.5", 4: "1.6", 7: "2.1", 8: "2.2", 9: "2.3", 10: "2.3.3", 11: "3.0", 14: "4.0", 15: "4.0.3", 16: "4.1", 17: "4.2", 18: "4.3", 19: "4.4", 21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1",
        26: "8.0", 27: "8.1", 28: "9", 29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16",
    ]
    static func sdk(_ n: Int) -> String { "API \(n)" + (sdkNames[n].map { " (Android \($0))" } ?? "") }

    struct Signing {
        var schemes: [String] = []
        var certs: [SecCertificate] = []
        var fingerprint: String?
    }

    /// v1 (JAR) signature files plus the v2/v3 APK Signing Block that sits just before the central directory.
    static func signing(_ zip: Zip) -> Signing {
        var s = Signing()
        let r = zip.r
        for e in zip.entries where e.name.hasPrefix("META-INF/") && [".RSA", ".DSA", ".EC"].contains(where: { e.name.uppercased().hasSuffix($0) }) {
            if !s.schemes.contains("v1") { s.schemes.append("v1") }
            if s.certs.isEmpty, let d = zip.read(e, max: 1 << 20), let c = decodeCMS(d) { s.certs = c.chain }
        }
        let cd = zip.cdOffset
        if cd >= 32, r.fixedStr(cd - 16, 16) == "APK Sig Block 42" {
            let size = Int(clamping: r.u64(cd - 24))
            var p = cd - size
            let end = cd - 24
            var v23 = [SecCertificate]()
            while p + 12 <= end, p > 0 {
                let len = Int(clamping: r.u64(p))
                guard len >= 4, p + 8 + len <= end else { break }
                let id = r.u32(p + 8)
                let name = [0x7109_871a: "v2", 0xf053_68c0: "v3", 0x1b93_ad61: "v3.1"][id]
                if let name {
                    s.schemes.append(name)
                    if v23.isEmpty {
                        // value → signers → signer → signedData → [digests][certificates]…
                        let signers = p + 12
                        let signer = signers + 4
                        let signed = signer + 4
                        let digestsLen = Int(r.u32(signed + 4))
                        let certsAt = signed + 8 + digestsLen
                        let certsLen = Int(r.u32(certsAt))
                        var q = certsAt + 4
                        while q + 4 <= certsAt + 4 + certsLen, v23.count < 8 {
                            let n = Int(r.u32(q))
                            guard n > 0, r.ok(q + 4, n) else { break }
                            if let c = SecCertificateCreateWithData(nil, r.bytes(q + 4, n) as CFData) { v23.append(c) }
                            q += 4 + n
                        }
                    }
                }
                p += 8 + len
            }
            if !v23.isEmpty { s.certs = v23 }
        }
        if zip.entry("stamp-cert-sha256") != nil { s.schemes.append("source stamp") }
        if let c = s.certs.first {
            let der = SecCertificateCopyData(c) as Data
            s.fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        return s
    }

    static func iconData(_ zip: Zip, manifest: AXML, arsc: ARSC?, guess: Bool = true) -> Data? {
        guard let app = manifest.elements.first(where: { $0.name == "application" }),
              let v = app.attrs["icon"] ?? app.attrs["roundIcon"] else { return nil }
        var paths = [(String, Int)]()
        if v.type == 1, let arsc { paths = arsc.lookup(v.data).compactMap { h in h.string.map { ($0, h.density == 0xffff ? 0 : h.density) } } }
        else if let s = v.string { paths = [(s, 0)] }
        let raster = paths.filter { $0.0.hasSuffix(".png") || $0.0.hasSuffix(".webp") }.sorted { $0.1 > $1.1 }
        for (p, _) in raster { if let d = zip.read(p, max: 8 << 20), !d.isEmpty { return d } }
        guard guess else { return nil }
        // Fall back to a bitmap with the same or the conventional launcher name.
        var bases = Set(paths.map { (($0.0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        bases.formUnion(["ic_launcher", "ic_launcher_round", "icon", "app_icon", "ic_launcher_foreground"])
        var best: Zip.Entry?
        for e in zip.entries where e.name.hasPrefix("res/") && (e.name.hasSuffix(".png") || e.name.hasSuffix(".webp")) {
            let b = ((e.name as NSString).lastPathComponent as NSString).deletingPathExtension
            guard bases.contains(b), !b.hasSuffix("_foreground") || best == nil else { continue }
            if best == nil || e.size > best!.size { best = e }
        }
        return best.flatMap { zip.read($0, max: 8 << 20) }
    }

    static func load(_ zip: Zip) -> (AXML, ARSC?)? {
        if let m = zip.read("AndroidManifest.xml", max: 16 << 20), let ax = AXML(m) {
            return (ax, zip.read("resources.arsc", max: 256 << 20).flatMap { ARSC($0) })
        }
        // The base module of an app bundle: the same things in protobuf form.
        guard let m = zip.read("manifest/AndroidManifest.xml", max: 16 << 20), let ax = AXML(proto: m) else { return nil }
        return (ax, zip.read("resources.pb", max: 256 << 20).flatMap { ARSC(proto: $0) })
    }

    static func icon(_ zip: Zip) -> CGImage? {
        guard let (ax, arsc) = load(zip) else { return nil }
        return iconImage(zip, manifest: ax, arsc: arsc)
    }

    /// Launcher icon: a bitmap from the resource table, else the adaptive (XML) icon rendered here,
    /// else a bitmap with a conventional launcher name.
    static func iconImage(_ zip: Zip, manifest: AXML, arsc: ARSC?) -> CGImage? {
        if let d = iconData(zip, manifest: manifest, arsc: arsc, guess: false), let img = ImageKit.decode(d) { return img }
        if let app = manifest.elements.first(where: { $0.name == "application" }), let arsc {
            let renderer = AndroidDrawable(zip: zip, arsc: arsc)
            for key in ["icon", "roundIcon"] {
                guard let v = app.attrs[key], v.type == 1 else { continue }
                for h in arsc.lookup(v.data) {
                    if let p = h.string, p.hasSuffix(".xml"), let img = renderer.adaptiveIcon(xmlPath: p) { return img }
                }
            }
        }
        return iconData(zip, manifest: manifest, arsc: arsc, guess: true).flatMap { ImageKit.decode($0) }
    }

    static func report(url: URL, zip: Zip, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .apk, path: url.path, title: url.lastPathComponent)
        rep.subtitle = L("Android アプリ (apk)", "Android app (apk)")
        guard let (ax, arsc) = load(zip) else {
            rep.summary = [Row(L("種類", "Kind"), L("Android パッケージ（マニフェストを読めません）", "Android package (unreadable manifest)")),
                           Row(L("サイズ", "Size"), byteSize(fileSize))]
            rep.sections = [IPA.largestFiles(zip, strip: "", deep: opts.deep)]
            return rep
        }
        func text(_ v: AXML.Value?) -> String? {
            guard let v else { return nil }
            switch v.type {
            case 3: return v.string
            case 1:
                let hits = arsc?.lookup(v.data) ?? []
                let lang = prefersJapanese ? "ja" : "en"
                return (hits.first { $0.language == lang && $0.string != nil } ?? hits.first { $0.language.isEmpty && $0.string != nil } ?? hits.first { $0.string != nil })?.string
                    ?? hits.first.map { "\($0.data)" } ?? "@" + String(v.data, radix: 16)
            case 0x10, 0x11: return "\(Int32(bitPattern: v.data))"
            case 0x12: return v.data != 0 ? "true" : "false"
            default: return v.string ?? "\(v.data)"
            }
        }
        func flag(_ v: AXML.Value?) -> Bool? { text(v).map { $0 == "true" || $0 == "-1" } }

        let els = ax.elements
        let man = els.first { $0.name == "manifest" }
        let app = els.first { $0.name == "application" }
        let usesSdk = els.first { $0.name == "uses-sdk" }
        let package = text(man?.attrs["package"])
        let versionName = text(man?.attrs["versionName"])
        let versionCode = text(man?.attrs["versionCode"])
        let minSdk = text(usesSdk?.attrs["minSdkVersion"]).flatMap { Int($0) }
        let targetSdk = text(usesSdk?.attrs["targetSdkVersion"]).flatMap { Int($0) }
        let label = text(app?.attrs["label"])
        let debuggable = flag(app?.attrs["debuggable"]) == true
        let permissions = els.filter { $0.name.hasPrefix("uses-permission") }.compactMap { text($0.attrs["name"]) }
        let features = els.filter { $0.name == "uses-feature" }.compactMap { e -> [String]? in
            guard let n = text(e.attrs["name"]) else { return nil }
            return [n, flag(e.attrs["required"]) == false ? L("任意", "optional") : L("必須", "required")]
        }

        rep.title = label ?? package ?? rep.title
        let version: String? = versionName.map { $0 + (versionCode.map { " (\($0))" } ?? "") } ?? versionCode
        if let version { rep.subtitle += " · " + L("バージョン ", "Version ") + version }
        rep.icon = iconImage(zip, manifest: ax, arsc: arsc)

        // Native code
        var abis = [String: [(String, Int)]]()
        for e in zip.entries where e.name.hasPrefix("lib/") && e.name.hasSuffix(".so") {
            let parts = e.name.split(separator: "/")
            if parts.count == 3 { abis[String(parts[1]), default: []].append((String(parts[2]), e.size)) }
        }
        let libNames = Set(abis.values.flatMap { $0.map { $0.0 } })
        var tech = [String]()
        if libNames.contains("libflutter.so") { tech.append("Flutter") }
        if libNames.contains("libunity.so") { tech.append(libNames.contains("libil2cpp.so") ? "Unity (IL2CPP)" : "Unity (Mono)") }
        if libNames.contains("libUE4.so") || libNames.contains("libUnreal.so") { tech.append("Unreal Engine") }
        if libNames.contains("libgodot_android.so") { tech.append("Godot") }
        if libNames.contains("libreactnativejni.so") || libNames.contains("libhermes.so") || zip.entry("assets/index.android.bundle") != nil { tech.append("React Native") }
        if libNames.contains(where: { $0.hasPrefix("libmonodroid") || $0.hasPrefix("libmonosgen") }) { tech.append("Xamarin / .NET") }
        if zip.entry("assets/www/cordova.js") != nil { tech.append("Cordova") }
        if zip.entry("assets/public/cordova.js") != nil || zip.entry("assets/capacitor.config.json") != nil { tech.append("Capacitor") }
        if zip.entries.contains(where: { $0.name.hasPrefix("kotlin/") }) { tech.append("Kotlin") }
        if libNames.contains("libcocos2dcpp.so") || libNames.contains("libcocos2djs.so") { tech.append("Cocos2d-x") }
        let dex = zip.entries.filter { $0.name.hasSuffix(".dex") && !$0.name.contains("/") }

        // Signing
        let sg = signing(zip)
        let signer = sg.certs.first.map(certName)
        let debugCert = signer?.contains("Android Debug") == true
        if sg.schemes.isEmpty { rep.badges.append(Badge(text: L("署名なし", "Unsigned"), tone: .bad)) }
        else if debugCert { rep.badges.append(Badge(text: L("デバッグ用の署名", "Debug-signed"), tone: .warn)) }
        else { rep.badges.append(Badge(text: L("署名あり", "Signed") + " (" + sg.schemes.joined(separator: " + ") + ")", tone: .good)) }
        if debuggable { rep.badges.append(Badge(text: L("デバッグ可能", "Debuggable"), tone: .warn)) }
        if flag(app?.attrs["testOnly"]) == true { rep.badges.append(Badge(text: "testOnly", tone: .warn)) }
        if !abis.isEmpty { rep.badges.append(Badge(text: abis.keys.sorted().joined(separator: " / "), tone: .info)) }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("Android アプリのパッケージ (apk)", "Android app package (apk)"))
        sum.add(L("バージョン", "Version"), version)
        sum.add(L("パッケージ名", "Package"), package, mono: true)
        sum.add(L("対応 OS", "Requires"), minSdk.map { sdk($0) + L(" 以降", " or later") })
        sum.add(L("ターゲット", "Target"), targetSdk.map { sdk($0) })
        sum.add(L("署名者", "Signed by"), signer)
        sum.add(L("対応 CPU", "ABIs"), abis.isEmpty ? L("ネイティブコードなし（全 CPU 対応）", "No native code (any CPU)") : abis.keys.sorted().joined(separator: ", "))
        sum.add(L("技術", "Built with"), tech.joined(separator: ", "))
        sum.add(L("権限", "Permissions"), permissions.isEmpty ? nil : "\(permissions.count)" + L(" 個", ""))
        sum.add(L("サイズ", "Size"), byteSize(fileSize) + L("（展開後 ", " (unpacked ") + byteSize(zip.totalUncompressed) + L("、\(zip.entries.count) 項目）", ", \(zip.entries.count) items)"))
        rep.summary = sum

        // Signature
        var srows = [Row]()
        srows.add(L("署名方式", "Schemes"), sg.schemes.isEmpty ? L("なし", "None") : sg.schemes.joined(separator: ", "))
        srows.add(L("署名者", "Signed by"), signer, tone: debugCert ? .warn : .neutral)
        #if os(macOS)
        if let c = sg.certs.first {
            if let vals = SecCertificateCopyValues(c, [kSecOIDX509V1SubjectName, kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1ValidityNotBefore] as CFArray, nil) as? [String: [String: Any]] {
                if let subj = vals[kSecOIDX509V1SubjectName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
                    let parts = subj.compactMap { d -> String? in
                        guard let v = d[kSecPropertyKeyValue as String] as? String else { return nil }
                        return v
                    }
                    srows.add(L("証明書の名義", "Subject"), parts.joined(separator: ", "))
                }
                func date(_ k: CFString) -> Date? {
                    (vals[k as String]?[kSecPropertyKeyValue as String] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
                }
                if let a = date(kSecOIDX509V1ValidityNotBefore), let b = date(kSecOIDX509V1ValidityNotAfter) {
                    srows.add(L("証明書の有効期間", "Validity"), dateString(a) + " 〜 " + dateString(b))
                }
            }
        }
        #endif
        srows.add(L("証明書の SHA-256", "Certificate SHA-256"), sg.fingerprint, mono: true)
        rep.sections.append(ReportSection(id: "signature", title: L("署名", "Signature"), symbol: "checkmark.seal",
            blocks: [.rows(srows), .note(L("署名に含まれる証明書を表示しています。署名そのものの検証は行っていません。Android の証明書は自己署名が普通で、同じアプリかどうかは SHA-256 の一致で見分けます。",
                                           "Shows the certificate carried by the signature; the signature itself is not verified. Android certificates are normally self-signed: compare the SHA-256 to tell whether two APKs come from the same developer."))]))

        // Manifest
        var mrows = [Row]()
        mrows.add(L("アプリ名", "Label"), label)
        mrows.add(L("パッケージ名", "Package"), package, mono: true)
        mrows.add("versionName", versionName)
        mrows.add("versionCode", versionCode)
        mrows.add("minSdkVersion", minSdk.map { sdk($0) })
        mrows.add("targetSdkVersion", targetSdk.map { sdk($0) })
        mrows.add("compileSdkVersion", text(man?.attrs["compileSdkVersion"]).flatMap { Int($0) }.map { sdk($0) })
        mrows.add(L("Application クラス", "Application class"), text(app?.attrs["name"]), mono: true)
        mrows.add(L("デバッグ", "Debuggable"), debuggable ? L("可能", "Yes") : nil, tone: .warn)
        if let b = flag(app?.attrs["allowBackup"]) { mrows.add(L("バックアップ", "Allow backup"), b ? L("許可", "Allowed") : L("不許可", "Not allowed")) }
        if flag(app?.attrs["usesCleartextTraffic"]) == true { mrows.add(L("平文の HTTP 通信", "Cleartext traffic"), L("許可", "Allowed"), tone: .warn) }
        if let b = flag(app?.attrs["extractNativeLibs"]) { mrows.add(L("ネイティブライブラリの展開", "Extract native libs"), b ? L("する", "Yes") : L("しない", "No")) }
        // Launcher activity
        var launcher: String?
        var curActivity: String?
        for e in els {
            if e.name == "activity" || e.name == "activity-alias" { curActivity = text(e.attrs["name"]) }
            if e.name == "category", text(e.attrs["name"]) == "android.intent.category.LAUNCHER", launcher == nil { launcher = curActivity }
        }
        mrows.add(L("起動するアクティビティ", "Launcher activity"), launcher, mono: true)
        var mblocks: [Block] = [.rows(mrows)]
        let compKinds = [("activity", L("アクティビティ", "Activity")), ("service", L("サービス", "Service")),
                         ("receiver", L("レシーバー", "Receiver")), ("provider", L("プロバイダー", "Provider"))]
        var comps = [[String]]()
        for (tag, name) in compKinds {
            for e in els where e.name == tag {
                comps.append([name, text(e.attrs["name"]) ?? "", flag(e.attrs["exported"]).map { $0 ? L("公開", "exported") : "" } ?? ""])
            }
        }
        if !comps.isEmpty {
            mblocks.append(.heading(L("コンポーネント", "Components")))
            let counts = compKinds.map { k in "\(k.1) \(els.filter { $0.name == k.0 }.count)" }.joined(separator: L("、", ", "))
            mblocks.append(.rows([Row(L("内訳", "Breakdown"), counts)]))
            mblocks.append(.table(TableData(columns: [L("種類", "Kind"), L("クラス", "Class"), L("公開", "Exported")], rows: comps)))
        }
        rep.sections.append(ReportSection(id: "manifest", title: "AndroidManifest", symbol: "doc.text", blocks: mblocks))

        if !permissions.isEmpty || !features.isEmpty {
            let dangerous: Set<String> = ["CAMERA", "RECORD_AUDIO", "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION",
                "READ_CONTACTS", "WRITE_CONTACTS", "READ_SMS", "SEND_SMS", "RECEIVE_SMS", "READ_CALL_LOG", "WRITE_CALL_LOG", "CALL_PHONE",
                "READ_PHONE_STATE", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "MANAGE_EXTERNAL_STORAGE", "READ_CALENDAR", "WRITE_CALENDAR",
                "BODY_SENSORS", "POST_NOTIFICATIONS", "BLUETOOTH_CONNECT", "BLUETOOTH_SCAN", "READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO",
                "READ_MEDIA_AUDIO", "SYSTEM_ALERT_WINDOW", "REQUEST_INSTALL_PACKAGES", "QUERY_ALL_PACKAGES", "BIND_ACCESSIBILITY_SERVICE"]
            var blocks = [Block]()
            if !permissions.isEmpty {
                blocks.append(.table(TableData(columns: [L("権限", "Permission"), L("区分", "Class")], rows: permissions.map {
                    let short = $0.replacingOccurrences(of: "android.permission.", with: "")
                    return [short, dangerous.contains(short) ? L("要注意（利用者の許可が必要）", "sensitive (needs user consent)") : ""]
                })))
            }
            if !features.isEmpty {
                blocks.append(.heading(L("必要な機能", "Features")))
                blocks.append(.table(TableData(columns: [L("機能", "Feature"), L("必須か", "Required")], rows: features)))
            }
            rep.sections.append(ReportSection(id: "permissions", title: L("権限", "Permissions"), symbol: "hand.raised", blocks: blocks, count: permissions.count))
        }

        if !abis.isEmpty {
            var rows = [[String]]()
            for abi in abis.keys.sorted() { for (n, s) in abis[abi]!.sorted(by: { $0.1 > $1.1 }) { rows.append([abi, n, byteSize(s)]) } }
            rep.sections.append(ReportSection(id: "native", title: L("ネイティブライブラリ", "Native Libraries"), symbol: "cpu",
                blocks: [.table(TableData(columns: ["ABI", L("ライブラリ", "Library"), L("サイズ", "Size")], rows: rows))], count: rows.count))
        }
        if !dex.isEmpty {
            rep.sections.append(ReportSection(id: "dex", title: L("コード (DEX)", "Code (DEX)"), symbol: "curlybraces",
                blocks: [.table(TableData(columns: [L("ファイル", "File"), L("サイズ", "Size")], rows: dex.map { [$0.name, byteSize($0.size)] }))], count: dex.count))
        }
        rep.sections.append(IPA.largestFiles(zip, strip: "", deep: opts.deep))
        return rep
    }
}
