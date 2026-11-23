import Foundation
import CoreGraphics

/// Tiny XML tree (element names without namespace prefixes).
final class XMLNode {
    var name = ""
    var prefix = ""
    var attrs: [String: String] = [:]
    var text = ""
    var children: [XMLNode] = []

    func first(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XMLNode] { children.filter { $0.name == n } }
    func descendants(_ n: String) -> [XMLNode] { children.flatMap { ($0.name == n ? [$0] : []) + $0.descendants(n) } }

    static func parse(_ data: Data) -> XMLNode? {
        final class D: NSObject, XMLParserDelegate {
            var stack = [XMLNode()]
            func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                let n = XMLNode()
                let parts = el.split(separator: ":", maxSplits: 1).map(String.init)
                n.name = parts.last ?? el
                n.prefix = parts.count > 1 ? parts[0] : ""
                n.attrs = attributes
                stack.last!.children.append(n)
                stack.append(n)
            }
            func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
                if stack.count > 1 { stack.removeLast() }
            }
            func parser(_ parser: XMLParser, foundCharacters s: String) { stack.last!.text += s }
        }
        let d = D()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.stack[0].children.first
    }
}

/// Windows app packages: .appx / .msix and their bundles.
enum Appx {
    static func kind(_ zip: Zip) -> String? {
        if zip.entry("AppxMetadata/AppxBundleManifest.xml") != nil { return "bundle" }
        if zip.entry("AppxManifest.xml") != nil { return "package" }
        return nil
    }

    /// Package file names are percent-encoded inside the ZIP.
    static func find(_ zip: Zip, _ path: String) -> Zip.Entry? {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        if let e = zip.entry(p) { return e }
        let enc = p.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? p
        return zip.entry(enc) ?? zip.entries.first { $0.name.removingPercentEncoding?.lowercased() == p.lowercased() }
    }

    /// "Assets\Logo.png" also matches "Assets/Logo.scale-200.png" and "Logo.targetsize-256.png": take the biggest.
    static func logo(_ zip: Zip, _ path: String) -> Data? {
        let p = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let ext = (p as NSString).pathExtension
        let stem = (p as NSString).deletingPathExtension
        var best: Zip.Entry?
        for e in zip.entries {
            let n = (e.name.removingPercentEncoding ?? e.name).lowercased()
            guard n.hasSuffix("." + ext), n == p || n.hasPrefix(stem + ".") else { continue }
            if n.contains("contrast-") || n.contains("_altform-") && !n.contains("unplated") { if best != nil { continue } }
            if best == nil || e.size > best!.size { best = e }
        }
        return best.flatMap { zip.read($0, max: 8 << 20) }
    }

    static func iconData(_ zip: Zip, manifest: XMLNode) -> Data? {
        var candidates = [String]()
        for ve in manifest.descendants("VisualElements") {
            for k in ["Square150x150Logo", "Square44x44Logo", "Logo", "Square30x30Logo"] { if let v = ve.attrs[k] { candidates.append(v) } }
        }
        if let l = manifest.first("Properties")?.first("Logo")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { candidates.append(l) }
        for c in candidates { if let d = logo(zip, c), !d.isEmpty { return d } }
        return nil
    }

    /// The first application package inside a bundle.
    static func mainPackage(_ zip: Zip, bundleManifest: XMLNode, max: Int) -> Zip? {
        let pkgs = bundleManifest.descendants("Package")
        let apps = pkgs.filter { ($0.attrs["Type"] ?? "application").lowercased() == "application" }
        let order = apps.sorted { a, _ in ["arm64", "x64", "neutral"].contains((a.attrs["Architecture"] ?? "").lowercased()) }
        for p in order {
            guard let f = p.attrs["FileName"], let e = find(zip, f), e.size <= max, let d = zip.read(e, max: max) else { continue }
            if let z = Zip(d) { return z }
        }
        return nil
    }

    static func icon(_ zip: Zip) -> CGImage? {
        var z = zip
        if kind(zip) == "bundle" {
            guard let m = zip.read("AppxMetadata/AppxBundleManifest.xml").flatMap(XMLNode.parse),
                  let inner = mainPackage(zip, bundleManifest: m, max: 300 << 20) else { return nil }
            z = inner
        }
        guard let m = z.read("AppxManifest.xml").flatMap(XMLNode.parse), let d = iconData(z, manifest: m) else { return nil }
        return ImageKit.decode(d)
    }

    static func arch(_ a: String?) -> String? {
        guard let a, !a.isEmpty else { return nil }
        return ["x86": "x86", "x64": "x64", "arm": "ARM32", "arm64": "ARM64", "neutral": L("共通（CPU 非依存）", "Neutral")][a.lowercased()] ?? a
    }

    static func windowsBuild(_ v: String?) -> String? {
        guard let v else { return nil }
        let parts = v.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return v }
        let b = parts[2]
        let name: String
        switch b {
        case 22000...: name = "Windows 11" + (b >= 26100 ? " 24H2" : b >= 22621 ? " 22H2" : "")
        case 19041...: name = "Windows 10 2004"
        case 18362...: name = "Windows 10 1903"
        case 17763...: name = "Windows 10 1809"
        case 17134...: name = "Windows 10 1803"
        case 16299...: name = "Windows 10 1709"
        case 15063...: name = "Windows 10 1703"
        case 14393...: name = "Windows 10 1607"
        case 10240...: name = "Windows 10"
        case 9600...: name = "Windows 8.1"
        case 9200...: name = "Windows 8"
        default: return v
        }
        return "\(name) (\(v))"
    }

    static func signatureSection(_ zip: Zip) -> (section: ReportSection, signer: String?, trusted: Bool?)? {
        guard let p7x = zip.read("AppxSignature.p7x", max: 4 << 20), p7x.count > 4 else { return nil }
        let cms = decodeCMS(p7x.dropFirst(4).withUnsafeBytes { Data($0) }, evaluateTrust: true)
        var rows = [Row]()
        rows.add(L("署名者", "Signed by"), cms?.names.first)
        if let n = cms?.names, n.count > 1 { rows.add(L("証明書チェーン", "Certificate chain"), n.joined(separator: "\n← ")) }
        if let t = cms?.timestamp ?? cms?.signingTime { rows.add(L("署名日時", "Signed"), dateString(t)) }
        switch cms?.trusted {
        case true?: rows.add(L("証明書の信頼", "Certificate trust"), L("この Mac の信頼済みルートまで検証できました", "Chains to a root trusted by this Mac"), tone: .good)
        case false?: rows.add(L("証明書の信頼", "Certificate trust"), L("この Mac では検証できません", "Could not be verified on this Mac") + (cms?.trustError.map { "\n\($0)" } ?? ""))
        default: break
        }
        return (ReportSection(id: "signature", title: L("デジタル署名", "Digital Signature"), symbol: "checkmark.seal",
            blocks: [.rows(rows), .note(L("署名に含まれる証明書を表示しています。パッケージ内容のハッシュ照合は行っていません。", "Shows the certificate in the signature; package hashes are not verified."))]),
            cms?.names.first, cms?.trusted)
    }

    static func report(url: URL, zip: Zip, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .appx, path: url.path, title: url.lastPathComponent)
        let isBundle = kind(zip) == "bundle"
        let ext = url.pathExtension.lowercased().hasPrefix("msix") ? "msix" : "appx"
        var pkg = zip
        var bundleManifest: XMLNode?
        if isBundle {
            bundleManifest = zip.read("AppxMetadata/AppxBundleManifest.xml").flatMap(XMLNode.parse)
            if let bm = bundleManifest, let inner = mainPackage(zip, bundleManifest: bm, max: opts.deep ? 2 << 30 : 400 << 20) { pkg = inner }
        }
        let man = (isBundle && pkg.entry("AppxManifest.xml") == nil) ? nil : pkg.read("AppxManifest.xml").flatMap(XMLNode.parse)
        let identity = man?.first("Identity") ?? bundleManifest?.first("Identity")
        let props = man?.first("Properties")
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !s.hasPrefix("ms-resource:") else { return nil }
            return s
        }
        let apps = man?.first("Applications")?.all("Application") ?? []
        let ve = apps.first?.children.first { $0.name == "VisualElements" }
        let display = clean(props?.first("DisplayName")?.text) ?? clean(ve?.attrs["DisplayName"]) ?? identity?.attrs["Name"]
        rep.title = display ?? rep.title
        let version = identity?.attrs["Version"]
        rep.subtitle = (isBundle ? L("Windows アプリのバンドル (\(ext)bundle)", "Windows app bundle (\(ext)bundle)") : L("Windows アプリのパッケージ (\(ext))", "Windows app package (\(ext))"))
            + (version.map { " · " + L("バージョン ", "Version ") + $0 } ?? "")
        if let man, let d = iconData(pkg, manifest: man) { rep.icon = ImageKit.decode(d) }

        let caps = (man?.first("Capabilities")?.children ?? []).compactMap { c -> [String]? in
            guard let n = c.attrs["Name"] else { return nil }
            let cls = c.name == "DeviceCapability" ? L("デバイス", "device") : c.prefix == "rescap" ? L("制限付き", "restricted") : ""
            return [n, cls]
        }
        let fullTrust = caps.contains { $0[0] == "runFullTrust" } || apps.contains { $0.attrs["EntryPoint"] == "Windows.FullTrustApplication" }
        let deps = man?.first("Dependencies")
        let families = (deps?.all("TargetDeviceFamily") ?? [])
        let pkgDeps = deps?.all("PackageDependency") ?? []
        var tech = [String]()
        let depNames = pkgDeps.compactMap { $0.attrs["Name"] }
        if depNames.contains(where: { $0.hasPrefix("Microsoft.WindowsAppRuntime") }) { tech.append("Windows App SDK (WinUI 3)") }
        if depNames.contains(where: { $0.hasPrefix("Microsoft.UI.Xaml") }) { tech.append("WinUI 2") }
        if depNames.contains(where: { $0.hasPrefix("Microsoft.NET.Native") || $0.hasPrefix("Microsoft.NET.CoreRuntime") }) { tech.append(".NET Native") }
        if depNames.contains(where: { $0.hasPrefix("Microsoft.VCLibs") }) { tech.append("C++ (VCLibs)") }
        if pkg.entries.contains(where: { $0.name.lowercased().hasSuffix("resources/app.asar") }) { tech.append("Electron") }
        if pkg.entries.contains(where: { $0.name.lowercased().hasSuffix("flutter_windows.dll") }) { tech.append("Flutter") }
        if pkg.entries.contains(where: { $0.name.lowercased().hasSuffix("unityplayer.dll") }) { tech.append("Unity") }
        tech.append(fullTrust ? L("デスクトップアプリ (Win32)", "Desktop app (Win32)") : "UWP")

        let sig = signatureSection(zip)
        if let s = sig {
            rep.badges.append(Badge(text: s.trusted == true ? L("署名済み", "Signed") : L("署名あり（信頼は未確認）", "Signed (trust unverified)"), tone: s.trusted == true ? .good : .neutral))
        } else {
            rep.badges.append(Badge(text: L("署名なし", "Unsigned"), tone: .warn))
        }
        if fullTrust { rep.badges.append(Badge(text: L("フルトラスト", "Full trust"), tone: .warn)) }

        let archs: String? = isBundle
            ? Array(Set((bundleManifest?.descendants("Package") ?? []).filter { ($0.attrs["Type"] ?? "application").lowercased() == "application" }
                .compactMap { arch($0.attrs["Architecture"]) })).sorted().joined(separator: ", ")
            : arch(identity?.attrs["ProcessorArchitecture"])
        if let a = archs, !a.isEmpty { rep.badges.append(Badge(text: a, tone: .info)) }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), isBundle ? L("Windows アプリのバンドル", "Windows app bundle") : L("Windows アプリのパッケージ", "Windows app package"))
        sum.add(L("バージョン", "Version"), version)
        sum.add(L("パッケージ名", "Package name"), identity?.attrs["Name"], mono: true)
        sum.add(L("発行元", "Publisher"), clean(props?.first("PublisherDisplayName")?.text))
        sum.add(L("発行元 ID", "Publisher ID"), identity?.attrs["Publisher"], mono: true)
        sum.add(L("署名者", "Signed by"), sig?.signer)
        sum.add(L("アーキテクチャ", "Architecture"), archs)
        if let f = families.first {
            sum.add(L("対応 OS", "Requires"), (windowsBuild(f.attrs["MinVersion"]) ?? "") + L(" 以降", " or later") + (families.count > 0 ? "（" + families.compactMap { $0.attrs["Name"] }.joined(separator: ", ") + "）" : ""))
        }
        sum.add(L("技術", "Built with"), tech.joined(separator: ", "))
        sum.add(L("説明", "Description"), clean(props?.first("Description")?.text))
        sum.add(L("サイズ", "Size"), byteSize(fileSize) + L("（展開後 ", " (unpacked ") + byteSize(zip.totalUncompressed) + L("、\(zip.entries.count) 項目）", ", \(zip.entries.count) items)"))
        rep.summary = sum

        if let s = sig { rep.sections.append(s.section) }

        if let bm = bundleManifest {
            let rows: [[String]] = bm.descendants("Package").map { (p: XMLNode) -> [String] in
                let file: String = p.attrs["FileName"] ?? ""
                let type: String = p.attrs["Type"] ?? "application"
                let cpu: String = arch(p.attrs["Architecture"]) ?? ""
                let version: String = p.attrs["Version"] ?? ""
                let qualifiers: [String] = p.descendants("Resource").compactMap { (r: XMLNode) -> String? in
                    if let lang = r.attrs["Language"] { return lang }
                    return r.attrs["Scale"].map { "scale-" + $0 }
                }
                let resources: String = p.attrs["ResourceId"] ?? qualifiers.joined(separator: ", ")
                let size: String = p.attrs["Size"].flatMap { Int($0) }.map { byteSize($0) } ?? ""
                return [file, type, cpu, version, resources, size]
            }
            rep.sections.append(ReportSection(id: "packages", title: L("含まれるパッケージ", "Packages"), symbol: "shippingbox",
                blocks: [.table(TableData(columns: [L("ファイル", "File"), L("種類", "Type"), L("アーキテクチャ", "Arch"), L("バージョン", "Version"), L("リソース", "Resources"), L("サイズ", "Size")], rows: rows))], count: rows.count))
        }

        if !apps.isEmpty {
            var blocks = [Block]()
            for a in apps {
                var rows = [Row]()
                let v = a.children.first { $0.name == "VisualElements" }
                rows.add("ID", a.attrs["Id"], mono: true)
                rows.add(L("表示名", "Display name"), clean(v?.attrs["DisplayName"]))
                rows.add(L("実行ファイル", "Executable"), a.attrs["Executable"], mono: true)
                rows.add(L("エントリーポイント", "Entry point"), a.attrs["EntryPoint"] ?? a.attrs["StartPage"], mono: true)
                rows.add(L("タイルの背景色", "Tile color"), v?.attrs["BackgroundColor"], mono: true)
                let exts = (a.first("Extensions")?.children ?? []).compactMap { e -> String? in
                    guard let c = e.attrs["Category"] else { return nil }
                    var d = c.replacingOccurrences(of: "windows.", with: "")
                    if let p = e.descendants("Protocol").first?.attrs["Name"] { d += " (\(p)://)" }
                    let fts = e.descendants("FileType").map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if !fts.isEmpty { d += " (" + fts.prefix(12).joined(separator: " ") + (fts.count > 12 ? " …" : "") + ")" }
                    if let al = e.descendants("ExecutionAlias").first?.attrs["Alias"] { d += " (\(al))" }
                    return d
                }
                rows.add(L("拡張機能", "Extensions"), exts.joined(separator: "\n"))
                blocks.append(.rows(rows))
                if a !== apps.last { blocks.append(.heading("")) }
            }
            rep.sections.append(ReportSection(id: "apps", title: L("アプリ", "Applications"), symbol: "app.badge", blocks: blocks, count: apps.count))
        }

        if !caps.isEmpty {
            rep.sections.append(ReportSection(id: "capabilities", title: L("権限 (Capabilities)", "Capabilities"), symbol: "hand.raised",
                blocks: [.table(TableData(columns: [L("権限", "Capability"), L("区分", "Class")], rows: caps))], count: caps.count))
        }

        if !families.isEmpty || !pkgDeps.isEmpty {
            var blocks = [Block]()
            if !families.isEmpty {
                blocks.append(.table(TableData(columns: [L("対象デバイス", "Device family"), L("最低バージョン", "Min version"), L("テスト済み", "Max tested")],
                    rows: families.map { [$0.attrs["Name"] ?? "", windowsBuild($0.attrs["MinVersion"]) ?? "", windowsBuild($0.attrs["MaxVersionTested"]) ?? ""] })))
            }
            if !pkgDeps.isEmpty {
                blocks.append(.heading(L("必要なパッケージ", "Package dependencies")))
                blocks.append(.table(TableData(columns: [L("名前", "Name"), L("最低バージョン", "Min version")], rows: pkgDeps.map { [$0.attrs["Name"] ?? "", $0.attrs["MinVersion"] ?? ""] })))
            }
            let langs = (man?.first("Resources")?.all("Resource") ?? []).compactMap { $0.attrs["Language"] }
            if !langs.isEmpty { blocks.append(.rows([Row(L("言語", "Languages"), langs.joined(separator: ", "))])) }
            rep.sections.append(ReportSection(id: "deps", title: L("動作条件", "Requirements"), symbol: "desktopcomputer", blocks: blocks))
        }

        // Main executable: a short look at the PE header.
        if let exe = apps.first?.attrs["Executable"], let e = find(pkg, exe), let d = pkg.read(e, max: opts.deep ? 1 << 30 : 200 << 20), let pe = PEFile(d) {
            var rows = [Row]()
            rows.add(L("ファイル", "File"), exe, mono: true)
            rows.add(L("マシン", "Machine"), PEFile.machines[pe.machine])
            rows.add(L("形式", "Format"), pe.is64 ? "PE32+" : "PE32")
            if pe.dir(14) != nil { rows.add(L("ランタイム", "Runtime"), ".NET") }
            rows.add(L("サイズ", "Size"), byteSize(d.count))
            let vs = Dictionary(pe.versionInfo(pe.resources()).strings, uniquingKeysWith: { a, _ in a })
            rows.add(L("ファイルバージョン", "File version"), vs["FileVersion"])
            rows.add(L("会社名", "Company"), vs["CompanyName"])
            rep.sections.append(ReportSection(id: "exe", title: L("実行ファイル", "Executable"), symbol: "cpu", blocks: [.rows(rows)]))
        }

        if let m = pkg.read("AppxManifest.xml", max: 2 << 20) {
            rep.sections.append(ReportSection(id: "manifest", title: "AppxManifest.xml", symbol: "doc.text", blocks: [.text(Reader.decode(m).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}").union(.whitespacesAndNewlines)))]))
        }
        rep.sections.append(IPA.largestFiles(isBundle ? zip : pkg, strip: "", deep: opts.deep))
        return rep
    }
}
