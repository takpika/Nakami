import Foundation
import Compression
import Security

/// zlib / gzip helpers on top of Foundation's raw-deflate decoder.
enum Inflate {
    static func raw(_ d: Data) -> Data? { try? (d as NSData).decompressed(using: .zlib) as Data }

    /// zlib stream (2-byte header) as used inside xar.
    static func zlib(_ d: Data) -> Data? { d.count > 2 ? raw(d.dropFirst(2).withUnsafeBytes { Data($0) }) : nil }

    /// zlib stream expanded into at most `max` bytes (for formats where a block has a known upper size,
    /// so a damaged or hostile block cannot balloon).
    static func zlib(_ d: Data, max: Int) -> Data? {
        guard d.count > 2, max > 0 else { return nil }
        var out = Data(count: max)
        let n = out.withUnsafeMutableBytes { dst in d.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, max, src.bindMemory(to: UInt8.self).baseAddress! + 2, d.count - 2, nil, COMPRESSION_ZLIB) } }
        guard n > 0 else { return nil }
        if n < max { out.removeSubrange(n...) }
        return out
    }

    /// gzip member (.gz).
    static func gzip(_ d: Data) -> Data? {
        let b = Reader(d, little: true)
        guard d.count > 18, b.u8(0) == 0x1f, b.u8(1) == 0x8b, b.u8(2) == 8 else { return nil }
        let flags = b.u8(3)
        var o = 10
        if flags & 4 != 0 { o += 2 + Int(b.u16(o)) }
        if flags & 8 != 0 { while o < d.count, b.u8(o) != 0 { o += 1 }; o += 1 }
        if flags & 16 != 0 { while o < d.count, b.u8(o) != 0 { o += 1 }; o += 1 }
        if flags & 2 != 0 { o += 2 }
        guard o < d.count else { return nil }
        return raw(b.bytes(o, d.count - o))
    }
}

/// xar archive (the container of flat .pkg files).
struct Xar {
    struct File { var path: String; var isDir: Bool; var offset: Int; var length: Int; var size: Int; var encoding: String }
    let r: Reader
    var heap = 0
    var toc: XMLNode?
    var files: [File] = []

    static func isXar(_ r: Reader) -> Bool { r.be32(0) == 0x7861_7221 }

    init?(_ data: Data) {
        r = Reader(data, little: false)
        guard Xar.isXar(r), data.count > 28 else { return nil }
        let hsize = Int(r.u16(4))
        let clen = Int(clamping: r.u64(8)), ulen = Int(clamping: r.u64(16))
        guard clen > 0, clen < 256 << 20, ulen < 512 << 20, r.ok(hsize, clen), let xml = Inflate.zlib(r.bytes(hsize, clen)) else { return nil }
        heap = hsize + clen
        guard let root = XMLNode.parse(xml), let t = root.first("toc") ?? (root.name == "toc" ? root : nil) else { return nil }
        toc = t
        func walk(_ n: XMLNode, _ prefix: String) {
            for f in n.all("file") where files.count < 100_000 {
                let name = f.first("name")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let type = f.first("type")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "file"
                let d = f.first("data")
                func num(_ k: String) -> Int { Int(d?.first(k)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
                files.append(File(path: path, isDir: type == "directory", offset: num("offset"), length: num("length"), size: num("size"),
                                  encoding: d?.first("encoding")?.attrs["style"] ?? ""))
                walk(f, path)
            }
        }
        walk(t, "")
    }

    func file(_ path: String) -> File? { files.first { $0.path == path } }

    /// Certificates embedded in the table of contents (signer first), signing time and trust.
    func signature() -> (certs: [SecCertificate], names: [String], signedAt: Date?, trusted: Bool?, trustError: String?) {
        var certs = [SecCertificate]()
        if let sig = toc?.first("signature") ?? toc?.first("x-signature") {
            for c in sig.descendants("X509Certificate") {
                let b64 = c.text.components(separatedBy: .whitespacesAndNewlines).joined()
                if let der = Data(base64Encoded: b64), let sc = SecCertificateCreateWithData(nil, der as CFData) { certs.append(sc) }
            }
        }
        let names = certs.map(certName)
        var signedAt: Date?
        if let xs = toc?.first("x-signature"), let off = Int(xs.first("offset")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
           let size = Int(xs.first("size")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""), size < 1 << 20 {
            let cms = decodeCMS(r.bytes(heap + off, size))
            signedAt = cms?.timestamp ?? cms?.signingTime
        }
        var trusted: Bool?
        var trustError: String?
        if !certs.isEmpty {
            var trust: SecTrust?
            if SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust {
                if let signedAt { SecTrustSetVerifyDate(trust, signedAt as CFDate) }
                SecTrustSetNetworkFetchAllowed(trust, false)
                var err: CFError?
                trusted = SecTrustEvaluateWithError(trust, &err)
                trustError = err.flatMap { CFErrorCopyDescription($0) as String? }
            }
        }
        return (certs, names, signedAt, trusted, trustError)
    }


    /// Stored bytes of a member (still gzip/pbzx/… if the member itself is compressed).
    func read(_ f: File, max: Int = 64 << 20) -> Data? {
        guard !f.isDir, f.length <= max, f.size <= max * 4, r.ok(heap + f.offset, f.length) else { return nil }
        let stored = r.bytes(heap + f.offset, f.length)
        if f.encoding.contains("gzip") || f.encoding.contains("zlib") { return Inflate.zlib(stored) }
        if f.encoding.contains("bzip2") { return nil }
        return stored
    }

    func head(_ f: File, _ n: Int) -> Data { r.bytes(heap + f.offset, Swift.min(n, f.length)) }
}

/// cpio archives (odc "070707" and newc "070701"): the Scripts member of a package.
enum Cpio {
    static func entries(_ d: Data, limit: Int = 5000) -> [(name: String, mode: Int, data: Data)] {
        let r = Reader(d)
        var out = [(String, Int, Data)]()
        var o = 0
        func oct(_ at: Int, _ n: Int) -> Int { Int(r.fixedStr(at, n), radix: 8) ?? 0 }
        func hex8(_ at: Int) -> Int { Int(r.fixedStr(at, 8), radix: 16) ?? 0 }
        while r.ok(o, 6), out.count < limit {
            let magic = r.fixedStr(o, 6)
            var name = "", mode = 0, size = 0, dataAt = 0, next = 0
            if magic == "070707" {
                guard r.ok(o, 76) else { break }
                mode = oct(o + 18, 6)
                let nsize = oct(o + 59, 6)
                size = oct(o + 65, 11)
                name = r.fixedStr(o + 76, nsize)
                dataAt = o + 76 + nsize
                next = dataAt + size
            } else if magic == "070701" || magic == "070702" {
                guard r.ok(o, 110) else { break }
                mode = hex8(o + 14)
                size = hex8(o + 54)
                let nsize = hex8(o + 94)
                name = r.fixedStr(o + 110, nsize)
                dataAt = (o + 110 + nsize + 3) & ~3
                next = (dataAt + size + 3) & ~3
            } else { break }
            if name == "TRAILER!!!" { break }
            guard r.ok(dataAt, size) else { break }
            if name.hasPrefix("./") { name.removeFirst(2) }
            if !name.isEmpty, name != "." { out.append((name, mode, r.bytes(dataAt, size))) }
            o = next
        }
        return out
    }
}

/// "Bill of materials": the list of everything a package installs, without unpacking its payload.
enum BOM {
    struct Item { var path: String; var isDir: Bool; var isLink: Bool; var mode: Int; var size: Int }

    static func items(_ d: Data, limit: Int = 300_000) -> [Item] {
        let r = Reader(d, little: false)
        guard r.fixedStr(0, 8) == "BOMStore" else { return [] }
        let indexOff = Int(r.u32(16)), varsOff = Int(r.u32(24))
        let nblocks = Int(r.u32(indexOff))
        func block(_ i: Int) -> (off: Int, len: Int)? {
            guard i > 0, i < nblocks, r.ok(indexOff + 4 + i * 8, 8) else { return nil }
            return (Int(r.u32(indexOff + 4 + i * 8)), Int(r.u32(indexOff + 8 + i * 8)))
        }
        // Named variables → block index of the "Paths" tree.
        var pathsBlock = 0
        var p = varsOff + 4
        for _ in 0..<Swift.min(Int(r.u32(varsOff)), 64) {
            let idx = Int(r.u32(p)), n = Int(r.u8(p + 4))
            if r.fixedStr(p + 5, n) == "Paths" { pathsBlock = idx }
            p += 5 + n
        }
        guard let tree = block(pathsBlock), r.fixedStr(tree.off, 4) == "tree" else { return [] }
        var node = Int(r.u32(tree.off + 8))
        // Descend to the first leaf, then follow the forward links.
        var depth = 0
        while let b = block(node), r.u16(b.off) == 0, depth < 32 {
            node = Int(r.u32(b.off + 12))
            depth += 1
        }
        var names = [Int: (parent: Int, name: String)]()
        var info = [Int: (type: UInt8, mode: Int, size: Int)]()
        var order = [Int]()
        var hops = 0
        while node != 0, let b = block(node), hops < 1_000_000, order.count < limit {
            let count = Int(r.u16(b.off + 2))
            for i in 0..<count {
                let e = b.off + 12 + i * 8
                guard let pi1 = block(Int(r.u32(e))), let fi = block(Int(r.u32(e + 4))) else { continue }
                let id = Int(r.u32(pi1.off))
                names[id] = (Int(r.u32(fi.off)), r.cstr(fi.off + 4, max: Swift.max(0, fi.len - 4)))
                if let pi2 = block(Int(r.u32(pi1.off + 4))) {
                    info[id] = (r.u8(pi2.off), Int(r.u16(pi2.off + 4)), Int(r.u32(pi2.off + 18)))
                }
                order.append(id)
            }
            node = Int(r.u32(b.off + 4))
            hops += 1
        }
        var cache = [Int: String]()
        func path(_ id: Int, _ depth: Int = 0) -> String {
            if let c = cache[id] { return c }
            guard let n = names[id], depth < 64 else { return "" }
            let parent = n.parent == 0 ? "" : path(n.parent, depth + 1)
            let full = parent.isEmpty || parent == "." ? n.name : parent + "/" + n.name
            cache[id] = full
            return full
        }
        return order.compactMap { id in
            let p = path(id)
            guard !p.isEmpty, p != "." else { return nil }
            let i = info[id]
            return Item(path: p.hasPrefix("./") ? String(p.dropFirst(2)) : p, isDir: i?.type == 2, isLink: i?.type == 3, mode: i?.mode ?? 0, size: i?.size ?? 0)
        }
    }
}

/// macOS installer packages (flat .pkg: product archives and component packages).
enum PKG {
    struct Component {
        var name: String          // "Foo.pkg" inside a product archive, "" for a bare component package
        var identifier = ""
        var version = ""
        var location = ""
        var auth = ""
        var restart = ""
        var files = 0
        var kbytes = 0
        var scripts: [(name: String, mode: Int, text: String?, size: Int)] = []
        var declared: [String] = []   // preinstall / postinstall named in PackageInfo
        var bundles: [[String]] = []
        var items: [BOM.Item] = []
        var payloadFormat = ""
    }

    static func text(_ d: Data) -> String? {
        guard !d.prefix(4096).contains(0), d.count < 2 << 20 else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        guard let xar = Xar(data) else { return nil }
        if XIP.isXIP(xar) { return XIP.report(url: url, xar: xar, fileSize: data.count, opts: opts) }
        let looksLikePkg = xar.files.contains { ["Distribution", "PackageInfo", "Bom", "Payload"].contains(($0.path as NSString).lastPathComponent) }
        var rep = Report(kind: .pkg, path: url.path, title: url.lastPathComponent)
        guard looksLikePkg else {
            rep.subtitle = L("xar アーカイブ", "xar archive")
            rep.summary = [Row(L("種類", "Kind"), L("xar アーカイブ（インストーラーパッケージではありません）", "xar archive (not an installer package)")),
                           Row(L("サイズ", "Size"), byteSizeExact(data.count))]
            rep.sections = [contentsSection(xar)]
            return rep
        }

        // ---- Components
        var comps = [Component]()
        let prefixes = Set(xar.files.filter { ($0.path as NSString).lastPathComponent == "PackageInfo" }.map { ($0.path as NSString).deletingLastPathComponent })
        for prefix in prefixes.sorted() {
            func member(_ n: String) -> Xar.File? { xar.file(prefix.isEmpty ? n : prefix + "/" + n) }
            var c = Component(name: prefix)
            if let f = member("PackageInfo"), let d = xar.read(f, max: 8 << 20), let info = XMLNode.parse(d) {
                c.identifier = info.attrs["identifier"] ?? ""
                c.version = info.attrs["version"] ?? ""
                c.location = info.attrs["install-location"] ?? ""
                c.auth = info.attrs["auth"] ?? ""
                c.restart = info.attrs["postinstall-action"] ?? ""
                if let p = info.first("payload") {
                    c.files = Int(p.attrs["numberOfFiles"] ?? "") ?? 0
                    c.kbytes = Int(p.attrs["installKBytes"] ?? "") ?? 0
                }
                c.declared = (info.first("scripts")?.children ?? []).map { $0.name }
                c.bundles = info.descendants("bundle").map { [$0.attrs["path"] ?? "", $0.attrs["id"] ?? "", $0.attrs["CFBundleShortVersionString"] ?? $0.attrs["CFBundleVersion"] ?? ""] }
            }
            if let f = member("Scripts"), let stored = xar.read(f, max: opts.deep ? 512 << 20 : 64 << 20) {
                let cpio = Inflate.gzip(stored) ?? stored
                for e in Cpio.entries(cpio) where e.mode & 0o170000 != 0o040000 && !(e.name as NSString).lastPathComponent.hasPrefix("._") && !e.name.hasSuffix(".DS_Store") {
                    let isMain = ["preinstall", "postinstall", "preupgrade", "postupgrade", "preflight", "postflight", "InstallationCheck", "VolumeCheck"].contains(e.name)
                    c.scripts.append((e.name, e.mode, isMain || e.data.starts(with: [0x23, 0x21]) ? text(e.data) : nil, e.data.count))
                }
            }
            if let f = member("Bom"), let d = xar.read(f, max: opts.deep ? 512 << 20 : 96 << 20) {
                c.items = BOM.items(d, limit: opts.deep ? 300_000 : 60_000)
            }
            if let f = member("Payload") {
                let h = xar.head(f, 4)
                c.payloadFormat = h.starts(with: [0x70, 0x62, 0x7a, 0x78]) ? "pbzx (xz)" : h.starts(with: [0x1f, 0x8b]) ? "gzip + cpio" : h.starts(with: [0x42, 0x5a]) ? "bzip2 + cpio" : ""
            }
            comps.append(c)
        }

        // ---- Distribution (product archives)
        let dist = xar.file("Distribution").flatMap { xar.read($0, max: 8 << 20) }
        let dx = dist.flatMap(XMLNode.parse)
        let isProduct = dx != nil
        let options = dx?.first("options")
        let pkgRefs = dx?.descendants("pkg-ref") ?? []
        var title = dx?.first("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = title, t.isEmpty || !t.contains(" ") && t.uppercased() == t && t.contains("_") { title = nil }  // a localisation key, not a title
        if title == nil, let t = dx?.first("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            // Look the key up in the package's own string tables.
            for lang in prefersJapanese ? ["ja", "Japanese", "en", "English", "Base"] : ["en", "English", "Base"] {
                if let f = xar.file("Resources/\(lang).lproj/Localizable.strings"), let d = xar.read(f, max: 2 << 20),
                   let dict = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: String], let v = dict[t] { title = v; break }
            }
        }
        let product = dx?.first("product")
        let version = product?.attrs["version"] ?? comps.first?.version
        let hostArch = options?.attrs["hostArchitectures"]
        let minOS = (dx?.descendants("os-version") ?? []).compactMap { $0.attrs["min"] }.first

        rep.title = title ?? url.deletingPathExtension().lastPathComponent
        rep.subtitle = L("macOS インストーラー (pkg)", "macOS installer (pkg)") + (version.flatMap { $0.isEmpty ? nil : " · " + L("バージョン ", "Version ") + $0 } ?? "")

        // ---- Signature
        let sig = xar.signature()
        let certs = sig.certs, names = sig.names, signedAt = sig.signedAt, trusted = sig.trusted, trustError = sig.trustError
        let leaf = names.first ?? ""
        var origin: String
        var tone: Tone = .neutral
        if certs.isEmpty { origin = L("署名なし", "Unsigned"); tone = .warn }
        else if leaf.hasPrefix("Developer ID Installer") { origin = "Developer ID"; tone = .good }
        else if leaf.hasPrefix("3rd Party Mac Developer Installer") || leaf.hasPrefix("Apple Distribution") { origin = L("Mac App Store 提出用の署名", "Mac App Store submission signing") }
        else if leaf.contains("Software Update") || leaf.hasSuffix("Software Signing") || leaf == "Apple Installer" { origin = L("Apple のソフトウェア", "Apple software"); tone = .good }
        else { origin = L("署名済み（Apple 発行ではない可能性）", "Signed (possibly not Apple-issued)"); tone = .warn }
        if trusted == false { tone = .warn }
        rep.badges.append(Badge(text: origin, tone: tone))

        // ---- What it installs
        struct Placed { var path: String; var size: Int; var isDir: Bool; var mode: Int; var pkg: String }
        var placed = [Placed]()
        for c in comps {
            let base = c.location.isEmpty || c.location == "/" ? "" : (c.location.hasSuffix("/") ? String(c.location.dropLast()) : c.location)
            for i in c.items { placed.append(Placed(path: base + "/" + i.path, size: i.size, isDir: i.isDir, mode: i.mode, pkg: c.name)) }
        }
        let fileCount = placed.filter { !$0.isDir }.count
        let totalFiles = comps.reduce(0) { $0 + $1.files }
        let totalKB = comps.reduce(0) { $0 + $1.kbytes }
        func items(matching test: (String) -> Bool) -> [String] { placed.map { $0.path }.filter(test) }
        func bundles(_ ext: String) -> [String] {
            // Outermost bundles only.
            var out = [String]()
            for p in placed where p.isDir && p.path.hasSuffix("." + ext) {
                let parent = (p.path as NSString).deletingLastPathComponent
                if !parent.contains(".app/") && !parent.contains(".framework/") && !parent.hasSuffix(".app") { out.append(p.path) }
            }
            return out
        }
        let apps = bundles("app")
        let daemons = items { $0.contains("/LaunchDaemons/") && $0.hasSuffix(".plist") }
        let agents = items { $0.contains("/LaunchAgents/") && $0.hasSuffix(".plist") }
        let kexts = bundles("kext")
        let sysext = bundles("systemextension") + bundles("dext")
        let helpers = items { $0.contains("/PrivilegedHelperTools/") }
        let setuid = placed.filter { !$0.isDir && $0.mode & 0o6000 != 0 }.map { $0.path }
        let hasScripts = comps.contains { !$0.scripts.isEmpty }
        let needsRoot = comps.contains { $0.auth.lowercased() == "root" } || pkgRefs.contains { ($0.attrs["auth"] ?? "").lowercased() == "root" }
        let restart = comps.contains { $0.restart == "restart" } || pkgRefs.contains { ($0.attrs["onConclusion"] ?? "") == "RequireRestart" }
        let logout = comps.contains { $0.restart == "logout" } || pkgRefs.contains { ($0.attrs["onConclusion"] ?? "") == "RequireLogout" }

        if hasScripts { rep.badges.append(Badge(text: L("スクリプトあり", "Runs scripts"), tone: .warn)) }
        if !daemons.isEmpty || !agents.isEmpty { rep.badges.append(Badge(text: L("常駐プロセスを入れる", "Installs background items"), tone: .warn)) }
        if !kexts.isEmpty || !sysext.isEmpty { rep.badges.append(Badge(text: L("システム拡張を入れる", "Installs system extensions"), tone: .warn)) }
        if restart { rep.badges.append(Badge(text: L("再起動が必要", "Requires restart"), tone: .info)) }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), isProduct ? L("インストーラーパッケージ（製品アーカイブ）", "Installer package (product archive)") : L("インストーラーパッケージ（コンポーネント）", "Installer package (component)"))
        sum.add(L("バージョン", "Version"), version)
        sum.add(L("識別子", "Identifier"), product?.attrs["id"] ?? (comps.count == 1 ? comps[0].identifier : nil), mono: true)
        sum.add(L("入手元の判定", "Origin"), origin, tone: tone)
        sum.add(L("署名者", "Signed by"), names.first)
        sum.add(L("対応 OS", "Requires"), minOS.map { "macOS \($0) " + L("以降", "or later") })
        sum.add(L("対応 CPU", "Architectures"), hostArch)
        sum.add(L("含まれるパッケージ", "Packages"), comps.count > 1 ? "\(comps.count)" + L(" 個", "") : nil)
        if totalFiles > 0 || fileCount > 0 {
            sum.add(L("インストールされるもの", "Installs"), "\(Swift.max(totalFiles, fileCount))" + L(" 項目", " items") + (totalKB > 0 ? L("、約 ", ", about ") + byteSize(totalKB * 1024) : ""))
        }
        sum.add(L("アプリ", "Apps"), apps.isEmpty ? nil : apps.prefix(6).joined(separator: "\n") + (apps.count > 6 ? "\n…" : ""), mono: true)
        sum.add(L("管理者権限", "Administrator"), needsRoot ? L("必要", "Required") : nil)
        sum.add(L("スクリプト", "Scripts"), hasScripts ? Array(Set(comps.flatMap { c in c.scripts.filter { $0.text != nil }.map { $0.name } })).sorted().joined(separator: ", ") : nil, tone: .warn)
        sum.add(L("インストール後", "After install"), restart ? L("再起動", "Restart") : logout ? L("ログアウト", "Log out") : nil)
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum

        // ---- Sections
        var srows = [Row]()
        srows.add(L("判定", "Assessment"), origin, tone: tone)
        srows.add(L("署名者", "Signed by"), names.first)
        if names.count > 1 { srows.add(L("証明書チェーン", "Certificate chain"), names.joined(separator: "\n← ")) }
        if let signedAt { srows.add(L("署名日時", "Signed"), dateString(signedAt)) }
        switch trusted {
        case true?: srows.add(L("証明書の信頼", "Certificate trust"), L("信頼済みルートまで検証できました", "Chains to a trusted root"), tone: .good)
        case false?: srows.add(L("証明書の信頼", "Certificate trust"), L("検証できません", "Could not be verified") + (trustError.map { "\n\($0)" } ?? ""), tone: .warn)
        default: break
        }
        rep.sections.append(ReportSection(id: "signature", title: L("署名", "Signature"), symbol: "checkmark.seal",
            blocks: [.rows(srows), .note(L("署名に含まれる証明書を表示しています。パッケージ内容の照合と、公証（ノータリゼーション）の確認は行っていません。",
                                           "Shows the certificates in the signature. The package contents and notarization are not checked."))]))

        if !comps.isEmpty {
            rep.sections.append(ReportSection(id: "packages", title: L("パッケージ", "Packages"), symbol: "shippingbox",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("識別子", "Identifier"), L("バージョン", "Version"), L("インストール先", "Location"), L("項目数", "Items"), L("サイズ", "Size"), L("スクリプト", "Scripts"), L("形式", "Payload")],
                    rows: comps.map { [$0.name.isEmpty ? L("（本体）", "(this package)") : $0.name, $0.identifier, $0.version, $0.location, $0.files > 0 ? "\($0.files)" : "",
                                       $0.kbytes > 0 ? byteSize($0.kbytes * 1024) : "", $0.scripts.filter { $0.text != nil }.map { $0.name }.joined(separator: ", "), $0.payloadFormat] }))],
                count: comps.count))
        }

        // Scripts: the text itself.
        var sblocks = [Block]()
        var scriptCount = 0
        for c in comps where !c.scripts.isEmpty {
            if comps.count > 1 { sblocks.append(.heading(c.name)) }
            for s in c.scripts {
                scriptCount += 1
                if let t = s.text {
                    sblocks.append(.rows([Row(s.name, byteSize(s.size) + (needsRoot ? L("、管理者権限で実行", ", runs as root") : ""), mono: true, tone: .warn)]))
                    sblocks.append(.text(t.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            let others = c.scripts.filter { $0.text == nil }
            if !others.isEmpty {
                sblocks.append(.table(TableData(columns: [L("同梱ファイル", "Bundled file"), L("サイズ", "Size")], rows: others.map { [$0.name, byteSize($0.size)] })))
            }
        }
        if !sblocks.isEmpty {
            rep.sections.append(ReportSection(id: "scripts", title: L("スクリプト", "Scripts"), symbol: "terminal", blocks: sblocks, count: scriptCount))
        }

        // Notable installed items + the full list.
        if !placed.isEmpty {
            var nrows = [Row]()
            func add(_ k: String, _ a: [String], _ tone: Tone = .neutral) {
                if !a.isEmpty { nrows.add(k, a.prefix(12).joined(separator: "\n") + (a.count > 12 ? L("\n（ほか \(a.count - 12) 件）", "\n(\(a.count - 12) more)", "\n（另有 \(a.count - 12) 項）") : ""), mono: true, tone: tone) }
            }
            add(L("アプリ", "Apps"), apps)
            add(L("常駐（全ユーザー）LaunchDaemons", "LaunchDaemons"), daemons, .warn)
            add(L("常駐（ユーザーごと）LaunchAgents", "LaunchAgents"), agents, .warn)
            add(L("特権ヘルパー", "Privileged helpers"), helpers, .warn)
            add(L("カーネル拡張", "Kernel extensions"), kexts, .warn)
            add(L("システム拡張", "System extensions"), sysext, .warn)
            add(L("setuid / setgid", "setuid / setgid"), setuid, .warn)
            // Where things go, by top-level location.
            var byTop = [(String, Int, Int)]()
            for p in placed where !p.isDir {
                let parts = p.path.split(separator: "/")
                let top = "/" + parts.prefix(Swift.min(2, Swift.max(1, parts.count - 1))).joined(separator: "/")
                if let i = byTop.firstIndex(where: { $0.0 == top }) { byTop[i].1 += 1; byTop[i].2 += p.size } else { byTop.append((top, 1, p.size)) }
            }
            var blocks = [Block]()
            if !nrows.isEmpty { blocks.append(.rows(nrows)) }
            blocks.append(.heading(L("入る場所", "Locations")))
            blocks.append(.table(TableData(columns: [L("場所", "Location"), L("ファイル数", "Files"), L("サイズ", "Size")],
                                           rows: byTop.sorted { $0.2 > $1.2 }.prefix(40).map { [$0.0, "\($0.1)", byteSize($0.2)] })))
            blocks.append(.heading(L("すべての項目", "All items")))
            let cap = opts.deep ? 50_000 : 400
            blocks.append(.table(TableData(columns: [L("パス", "Path"), L("サイズ", "Size"), L("権限", "Mode")],
                rows: placed.prefix(cap).map { [$0.path + ($0.isDir ? "/" : ""), $0.isDir ? "" : byteSize($0.size), String($0.mode & 0o7777, radix: 8)] }, total: placed.count)))
            rep.sections.append(ReportSection(id: "installs", title: L("インストールされるもの", "What It Installs"), symbol: "square.and.arrow.down.on.square", blocks: blocks, count: placed.count))
        }

        if let dx {
            var rows = [Row]()
            rows.add(L("タイトル", "Title"), title)
            rows.add(L("対応 CPU", "Host architectures"), hostArch, mono: true)
            rows.add(L("最低 OS", "Minimum OS"), minOS)
            if let d = dx.first("domains") {
                var where_ = [String]()
                if d.attrs["enable_localSystem"] == "true" { where_.append(L("このコンピューター全体", "this computer")) }
                if d.attrs["enable_currentUserHome"] == "true" { where_.append(L("現在のユーザーのみ", "current user only")) }
                if d.attrs["enable_anywhere"] == "true" { where_.append(L("任意のボリューム", "any volume")) }
                rows.add(L("インストール先の選択", "Install domains"), where_.joined(separator: L("、", ", ")))
            }
            if options?.attrs["customize"] == "never" { rows.add(L("カスタムインストール", "Customization"), L("不可", "Not allowed")) }
            if options?.attrs["allow-external-scripts"] == "true" || options?.attrs["allow-external-scripts"] == "yes" {
                rows.add(L("外部スクリプトの実行", "External scripts"), L("許可（インストール前の判定で任意のコマンドを実行できます）", "Allowed (the pre-install check may run arbitrary commands)"), tone: .warn)
            }
            for k in ["license", "readme", "welcome", "conclusion", "background"] {
                if let f = dx.first(k)?.attrs["file"] { rows.add(k, f, mono: true) }
            }
            var blocks: [Block] = [.rows(rows)]
            let choices = dx.descendants("choice").filter { $0.attrs["id"] != nil }
            if !choices.isEmpty {
                blocks.append(.heading(L("選択項目", "Choices")))
                blocks.append(.table(TableData(columns: ["ID", L("名前", "Title"), L("パッケージ", "Packages")], rows: choices.map {
                    [$0.attrs["id"] ?? "", $0.attrs["title"] ?? "", $0.all("pkg-ref").compactMap { $0.attrs["id"] }.joined(separator: ", ")]
                })))
            }
            let js = dx.all("script").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !js.isEmpty {
                blocks.append(.heading(L("インストール可否の判定スクリプト (JavaScript)", "Installation check script (JavaScript)")))
                blocks.append(.text(js))
            }
            if opts.deep, let dist, let raw = String(data: dist, encoding: .utf8) {
                blocks.append(.heading("Distribution"))
                blocks.append(.text(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            rep.sections.append(ReportSection(id: "distribution", title: L("インストーラーの設定", "Installer Settings"), symbol: "doc.text", blocks: blocks))
        }

        let bundleRows = comps.flatMap { $0.bundles }
        if !bundleRows.isEmpty {
            rep.sections.append(ReportSection(id: "bundles", title: L("含まれるバンドル", "Bundles"), symbol: "app.badge",
                blocks: [.table(TableData(columns: [L("パス", "Path"), L("識別子", "Identifier"), L("バージョン", "Version")], rows: bundleRows))], count: bundleRows.count))
        }
        rep.sections.append(contentsSection(xar))
        return rep
    }

    static func contentsSection(_ xar: Xar) -> ReportSection {
        ReportSection(id: "xar", title: L("アーカイブの中身", "Archive Contents"), symbol: "tray.full",
            blocks: [.table(TableData(columns: [L("パス", "Path"), L("サイズ", "Size"), L("格納サイズ", "Stored")],
                                      rows: xar.files.prefix(5000).map { [$0.path + ($0.isDir ? "/" : ""), $0.isDir ? "" : byteSize($0.size), $0.isDir ? "" : byteSize($0.length)] }, total: xar.files.count))],
            count: xar.files.count)
    }
}
