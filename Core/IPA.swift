import Foundation
import CoreGraphics

enum IPA {
    /// Directory holding Info.plist: "Payload/Foo.app/" for a proper ipa, but also "Foo.app/" (an app zipped
    /// without the Payload folder) and "Foo.app/Contents/" (a zipped macOS app).
    static func appDir(_ zip: Zip) -> String? {
        var best: String?
        for e in zip.entries where e.name.hasSuffix("/Info.plist") && !e.name.hasPrefix("__MACOSX/") {
            var dir = String(e.name.dropLast("Info.plist".count))
            let isMac = dir.hasSuffix(".app/Contents/")
            let bundle = isMac ? String(dir.dropLast("Contents/".count)) : dir
            guard bundle.hasSuffix(".app/") else { continue }
            // The outermost app only: no other ".app/" earlier in the path.
            let parent = bundle.dropLast(1).split(separator: "/").dropLast()
            if parent.contains(where: { $0.hasSuffix(".app") }) || parent.count > 2 { continue }
            if isMac { dir = bundle + "Contents/" }
            if dir.hasPrefix("Payload/") { return dir }
            if best == nil || dir.count < best!.count { best = dir }
        }
        return best
    }

    static func plist(_ zip: Zip, _ name: String) -> [String: Any]? {
        guard let d = zip.read(name, max: 8 << 20) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    static func iconData(_ zip: Zip, dir: String, info: [String: Any]) -> Data? {
        var names = [String]()
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any], let prim = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += (prim["CFBundleIconFiles"] as? [String]) ?? []
                if let n = prim["CFBundleIconName"] as? String { names.append(n) }
            }
        }
        names += (info["CFBundleIconFiles"] as? [String]) ?? []
        // macOS bundles: Contents/Resources/<CFBundleIconFile>.icns
        if dir.hasSuffix(".app/Contents/") {
            for n in [info["CFBundleIconFile"] as? String, "AppIcon"].compactMap({ $0 }) {
                let file = n.hasSuffix(".icns") ? n : n + ".icns"
                if let d = zip.read(dir + "Resources/" + file, max: 16 << 20), !d.isEmpty { return d }
            }
        }
        if names.isEmpty { names = ["AppIcon", "Icon"] }
        var best: Zip.Entry?
        for e in zip.entries where e.name.hasPrefix(dir) && e.name.hasSuffix(".png") {
            let file = e.name.dropFirst(dir.count)
            guard !file.contains("/"), names.contains(where: { file.hasPrefix($0) }) else { continue }
            if best == nil || e.size > best!.size { best = e }
        }
        return best.flatMap { zip.read($0, max: 8 << 20) }
    }

    static func icon(_ zip: Zip) -> CGImage? {
        guard let dir = appDir(zip), let info = plist(zip, dir + "Info.plist"),
              let d = iconData(zip, dir: dir, info: info) else { return nil }
        return appIcon(d, info: info)
    }

    /// The icon as the home screen shows it: iOS icon files are plain squares, the system rounds them.
    static func appIcon(_ data: Data, info: [String: Any]) -> CGImage? {
        guard let src = ImageKit.decode(data) else { return nil }
        let platform = (info["CFBundleSupportedPlatforms"] as? [String])?.first ?? "iPhoneOS"
        guard platform == "iPhoneOS" || platform == "iPhoneSimulator" else { return src }
        return ImageKit.squircle(src)
    }

    static func report(url: URL, zip: Zip, dir: String, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .ipa, path: url.path, title: url.lastPathComponent)
        let info = plist(zip, dir + "Info.plist") ?? [:]
        let isMac = dir.hasSuffix(".app/Contents/")
        let isFolder = zip.containerLabel != nil
        let proper = dir.hasPrefix("Payload/")
        let bundleName = dir.split(separator: "/").last { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) } ?? ""
        rep.title = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleName
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let version: String? = short.map { $0 + (build != nil && build != $0 ? " (\(build!))" : "") } ?? build
        let platform: String = {
            let p = (info["CFBundleSupportedPlatforms"] as? [String])?.first ?? (isMac ? "MacOSX" : "iPhoneOS")
            return ["iPhoneOS": "iOS", "AppleTVOS": "tvOS", "WatchOS": "watchOS", "XROS": "visionOS", "MacOSX": "macOS"][p] ?? p
        }()
        let container = isFolder ? zip.containerLabel! : proper ? "ipa" : url.pathExtension.lowercased() == "ipa" ? L("ipa、Payload なし", "ipa without Payload") : "zip"
        rep.subtitle = L("\(platform) アプリ (\(container))", "\(platform) app (\(container))") + (version.map { " · " + L("バージョン ", "Version ") + $0 } ?? "")
        if let d = iconData(zip, dir: dir, info: info) { rep.icon = appIcon(d, info: info) }

        // Main executable
        var slices = [MachOSlice]()
        var execData: Data?
        if let exe = info["CFBundleExecutable"] as? String, let e = zip.entry(dir + (isMac ? "MacOS/" : "") + exe) {
            if let d = zip.read(e, max: opts.deep ? 2 << 30 : 400 << 20), MachO.isMachO(Reader(d)) {
                execData = d
                slices = MachO.parse(d, opts: opts)
            }
        }
        let slice = MachO.preferred(slices)
        let sig = slice?.codeSig
        let prof = zip.read(dir + "embedded.mobileprovision", max: 4 << 20).flatMap { BundleAnalyzer.profile($0) }

        // Distribution method
        let getTaskAllow = (sig?.entitlements?["get-task-allow"] as? Bool) == true
        var dist: String
        var distTone: Tone = .neutral
        if let p = prof?.dict {
            if (p["ProvisionsAllDevices"] as? Bool) == true { dist = L("エンタープライズ配布 (In-House)", "Enterprise (In-House)") }
            else if p["ProvisionedDevices"] != nil { dist = getTaskAllow ? L("開発用 (Development)", "Development") : "Ad Hoc" }
            else { dist = L("App Store / TestFlight 提出用", "App Store / TestFlight") }
            if let e = p["ExpirationDate"] as? Date, e < Date() { distTone = .bad }
        } else if isMac, let leaf = sig?.cms?.names.first {
            // A Mac app: the certificate tells where it comes from (no provisioning profile needed).
            if leaf.hasPrefix("Developer ID Application") { dist = "Developer ID" }
            else if leaf.hasPrefix("Apple Mac OS Application Signing") || leaf.hasPrefix("3rd Party Mac Developer") { dist = "Mac App Store" }
            else if leaf.hasSuffix("Software Signing") { dist = L("Apple のシステムソフトウェア", "Apple system software") }
            else if leaf.hasPrefix("Apple Development") || leaf.hasPrefix("Mac Developer") { dist = L("開発用の署名", "Development signing") }
            else { dist = L("署名済み", "Signed") }
        } else if slice?.encrypted == true {
            dist = L("App Store（FairPlay 暗号化）", "App Store (FairPlay encrypted)")
        } else if sig == nil {
            dist = L("署名なし", "Unsigned"); distTone = .warn
        } else if sig?.hasCMS == false {
            dist = L("アドホック署名（再署名が必要）", "Ad hoc signed (needs re-signing)"); distTone = .warn
        } else {
            dist = L("App Store（復号済み）または再署名", "App Store (decrypted) or re-signed")
        }
        rep.badges.append(Badge(text: dist, tone: distTone == .neutral ? .info : distTone))
        if slice?.encrypted == true { rep.badges.append(Badge(text: L("暗号化", "Encrypted"), tone: .warn)) }
        if getTaskAllow { rep.badges.append(Badge(text: L("デバッグ可能", "Debuggable"), tone: .warn)) }
        if let e = prof?.dict["ExpirationDate"] as? Date, e < Date() { rep.badges.append(Badge(text: L("プロファイル期限切れ", "Profile expired"), tone: .bad)) }

        let families = ((info["UIDeviceFamily"] as? [Int]) ?? []).compactMap { [1: "iPhone", 2: "iPad", 3: "Apple TV", 4: "Apple Watch", 6: "Mac", 7: "Vision"][$0] }
        var tech = [String]()
        let fwNames = Set(zip.entries.compactMap { e -> String? in
            guard e.name.hasPrefix(dir + "Frameworks/") else { return nil }
            return e.name.dropFirst((dir + "Frameworks/").count).split(separator: "/").first.map(String.init)
        })
        if fwNames.contains("Flutter.framework") { tech.append("Flutter") }
        if fwNames.contains("UnityFramework.framework") { tech.append("Unity") }
        if fwNames.contains("hermes.framework") || fwNames.contains("React.framework") || zip.entry(dir + "main.jsbundle") != nil { tech.append("React Native") }
        if fwNames.contains(where: { $0.hasPrefix("Xamarin") || $0.hasPrefix("Mono") }) { tech.append("Xamarin / .NET") }
        if zip.entry(dir + "www/cordova.js") != nil || fwNames.contains("Cordova.framework") { tech.append("Cordova") }
        if fwNames.contains("Capacitor.framework") { tech.append("Capacitor") }
        if let s = slice {
            let libs = s.dylibs.map { ($0.name as NSString).lastPathComponent }
            if libs.contains("SwiftUI") { tech.append("SwiftUI") }
            if libs.contains("UIKit") { tech.append("UIKit") }
            for l in s.languages where !tech.contains(l) { tech.append(l) }
        }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), isFolder ? L("\(platform) アプリ（.app バンドル）", "\(platform) app (.app bundle)")
                : proper ? L("\(platform) アプリのパッケージ (ipa)", "\(platform) app package (ipa)") : L("zip に入った \(platform) アプリ", "\(platform) app in a zip archive"))
        if !proper, url.pathExtension.lowercased() == "ipa" {
            sum.add(L("構造", "Layout"), L("Payload フォルダーがありません（.app を直接 zip にしたもの）。このままでは通常の方法でインストールできません。", "No Payload folder (the .app was zipped directly). It will not install as-is."), tone: .warn)
            rep.badges.append(Badge(text: L("Payload なし", "No Payload folder"), tone: .warn))
        }
        sum.add(L("バージョン", "Version"), version)
        sum.add(L("識別子", "Identifier"), info["CFBundleIdentifier"] as? String, mono: true)
        sum.add(L("配布形態", "Distribution"), dist, tone: distTone)
        sum.add(L("署名者", "Signed by"), sig.map { $0.signerText })
        sum.add("Team ID", sig?.teamID, mono: true)
        sum.add(L("対応 OS", "Requires"), ((info["MinimumOSVersion"] as? String) ?? (info["LSMinimumSystemVersion"] as? String)).map { "\(platform) \($0) " + L("以降", "or later") })
        sum.add(L("対応デバイス", "Devices"), families.joined(separator: ", "))
        sum.add(L("アーキテクチャ", "Architectures"), slices.isEmpty ? nil : MachO.archSummary(slices))
        sum.add(L("技術", "Built with"), tech.joined(separator: ", "))
        sum.add(L("サイズ", "Size"), isFolder ? byteSize(zip.totalUncompressed) + L("（\(zip.entries.count) ファイル）", " (\(zip.entries.count) files)")
                : byteSize(fileSize) + L("（展開後 ", " (unpacked ") + byteSize(zip.totalUncompressed) + L("、\(zip.entries.count) 項目）", ", \(zip.entries.count) items)"))
        if let meta = plist(zip, "iTunesMetadata.plist") {
            sum.add(L("App Store での名前", "App Store name"), meta["itemName"] as? String)
            sum.add("App Store ID", (meta["itemId"] as? NSNumber)?.stringValue, mono: true)
            sum.add(L("販売元", "Seller"), meta["artistName"] as? String)
        }
        rep.summary = sum

        if let sig {
            rep.sections.append(ReportSection(id: "signature", title: L("コード署名", "Code Signature"), symbol: "checkmark.seal",
                blocks: [.rows(signatureRows(sig)), .note(L("署名の内容を表示しています。ハッシュの検証は行っていません。", "Shows what the signature says; hashes are not verified."))]))
            if let e = sig.entitlements, !e.isEmpty { rep.sections.append(entitlementsSection(e)) }
        }
        if let p = prof { rep.sections.append(p.section) }
        if let x = AppExtensions.section(AppExtensions.find(in: zip, appDir: dir)) {
            rep.sections.append(x.section)
            rep.summary.add(L("機能拡張", "Extensions"), x.summary)
        }
        if let pv = Privacy.section(info: info, entitlements: sig?.entitlements, manifests: Privacy.manifests(in: zip, appDir: dir), frameworks: Array(fwNames)) {
            rep.sections.append(pv.section)
            rep.badges.append(contentsOf: pv.badges)
            rep.summary.add(L("プライバシー", "Privacy"), pv.summary)
        }
        if let s = BundleAnalyzer.infoPlistSection(info) { rep.sections.append(s) }

        // Components: frameworks, dylibs, extensions, watch app, app clips.
        var comps = [[String]]()
        var seen = Set<String>()
        for e in zip.entries where e.name.hasPrefix(dir) {
            let rel = String(e.name.dropFirst(dir.count))
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count >= 2, ["Frameworks", "PlugIns", "Extensions", "Watch", "AppClips", "SystemExtensions"].contains(parts[0]) else { continue }
            let item = parts[0] + "/" + parts[1]
            guard !seen.contains(item) else { continue }
            let ext = (parts[1] as NSString).pathExtension.lowercased()
            if BundleAnalyzer.bundleExts.contains(ext) {
                seen.insert(item)
                let pi = plist(zip, dir + item + "/Info.plist") ?? [:]
                var kind = BundleAnalyzer.kindName(URL(fileURLWithPath: parts[1]), info: pi)
                if let x = pi["NSExtension"] as? [String: Any], let pt = x["NSExtensionPointIdentifier"] as? String {
                    kind += " (\(pt.replacingOccurrences(of: "com.apple.", with: "")))"
                }
                comps.append([item, kind, (pi["CFBundleShortVersionString"] as? String) ?? "", (pi["CFBundleIdentifier"] as? String) ?? ""])
            } else if ext == "dylib", parts.count == 2 {
                seen.insert(item)
                comps.append([item, L("ダイナミックライブラリ", "Dynamic library"), "", byteSize(e.size)])
            }
        }
        if !comps.isEmpty {
            rep.sections.append(ReportSection(id: "components", title: L("コンポーネント", "Components"), symbol: "shippingbox",
                blocks: [.table(TableData(columns: [L("場所", "Path"), L("種類", "Kind"), L("バージョン", "Version"), L("識別子 / サイズ", "Identifier / Size")], rows: comps))], count: comps.count))
        }

        if let d = execData {
            rep.sections.append(contentsOf: MachO.sections(slices, data: d, opts: opts, includeSignature: false))
        }
        rep.sections.append(largestFiles(zip, strip: dir, deep: opts.deep))
        return rep
    }

    static func largestFiles(_ zip: Zip, strip: String, deep: Bool) -> ReportSection {
        let files = zip.entries.filter { !$0.name.hasSuffix("/") }.sorted { $0.size > $1.size }
        let rows = files.prefix(deep ? 5000 : 200).map {
            [$0.name.hasPrefix(strip) ? String($0.name.dropFirst(strip.count)) : $0.name, byteSize($0.size), byteSize($0.compSize)]
        }
        return ReportSection(id: "files", title: L("ファイル（大きい順）", "Files (largest first)"), symbol: "doc.on.doc",
            blocks: [.table(TableData(columns: [L("パス", "Path"), L("サイズ", "Size"), L("圧縮後", "Compressed"), ], rows: rows, total: files.count))], count: files.count)
    }
}
