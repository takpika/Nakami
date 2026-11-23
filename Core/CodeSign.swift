import Foundation
import Security
import CryptoKit

/// Certificates and times pulled out of a CMS / PKCS#7 SignedData blob.
struct CMSInfo {
    var chain: [SecCertificate] = []   // signer first
    var names: [String] = []
    var signingTime: Date?
    var timestamp: Date?
    /// nil = not evaluated
    var trusted: Bool?
    var trustError: String?
}

func certName(_ c: SecCertificate) -> String {
    (SecCertificateCopySubjectSummary(c) as String?) ?? "?"
}

func decodeCMS(_ blob: Data, evaluateTrust: Bool = false) -> CMSInfo? {
    var info = CMSInfo()
    var certs = [SecCertificate]()
    var signer: SecCertificate?

    #if os(macOS)
    var dec: CMSDecoder?
    if CMSDecoderCreate(&dec) == errSecSuccess, let dec,
       blob.withUnsafeBytes({ CMSDecoderUpdateMessage(dec, $0.baseAddress!, blob.count) }) == errSecSuccess,
       CMSDecoderFinalizeMessage(dec) == errSecSuccess {
        var all: CFArray?
        CMSDecoderCopyAllCerts(dec, &all)
        certs = (all as? [SecCertificate]) ?? []
        var n = 0
        CMSDecoderGetNumSigners(dec, &n)
        if n > 0 {
            CMSDecoderCopySignerCert(dec, 0, &signer)
            var t: CFAbsoluteTime = 0
            if CMSDecoderCopySignerSigningTime(dec, 0, &t) == errSecSuccess, t != 0 {
                info.signingTime = Date(timeIntervalSinceReferenceDate: t)
            }
            var ts: CFAbsoluteTime = 0
            if CMSDecoderCopySignerTimestamp(dec, 0, &ts) == errSecSuccess, ts != 0 {
                info.timestamp = Date(timeIntervalSinceReferenceDate: ts)
            }
        }
    }
    #endif
    // CMSDecoder rejects some blobs (Authenticode's non-"data" content type): read the DER ourselves.
    if certs.isEmpty {
        guard let p = PKCS7.parse(blob) else { return nil }
        certs = p.certs
        signer = p.signer
        info.signingTime = p.signingTime
        info.timestamp = p.timestamp
    }
    guard !certs.isEmpty else { return nil }

    // Order the chain: signer, then each issuer.
    var chain = [SecCertificate]()
    var rest = certs
    var cur = signer ?? leafGuess(certs)
    while let c = cur, chain.count < 10 {
        chain.append(c)
        rest.removeAll { CFEqual($0, c) }
        let issuer = SecCertificateCopyNormalizedIssuerSequence(c) as Data?
        let subject = SecCertificateCopyNormalizedSubjectSequence(c) as Data?
        if issuer == subject { break }
        cur = rest.first { (SecCertificateCopyNormalizedSubjectSequence($0) as Data?) == issuer }
    }
    info.chain = chain
    info.names = chain.map(certName)

    if evaluateTrust, !chain.isEmpty {
        var trust: SecTrust?
        let pool = chain + rest
        if SecTrustCreateWithCertificates(pool as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
            if let when = info.timestamp ?? info.signingTime { SecTrustSetVerifyDate(trust, when as CFDate) }
            SecTrustSetNetworkFetchAllowed(trust, false)
            var err: CFError?
            info.trusted = SecTrustEvaluateWithError(trust, &err)
            if let err { info.trustError = (CFErrorCopyDescription(err) as String?) }
        }
    }
    return info
}

/// Minimal DER walk over a PKCS#7 SignedData: certificates, first signer, signing times.
enum PKCS7 {
    /// `end` is where the content stops, `next` where the following element starts
    /// (they differ for BER indefinite-length elements, which close with 00 00).
    struct TLV { var tag: UInt8; var start: Int; var len: Int; var next: Int; var end: Int { start + len } }

    static func tlv(_ b: [UInt8], _ i: Int, depth: Int = 0) -> TLV? {
        guard i >= 0, i + 2 <= b.count, depth < 32 else { return nil }
        var len = Int(b[i + 1]), s = i + 2
        if len == 0x80 {
            // Indefinite length (Xcode-signed code uses BER here): walk the children up to the end-of-contents marker.
            var j = s
            var guardN = 0
            while j + 2 <= b.count, guardN < 100_000 {
                if b[j] == 0, b[j + 1] == 0 { return TLV(tag: b[i], start: s, len: j - s, next: j + 2) }
                guard let c = tlv(b, j, depth: depth + 1) else { return nil }
                j = c.next
                guardN += 1
            }
            return nil
        }
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n > 0, n <= 4, s + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = len << 8 | Int(b[s + k]) }
            s += n
        }
        guard s + len <= b.count else { return nil }
        return TLV(tag: b[i], start: s, len: len, next: s + len)
    }

    static func children(_ b: [UInt8], _ t: TLV) -> [(at: Int, tlv: TLV)] {
        var out = [(Int, TLV)]()
        var i = t.start
        while i < t.end, let c = tlv(b, i), out.count < 4096 {
            out.append((i, c))
            i = c.next
        }
        return out
    }

    static func time(_ b: [UInt8], _ t: TLV) -> Date? {
        guard t.tag == 0x17 || t.tag == 0x18 else { return nil }
        var s = String(decoding: b[t.start..<t.end], as: Unicode.ASCII.self)
        if let dot = s.firstIndex(of: ".") { s = String(s[..<dot]) + "Z" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = t.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }

    static func find(_ b: [UInt8], _ pat: [UInt8], from: Int = 0) -> Int? {
        guard !pat.isEmpty, b.count >= pat.count, from <= b.count - pat.count else { return nil }
        var i = from
        let last = b.count - pat.count
        while i <= last {
            if b[i] == pat[0], b[i..<(i + pat.count)].elementsEqual(pat) { return i }
            i += 1
        }
        return nil
    }

    /// encapContentInfo's OCTET STRING (possibly split into chunks).
    static func content(_ blob: Data) -> Data? {
        let b = [UInt8](blob)
        guard let outer = tlv(b, 0), outer.tag == 0x30 else { return nil }
        let oc = children(b, outer)
        guard oc.count >= 2, oc[1].tlv.tag == 0xa0, let sd = tlv(b, oc[1].tlv.start), sd.tag == 0x30 else { return nil }
        for (_, c) in children(b, sd) where c.tag == 0x30 {
            let ci = children(b, c)
            guard ci.count >= 2, ci[0].tlv.tag == 0x06, ci[1].tlv.tag == 0xa0, let oct = tlv(b, ci[1].tlv.start) else { continue }
            if oct.tag == 0x04 { return Data(b[oct.start..<oct.end]) }
            if oct.tag == 0x24 {  // constructed: concatenate the pieces
                var out = Data()
                for (_, piece) in children(b, oct) where piece.tag == 0x04 { out.append(contentsOf: b[piece.start..<piece.end]) }
                return out
            }
        }
        return nil
    }

    static func parse(_ blob: Data) -> (certs: [SecCertificate], signer: SecCertificate?, signingTime: Date?, timestamp: Date?)? {
        let b = [UInt8](blob)
        guard let outer = tlv(b, 0), outer.tag == 0x30 else { return nil }
        let oc = children(b, outer)
        guard oc.count >= 2, oc[1].tlv.tag == 0xa0, let sd = tlv(b, oc[1].tlv.start), sd.tag == 0x30 else { return nil }
        var certs = [SecCertificate]()
        var signerSerial: [UInt8]?
        for (_, c) in children(b, sd) {
            if c.tag == 0xa0 {  // certificates
                for (at, cert) in children(b, c) where cert.tag == 0x30 {
                    if let sc = SecCertificateCreateWithData(nil, Data(b[at..<cert.end]) as CFData) { certs.append(sc) }
                }
            } else if c.tag == 0x31, signerSerial == nil, !certs.isEmpty || true {
                // signerInfos (the last SET); the digestAlgorithms SET has no nested issuerAndSerial.
                if let si = children(b, c).first?.tlv, si.tag == 0x30 {
                    let f = children(b, si)
                    if f.count > 1, f[1].tlv.tag == 0x30 {
                        let ias = children(b, f[1].tlv)
                        if ias.count == 2, ias[1].tlv.tag == 0x02 {
                            signerSerial = Array(b[ias[1].tlv.start..<ias[1].tlv.end].drop(while: { $0 == 0 }))
                        }
                    }
                }
            }
        }
        let signer = signerSerial.flatMap { serial in
            certs.first { c in
                guard let d = SecCertificateCopySerialNumberData(c, nil) as Data? else { return false }
                return Array(d.drop(while: { $0 == 0 })) == serial
            }
        }
        // signingTime attribute (1.2.840.113549.1.9.5) and RFC 3161 TSTInfo (1.2.840.113549.1.9.16.1.4) genTime.
        var signing: Date?, stamp: Date?
        let stOID: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05]
        if let at = find(b, stOID), let set = tlv(b, at + stOID.count), set.tag == 0x31, let t = tlv(b, set.start) { signing = time(b, t) }
        let tstOID: [UInt8] = [0x06, 0x0b, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x01, 0x04]
        if let at = find(b, tstOID) {
            var i = at + tstOID.count
            let limit = Swift.min(b.count - 17, i + 400)
            while i < limit {
                if b[i] == 0x18, let t = tlv(b, i), t.len >= 15, t.len <= 24, let d = time(b, t) { stamp = d; break }
                i += 1
            }
        }
        return (certs, signer, signing, stamp)
    }
}

/// A certificate that is nobody's issuer is the leaf.
private func leafGuess(_ certs: [SecCertificate]) -> SecCertificate? {
    let issuers = Set(certs.compactMap { SecCertificateCopyNormalizedIssuerSequence($0) as Data? })
    return certs.first { c in
        guard let s = SecCertificateCopyNormalizedSubjectSequence(c) as Data? else { return false }
        return !issuers.contains(s)
    } ?? certs.first
}

/// Embedded Mach-O code signature (LC_CODE_SIGNATURE), parsed directly from the file.
struct CodeSignature {
    var identifier = ""
    var teamID: String?
    var flags: UInt32 = 0
    var version: UInt32 = 0
    var hashName = ""
    var cdhash = ""
    var pageSize = 0
    var platformBinary = false
    var runtimeVersion: String?
    var entitlements: [String: Any]?
    var cms: CMSInfo?
    var hasCMS = false
    var size = 0

    var isAdHoc: Bool { flags & 0x2 != 0 || !hasCMS }
    var hardenedRuntime: Bool { flags & 0x10000 != 0 }
    var linkerSigned: Bool { flags & 0x20000 != 0 }
    var sandboxed: Bool { (entitlements?["com.apple.security.app-sandbox"] as? Bool) == true }

    static let flagNames: [(UInt32, String)] = [
        (0x1, "host"), (0x2, "adhoc"), (0x4, "get-task-allow"), (0x8, "installer"),
        (0x10, "forced-lv"), (0x20, "invalid-allowed"), (0x100, "hard"), (0x200, "kill"),
        (0x400, "check-expiration"), (0x800, "restrict"), (0x1000, "enforcement"),
        (0x2000, "library-validation"), (0x10000, "runtime"), (0x20000, "linker-signed"),
    ]

    var flagText: String {
        let names = CodeSignature.flagNames.filter { flags & $0.0 != 0 }.map { $0.1 }
        return hex(flags) + (names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")")
    }

    /// One-line description of who signed this.
    var signerText: String {
        if let n = cms?.names.first { return n }
        if linkerSigned { return L("アドホック（リンカーによる自動署名）", "Ad hoc (linker-signed)") }
        return L("アドホック署名", "Ad hoc")
    }

    static func parse(_ r: Reader, at base: Int, size: Int, trust: Bool) -> CodeSignature? {
        guard r.ok(base, 12), r.be32(base) == 0xfade0cc0 else { return nil }
        let count = Int(r.be32(base + 8))
        guard count < 64 else { return nil }
        var sig = CodeSignature()
        sig.size = size
        var bestRank = -1
        for i in 0..<count {
            let type = r.be32(base + 12 + i * 8)
            let off = base + Int(r.be32(base + 16 + i * 8))
            guard r.ok(off, 8) else { continue }
            let magic = r.be32(off)
            let len = Int(r.be32(off + 4))
            guard len >= 8, r.ok(off, len) else { continue }
            switch magic {
            case 0xfade0c02:  // CodeDirectory (slot 0 or alternates 0x1000...)
                let hashType = r.u8(off + 37)
                let rank = [1: 1, 3: 2, 2: 3, 4: 4][Int(hashType)] ?? 0
                guard rank > bestRank else { continue }
                bestRank = rank
                let ver = r.be32(off + 8)
                sig.version = ver
                sig.flags = r.be32(off + 12)
                sig.identifier = r.cstr(off + Int(r.be32(off + 20)), max: 512)
                sig.platformBinary = r.u8(off + 38) != 0
                sig.pageSize = 1 << Int(r.u8(off + 39) & 31)
                if ver >= 0x20200 {
                    let t = Int(r.be32(off + 48))
                    if t > 0 { sig.teamID = r.cstr(off + t, max: 64) }
                }
                if ver >= 0x20500 {
                    let rt = r.be32(off + 88)
                    if rt != 0 { sig.runtimeVersion = "\(rt >> 16).\((rt >> 8) & 0xff).\(rt & 0xff)" }
                }
                let blob = r.bytes(off, len)
                switch hashType {
                case 1: sig.hashName = "SHA-1"; sig.cdhash = hexString(Data(Insecure.SHA1.hash(data: blob)))
                case 2, 3: sig.hashName = "SHA-256"; sig.cdhash = hexString(Data(SHA256.hash(data: blob)).prefix(20))
                case 4: sig.hashName = "SHA-384"; sig.cdhash = hexString(Data(SHA384.hash(data: blob)).prefix(20))
                default: sig.hashName = "type \(hashType)"
                }
            case 0xfade7171:  // XML entitlements
                let xml = r.bytes(off + 8, len - 8)
                sig.entitlements = (try? PropertyListSerialization.propertyList(from: xml, format: nil)) as? [String: Any]
            case 0xfade0b01:  // CMS wrapper
                if len > 8 {
                    sig.hasCMS = true
                    sig.cms = decodeCMS(r.bytes(off + 8, len - 8), evaluateTrust: trust)
                }
            default:
                _ = type
            }
        }
        return bestRank >= 0 ? sig : nil
    }
}

/// Rows describing a signature, shared by Mach-O files and bundles.
func signatureRows(_ s: CodeSignature) -> [Row] {
    var rows = [Row]()
    rows.add(L("署名者", "Signed by"), s.signerText)
    if let names = s.cms?.names, names.count > 1 {
        rows.add(L("証明書チェーン", "Certificate chain"), names.joined(separator: "\n← "))
    }
    rows.add(L("識別子", "Identifier"), s.identifier, mono: true)
    rows.add("Team ID", s.teamID, mono: true)
    if let t = s.cms?.timestamp {
        rows.add(L("署名日時（タイムスタンプ）", "Signed (timestamp)"), dateString(t))
    } else if let t = s.cms?.signingTime {
        rows.add(L("署名日時", "Signed"), dateString(t))
    }
    rows.add("Hardened Runtime", s.hardenedRuntime
        ? L("有効", "Enabled") + (s.runtimeVersion.map { " (\($0))" } ?? "")
        : L("無効", "Disabled"), tone: s.hardenedRuntime ? .good : .neutral)
    rows.add("App Sandbox", s.sandboxed ? L("有効", "Enabled") : L("無効", "Disabled"), tone: s.sandboxed ? .good : .neutral)
    rows.add(L("フラグ", "Flags"), s.flagText, mono: true)
    rows.add("CDHash", s.cdhash.isEmpty ? nil : "\(s.cdhash) (\(s.hashName))", mono: true)
    rows.add(L("形式", "Format"), "CodeDirectory v" + String(s.version, radix: 16) + L("、ページ ", ", page ") + "\(s.pageSize) B")
    if s.platformBinary { rows.add(L("プラットフォームバイナリ", "Platform binary"), L("はい", "Yes")) }
    return rows
}

func entitlementsSection(_ e: [String: Any]) -> ReportSection {
    let rows = e.keys.sorted().map { [$0, describePlistValue(e[$0]!)] }
    return ReportSection(id: "entitlements", title: L("エンタイトルメント", "Entitlements"), symbol: "key",
                         blocks: [.table(TableData(columns: [L("キー", "Key"), L("値", "Value")], rows: rows))],
                         count: rows.count)
}

/// The signed payload of a CMS blob (e.g. a provisioning profile's plist).
func decodeCMSContent(_ blob: Data) -> Data? {
    #if os(macOS)
    var dec: CMSDecoder?
    if CMSDecoderCreate(&dec) == errSecSuccess, let dec,
       blob.withUnsafeBytes({ CMSDecoderUpdateMessage(dec, $0.baseAddress!, blob.count) }) == errSecSuccess,
       CMSDecoderFinalizeMessage(dec) == errSecSuccess {
        var content: CFData?
        CMSDecoderCopyContent(dec, &content)
        if let c = content as Data?, !c.isEmpty { return c }
    }
    #endif
    return PKCS7.content(blob)
}
