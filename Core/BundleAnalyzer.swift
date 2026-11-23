import Foundation
import Security

enum BundleAnalyzer {
    static let bundleExts: Set<String> = ["app", "framework", "appex", "bundle", "plugin", "kext", "xpc", "dext", "systemextension",
                                          "qlgenerator", "mdimporter", "saver", "prefpane", "component", "vst", "vst3", "driver", "action", "wdgt"]

    static func isBundle(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        if bundleExts.contains(url.pathExtension.lowercased()) { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Info.plist").path)
    }

    static func kindName(_ url: URL, info: [String: Any]) -> String {
        switch url.pathExtension.lowercased() {
        case "app":
            if let p = info["CFBundleSupportedPlatforms"] as? [String], let f = p.first, f != "MacOSX" {
                return L("アプリケーション (\(f))", "Application (\(f))")
            }
            return L("アプリケーション", "Application")
        case "framework": return L("フレームワーク", "Framework")
        case "appex": return L("機能拡張", "App Extension")
        case "xpc": return L("XPC サービス", "XPC Service")
        case "kext": return L("カーネル拡張", "Kernel Extension")
        case "dext", "systemextension": return L("システム機能拡張", "System Extension")
        case "qlgenerator": return L("Quick Look プラグイン（旧式）", "Quick Look generator (legacy)")
        case "mdimporter": return L("Spotlight インポーター", "Spotlight importer")
        case "saver": return L("スクリーンセーバー", "Screen saver")
        case "prefpane": return L("環境設定パネル", "Preference pane")
        case "component", "vst", "vst3": return L("オーディオプラグイン", "Audio plug-in")
        default: return L("バンドル", "Bundle")
        }
    }

    // MARK: Security.framework

    struct SecInfo {
        var signed = false
        var status: OSStatus = 0
        var validity: OSStatus?
        var validityNote: String?
        var identifier: String?
        var teamID: String?
        var certNames: [String] = []
        var flags: UInt32 = 0
        var entitlements: [String: Any]?
        var time: Date?
        var timestamp: Date?
        var cdhash: String?
        var apple = false, appStore = false, developerID = false
        var notarized: Bool?
        var designated: String?
    }

    #if os(macOS)
    static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
    }

    static func secInfo(_ url: URL, opts: AnalyzeOptions) -> SecInfo {
        var out = SecInfo()
        var codeRef: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef) == errSecSuccess, let code = codeRef else { return out }
        var cf: CFDictionary?
        out.status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &cf)
        guard let d = cf as? [String: Any] else { return out }
        out.identifier = d[kSecCodeInfoIdentifier as String] as? String
        out.signed = out.identifier != nil
        guard out.signed else { return out }
        out.teamID = d[kSecCodeInfoTeamIdentifier as String] as? String
        out.certNames = ((d[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []).map(certName)
        out.flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        out.entitlements = d[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        out.time = d[kSecCodeInfoTime as String] as? Date
        out.timestamp = d[kSecCodeInfoTimestamp as String] as? Date
        if let u = d[kSecCodeInfoUnique as String] as? Data { out.cdhash = hexString(u) }
        if let r = d[kSecCodeInfoDesignatedRequirement as String] {
            var text: CFString?
            SecRequirementCopyString(r as! SecRequirement, [], &text)
            out.designated = text as String?
        }

        // Validity. Resources are only hashed in deep mode, on a side thread with a deadline.
        if opts.deep {
            let sem = DispatchSemaphore(value: 0)
            let box = ResultBox()
            DispatchQueue.global(qos: .userInitiated).async {
                box.value = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil)
                sem.signal()
            }
            if sem.wait(timeout: .now() + 25) == .success {
                out.validity = box.value
                out.validityNote = L("リソースと内包コードを含めて検証", "Verified including resources and nested code")
            } else {
                out.validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
                out.validityNote = L("実行ファイルのみ検証（全体の検証は 25 秒で打ち切り）", "Executable only (full check timed out after 25 s)")
            }
        } else {
            out.validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
            out.validityNote = L("実行ファイルのみ検証", "Executable only")
        }

        out.apple = satisfies(code, "anchor apple")
        out.appStore = !out.apple && satisfies(code, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")
        out.developerID = satisfies(code, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
        if out.developerID { out.notarized = satisfies(code, "notarized") }
        return out
    }

    #endif

    final class ResultBox: @unchecked Sendable { var value: OSStatus = 0 }

    static func secErrorText(_ st: OSStatus) -> String {
        (SecCopyErrorMessageString(st, nil) as String?) ?? "OSStatus \(st)"
    }

    // MARK: Components

    struct Component {
        var path: String
        var kind: String
        var arch: String
        var version: String
        var identifier: String
        var team: String
        var traits: String
    }

    static let codeDirs = ["MacOS", "Frameworks", "PlugIns", "XPCServices", "Helpers", "Library/LoginItems", "Library/SystemExtensions",
                           "Library/LaunchServices", "Library/Spotlight", "Library/QuickLook", "Extensions", "SharedSupport", "Resources"]

    static func components(root: URL, mainExec: URL?, opts: AnalyzeOptions, deadline: Date) -> (items: [Component], truncated: Bool) {
        let fm = FileManager.default
        var items = [Component]()
        var truncated = false
        let maxItems = opts.deep ? 3000 : 400
        var light = opts
        light.light = true
        light.deep = false
        let rootPath = root.resolvingSymlinksInPath().path

        func rel(_ u: URL) -> String {
            var p = u.path
            if p.hasPrefix(rootPath + "/") { p = String(p.dropFirst(rootPath.count + 1)) }
            if p.hasPrefix("Contents/") { p = String(p.dropFirst(9)) }
            return p
        }
        func traits(_ sig: CodeSignature?) -> String {
            guard let sig else { return L("署名なし", "unsigned") }
            var t = [String]()
            if !sig.hasCMS { t.append(L("アドホック", "ad hoc")) }
            if sig.sandboxed { t.append("Sandbox") }
            if sig.hardenedRuntime { t.append("Hardened") }
            return t.joined(separator: ", ")
        }
        func machInfo(_ u: URL) -> (arch: String, sig: CodeSignature?, type: String)? {
            guard let d = try? Data(contentsOf: u, options: .alwaysMapped), d.count > 28, MachO.isMachO(Reader(d)) else { return nil }
            let sl = MachO.parse(d, opts: light)
            guard let s = MachO.preferred(sl) else { return nil }
            return (sl.map { $0.arch }.joined(separator: ", "), s.codeSig, s.fileTypeName)
        }
        func contentsDir(_ b: URL) -> URL {
            let c = b.appendingPathComponent("Contents")
            if fm.fileExists(atPath: c.path) { return c }
            let v = b.appendingPathComponent("Versions/Current")
            if fm.fileExists(atPath: v.path) { return v }
            return b
        }
        func visitBundle(_ b: URL, depth: Int) {
            guard items.count < maxItems, Date() < deadline else { truncated = true; return }
            let info = Bundle(url: b)?.infoDictionary ?? [:]
            var c = Component(path: rel(b), kind: kindName(b, info: info), arch: "", version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "",
                              identifier: (info["CFBundleIdentifier"] as? String) ?? "", team: "", traits: "")
            if let ex = Bundle(url: b)?.executableURL, let m = machInfo(ex) {
                c.arch = m.arch; c.team = m.sig?.teamID ?? ""; c.traits = traits(m.sig)
            }
            if let ext = info["NSExtension"] as? [String: Any], let pt = ext["NSExtensionPointIdentifier"] as? String {
                c.kind += " (\(pt.replacingOccurrences(of: "com.apple.", with: "")))"
            } else if let ex = info["EXAppExtensionAttributes"] as? [String: Any], let pt = ex["EXExtensionPointIdentifier"] as? String {
                c.kind += " (\(pt))"
            }
            items.append(c)
            if depth < 4 { scan(contentsDir(b), depth: depth + 1, skip: Bundle(url: b)?.executableURL) }
        }
        func scan(_ contents: URL, depth: Int, skip: URL?) {
            let skipPath = skip?.resolvingSymlinksInPath().path
            var dirs = codeDirs.map { contents.appendingPathComponent($0) }
            if contents.lastPathComponent != "Contents" { dirs.append(contents) }  // flat (iOS-style / framework version) bundles
            for dir in dirs {
                guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: []) else { continue }
                let shallowOnly = dir.lastPathComponent == "Resources" || dir.lastPathComponent == "SharedSupport" || dir == contents
                for u in list.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard items.count < maxItems, Date() < deadline else { truncated = true; return }
                    let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                    if v?.isSymbolicLink == true { continue }
                    let ext = u.pathExtension.lowercased()
                    if v?.isDirectory == true {
                        if bundleExts.contains(ext) { visitBundle(u, depth: depth) }
                        else if !shallowOnly, depth < 4, ext.isEmpty || ext == "lproj" { if ext.isEmpty { scanLoose(u, depth: depth) } }
                        continue
                    }
                    guard v?.isRegularFile == true else { continue }
                    if u.resolvingSymlinksInPath().path == skipPath { continue }
                    if shallowOnly, !ext.isEmpty, ext != "dylib", ext != "so" { continue }
                    if !["", "dylib", "so", "node", "bundle"].contains(ext) { continue }
                    if let m = machInfo(u) {
                        items.append(Component(path: rel(u), kind: m.type, arch: m.arch, version: "", identifier: m.sig?.identifier ?? "", team: m.sig?.teamID ?? "", traits: traits(m.sig)))
                    }
                }
            }
        }
        /// Plain sub-directory of a code directory (e.g. Frameworks/lib/…): one level of loose binaries.
        func scanLoose(_ dir: URL, depth: Int) {
            guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
            for u in list.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard items.count < maxItems, Date() < deadline else { truncated = true; return }
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { continue }
                let ext = u.pathExtension.lowercased()
                if v?.isDirectory == true {
                    if bundleExts.contains(ext) { visitBundle(u, depth: depth) }
                    continue
                }
                if ["", "dylib", "so", "node"].contains(ext), let m = machInfo(u) {
                    items.append(Component(path: rel(u), kind: m.type, arch: m.arch, version: "", identifier: m.sig?.identifier ?? "", team: m.sig?.teamID ?? "", traits: traits(m.sig)))
                }
            }
        }
        let rootResolved = URL(fileURLWithPath: rootPath)
        scan(contentsDir(rootResolved), depth: 0, skip: mainExec)
        return (items, truncated)
    }

    // MARK: Misc

    static func quarantine(_ url: URL) -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        let n = getxattr(url.path, "com.apple.quarantine", &buf, buf.count - 1, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        let parts = String(cString: buf).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var s = [String]()
        if parts.count > 2, !parts[2].isEmpty { s.append(parts[2].replacingOccurrences(of: "\\x20", with: " ")) }
        if parts.count > 1, let t = UInt64(parts[1], radix: 16), t > 0 { s.append(dateString(Date(timeIntervalSince1970: TimeInterval(t)))) }
        if let f = parts.first.flatMap({ UInt32($0, radix: 16) }) {
            s.append(f & 0x40 != 0 ? L("初回起動の確認済み", "first launch approved") : L("初回起動は未確認", "not yet approved"))
        }
        return s.isEmpty ? L("あり", "Present") : s.joined(separator: L("、", ", "))
    }

    static func technologies(contents: URL, slice: MachOSlice?) -> [String] {
        let fm = FileManager.default
        var t = [String]()
        let fw = Set(((try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path)) ?? []))
        func ver(_ name: String) -> String {
            let b = Bundle(url: contents.appendingPathComponent("Frameworks/\(name)"))
            return (b?.infoDictionary?["CFBundleShortVersionString"] as? String).map { " \($0)" } ?? ""
        }
        if fw.contains("Electron Framework.framework") { t.append("Electron" + ver("Electron Framework.framework")) }
        if fw.contains("Chromium Embedded Framework.framework") { t.append("CEF" + ver("Chromium Embedded Framework.framework")) }
        if fw.contains("FlutterMacOS.framework") || fw.contains("Flutter.framework") { t.append("Flutter") }
        if fw.contains(where: { $0.hasPrefix("QtCore") }) { t.append("Qt" + ver("QtCore.framework")) }
        if fw.contains("Sparkle.framework") { t.append("Sparkle" + ver("Sparkle.framework")) }
        if fw.contains("Squirrel.framework") { t.append("Squirrel") }
        if fw.contains("UnityPlayer.dylib") { t.append("Unity") }
        if fw.contains(where: { $0.hasPrefix("libmono") }) { t.append("Mono") }
        if fw.contains(where: { $0.hasPrefix("libcoreclr") }) || fm.fileExists(atPath: contents.appendingPathComponent("MonoBundle").path) { t.append(".NET") }
        if fm.fileExists(atPath: contents.appendingPathComponent("Resources/app.asar").path), !t.contains(where: { $0.hasPrefix("Electron") }) { t.append("Electron") }
        if fm.fileExists(atPath: contents.appendingPathComponent("PlugIns/jre").path) || fm.fileExists(atPath: contents.appendingPathComponent("runtime/Contents/Home").path) || fm.fileExists(atPath: contents.appendingPathComponent("Java").path) { t.append("Java") }
        if let s = slice {
            let libs = s.dylibs.map { ($0.name as NSString).lastPathComponent }
            if libs.contains("SwiftUI") { t.append("SwiftUI") }
            if s.platform?.contains("Catalyst") == true { t.append("Mac Catalyst") }
            else if libs.contains("AppKit") { t.append("AppKit") }
            else if libs.contains("UIKit") { t.append("UIKit") }
            if libs.contains("WebKit") { t.append("WebKit") }
            for l in s.languages where !t.contains(l) { t.append(l) }
        }
        return t
    }

    static func infoPlistSection(_ info: [String: Any], localized: [String: Any] = [:]) -> ReportSection? {
        guard !info.isEmpty else { return nil }
        var blocks = [Block]()
        var rows = [Row]()
        rows.add(L("実行ファイル", "Executable"), info["CFBundleExecutable"] as? String, mono: true)
        rows.add(L("パッケージ種別", "Package type"), info["CFBundlePackageType"] as? String, mono: true)
        rows.add("SDK", info["DTSDKName"] as? String)
        if let x = info["DTXcode"] as? String { rows.add("Xcode", x + ((info["DTXcodeBuild"] as? String).map { " (\($0))" } ?? "")) }
        rows.add(L("ビルドした OS", "Built on"), info["BuildMachineOSBuild"] as? String)
        if (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1" { rows.add(L("表示形態", "Presentation"), L("Dock に出ない常駐アプリ (LSUIElement)", "Agent app (LSUIElement)")) }
        if (info["LSBackgroundOnly"] as? Bool) == true { rows.add(L("表示形態", "Presentation"), L("バックグラウンド専用", "Background only")) }
        rows.add(L("自動アップデート (Sparkle)", "Update feed (Sparkle)"), info["SUFeedURL"] as? String, mono: true)
        if let ext = info["NSExtension"] as? [String: Any] {
            rows.add(L("機能拡張の種類", "Extension point"), ext["NSExtensionPointIdentifier"] as? String, mono: true)
        }
        if let ats = info["NSAppTransportSecurity"] as? [String: Any], (ats["NSAllowsArbitraryLoads"] as? Bool) == true {
            rows.add("App Transport Security", L("任意の HTTP 通信を許可", "Arbitrary loads allowed"), tone: .warn)
        }
        if !rows.isEmpty { blocks.append(.rows(rows)) }

        if let urls = info["CFBundleURLTypes"] as? [[String: Any]] {
            let schemes = urls.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
            if !schemes.isEmpty { blocks.append(.rows([Row(L("URL スキーム", "URL schemes"), schemes.map { $0 + "://" }.joined(separator: ", "), mono: true)])) }
        }
        if let docs = info["CFBundleDocumentTypes"] as? [[String: Any]], !docs.isEmpty {
            blocks.append(.heading(L("開けるファイルの種類", "Document types")))
            blocks.append(.table(TableData(columns: [L("名前", "Name"), L("役割", "Role"), L("種類 / 拡張子", "Types / Extensions")], rows: docs.map {
                let types = (($0["LSItemContentTypes"] as? [String]) ?? []) + (($0["CFBundleTypeExtensions"] as? [String]) ?? []).map { "." + $0 }
                return [($0["CFBundleTypeName"] as? String) ?? "", ($0["CFBundleTypeRole"] as? String) ?? "", types.joined(separator: ", ")]
            })))
        }
        blocks.append(.heading(L("すべてのキー", "All keys")))
        blocks.append(.table(TableData(columns: [L("キー", "Key"), L("値", "Value")], rows: info.keys.sorted().map { [$0, describePlistValue(info[$0]!)] })))
        return ReportSection(id: "info", title: "Info.plist", symbol: "doc.text", blocks: blocks, count: info.count)
    }

    /// Decoded provisioning profile: its report section plus the facts other code needs.
    static func profile(_ blob: Data) -> (section: ReportSection, dict: [String: Any])? {
        guard let pl = decodeCMSContent(blob),
              let d = (try? PropertyListSerialization.propertyList(from: pl, format: nil)) as? [String: Any] else { return nil }
        var rows = [Row]()
        rows.add(L("名前", "Name"), d["Name"] as? String)
        rows.add(L("チーム", "Team"), ((d["TeamName"] as? String) ?? "") + ((d["TeamIdentifier"] as? [String])?.first.map { " (\($0))" } ?? ""))
        rows.add("App ID", d["AppIDName"] as? String)
        rows.add("UUID", d["UUID"] as? String, mono: true)
        if let c = d["CreationDate"] as? Date { rows.add(L("作成日", "Created"), dateString(c)) }
        if let e = d["ExpirationDate"] as? Date {
            rows.add(L("有効期限", "Expires"), dateString(e) + (e < Date() ? L("（期限切れ）", " (expired)") : ""), tone: e < Date() ? .bad : .neutral)
        }
        if let dev = d["ProvisionedDevices"] as? [String] { rows.add(L("登録デバイス", "Devices"), "\(dev.count)" + L(" 台", "")) }
        if (d["ProvisionsAllDevices"] as? Bool) == true { rows.add(L("登録デバイス", "Devices"), L("すべて（エンタープライズ）", "All (enterprise)")) }
        rows.add(L("プラットフォーム", "Platforms"), (d["Platform"] as? [String])?.joined(separator: ", "))
        return (ReportSection(id: "profile", title: L("プロビジョニングプロファイル", "Provisioning Profile"), symbol: "person.text.rectangle", blocks: [.rows(rows)]), d)
    }

    // MARK: Report

    #if os(macOS)
    static func report(url: URL, opts: AnalyzeOptions) -> Report {
        let start = Date()
        var rep = Report(kind: .bundle, path: url.path)
        let fm = FileManager.default
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let localized = bundle?.localizedInfoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        rep.title = name
        let kind = kindName(url, info: info)
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        let version: String? = short.map { $0 + (build != nil && build != $0 ? " (\(build!))" : "") } ?? build
        rep.subtitle = kind + (version.map { " · " + L("バージョン ", "Version ") + $0 } ?? "")
        rep.icon = ImageKit.systemIcon(url)

        let contents: URL = {
            let c = url.appendingPathComponent("Contents")
            if fm.fileExists(atPath: c.path) { return c }
            let v = url.appendingPathComponent("Versions/Current")
            return fm.fileExists(atPath: v.path) ? v : url
        }()

        // Main executable
        let execURL = bundle?.executableURL
        var slices = [MachOSlice]()
        var execData: Data?
        if let e = execURL, let d = try? Data(contentsOf: e, options: .alwaysMapped), MachO.isMachO(Reader(d)) {
            execData = d
            slices = MachO.parse(d, opts: opts)
        }
        let slice = MachO.preferred(slices)

        // Signature
        let sec = secInfo(url, opts: opts)
        let own = slice?.codeSig
        let signed = sec.signed || own != nil
        let certNames = sec.certNames.isEmpty ? (own?.cms?.names ?? []) : sec.certNames
        let flags = sec.signed ? sec.flags : (own?.flags ?? 0)
        let ents = sec.entitlements ?? own?.entitlements
        let sandboxed = (ents?["com.apple.security.app-sandbox"] as? Bool) == true
        let hardened = flags & 0x10000 != 0
        let adhoc = signed && certNames.isEmpty
        let leaf = certNames.first ?? ""
        let stapled = fm.fileExists(atPath: contents.appendingPathComponent("CodeResources").path)

        var origin: String
        var originTone: Tone = .neutral
        if !signed {
            origin = L("署名なし", "Unsigned"); originTone = .bad
        } else if let v = sec.validity, v != errSecSuccess, sec.signed {
            origin = L("署名が無効です: ", "Invalid signature: ") + secErrorText(v); originTone = .bad
        } else if sec.apple {
            origin = L("Apple のシステムソフトウェア", "Apple system software"); originTone = .good
        } else if sec.appStore {
            origin = "Mac App Store"; originTone = .good
        } else if sec.developerID {
            if sec.notarized == true { origin = L("公証済みの Developer ID", "Notarized Developer ID"); originTone = .good }
            else if stapled { origin = L("Developer ID（公証チケット添付あり）", "Developer ID (stapled ticket present)"); originTone = .good }
            else { origin = L("Developer ID（公証は確認できません）", "Developer ID (notarization not confirmed)"); originTone = .warn }
        } else if adhoc {
            origin = own?.linkerSigned == true ? L("アドホック署名（リンカーによる自動署名）", "Ad hoc (linker-signed)") : L("アドホック署名", "Ad hoc signed"); originTone = .warn
        } else if leaf.hasPrefix("Apple Development") || leaf.hasPrefix("Mac Developer") || leaf.hasPrefix("iPhone Developer") {
            origin = L("開発用の署名（配布用ではありません）", "Development signing (not for distribution)"); originTone = .warn
        } else if leaf.hasPrefix("Apple Distribution") || leaf.hasPrefix("3rd Party Mac Developer") || leaf.hasPrefix("iPhone Distribution") {
            origin = L("App Store 提出用の署名", "App Store distribution signing")
        } else {
            origin = L("署名済み（Apple 発行ではない証明書）", "Signed (non-Apple certificate)"); originTone = .warn
        }

        rep.badges.append(Badge(text: origin.components(separatedBy: ": ").first ?? origin, tone: originTone))
        if signed {
            rep.badges.append(Badge(text: sandboxed ? "App Sandbox" : L("サンドボックスなし", "Not sandboxed"), tone: sandboxed ? .good : .neutral))
            rep.badges.append(Badge(text: hardened ? "Hardened Runtime" : L("Hardened Runtime なし", "No Hardened Runtime"), tone: hardened ? .good : .neutral))
        }

        let tech = technologies(contents: contents, slice: slice)
        let minOS = (info["LSMinimumSystemVersion"] as? String) ?? (info["MinimumOSVersion"] as? String) ?? slice?.minOS
        let platformName: String = {
            if let p = info["CFBundleSupportedPlatforms"] as? [String], let f = p.first {
                return ["MacOSX": "macOS", "iPhoneOS": "iOS", "iPhoneSimulator": "iOS Simulator", "AppleTVOS": "tvOS", "WatchOS": "watchOS", "XROS": "visionOS"][f] ?? f
            }
            return slice?.platform ?? "macOS"
        }()

        var sum = [Row]()
        sum.add(L("種類", "Kind"), kind)
        sum.add(L("バージョン", "Version"), version)
        sum.add(L("識別子", "Identifier"), info["CFBundleIdentifier"] as? String, mono: true)
        sum.add(L("入手元の判定", "Origin"), origin, tone: originTone)
        sum.add(L("署名者", "Signed by"), signed ? (certNames.first ?? L("（証明書なし）", "(no certificate)")) : nil)
        sum.add("Team ID", sec.teamID ?? own?.teamID, mono: true)
        sum.add(L("アーキテクチャ", "Architectures"), slices.isEmpty ? nil : MachO.archSummary(slices))
        sum.add(L("対応 OS", "Requires"), minOS.map { "\(platformName) \($0) " + L("以降", "or later") })
        sum.add(L("技術", "Built with"), tech.joined(separator: ", "))
        sum.add(L("カテゴリ", "Category"), (info["LSApplicationCategoryType"] as? String).map { $0.replacingOccurrences(of: "public.app-category.", with: "") })
        sum.add(L("著作権", "Copyright"), info["NSHumanReadableCopyright"] as? String)
        sum.add(L("ダウンロード元", "Quarantine"), quarantine(url))
        rep.summary = sum

        // Signature section
        var srows = [Row]()
        srows.add(L("判定", "Assessment"), origin, tone: originTone)
        if let v = sec.validity {
            srows.add(L("署名の検証", "Validity"), (v == errSecSuccess ? L("有効", "Valid") : secErrorText(v)) + (sec.validityNote.map { "（\($0)）" } ?? ""), tone: v == errSecSuccess ? .good : .bad)
        }
        if signed {
            srows.add(L("署名者", "Signed by"), certNames.first ?? L("なし（アドホック）", "None (ad hoc)"))
            if certNames.count > 1 { srows.add(L("証明書チェーン", "Certificate chain"), certNames.joined(separator: "\n← ")) }
            srows.add(L("識別子", "Identifier"), sec.identifier ?? own?.identifier, mono: true)
            srows.add("Team ID", sec.teamID ?? own?.teamID, mono: true)
            if let t = sec.timestamp ?? own?.cms?.timestamp { srows.add(L("署名日時（タイムスタンプ）", "Signed (timestamp)"), dateString(t)) }
            else if let t = sec.time ?? own?.cms?.signingTime { srows.add(L("署名日時", "Signed"), dateString(t)) }
            if sec.developerID {
                srows.add(L("公証", "Notarization"), sec.notarized == true ? L("公証済み", "Notarized") : L("確認できません", "Not confirmed"), tone: sec.notarized == true ? .good : .warn)
                srows.add(L("公証チケットの添付", "Stapled ticket"), stapled ? L("あり", "Present") : L("なし", "None"))
            }
            srows.add("App Sandbox", sandboxed ? L("有効", "Enabled") : L("無効", "Disabled"), tone: sandboxed ? .good : .neutral)
            srows.add("Hardened Runtime", hardened ? L("有効", "Enabled") + (own?.runtimeVersion.map { " (\($0))" } ?? "") : L("無効", "Disabled"), tone: hardened ? .good : .neutral)
            var cs = CodeSignature(); cs.flags = flags
            srows.add(L("フラグ", "Flags"), cs.flagText, mono: true)
            srows.add("CDHash", sec.cdhash ?? own?.cdhash, mono: true)
            srows.add(L("指定要件", "Designated requirement"), sec.designated, mono: true)
        }
        rep.sections.append(ReportSection(id: "signature", title: L("コード署名", "Code Signature"), symbol: "checkmark.seal", blocks: [.rows(srows)]))

        if let e = ents, !e.isEmpty { rep.sections.append(entitlementsSection(e)) }

        if let drv = Drivers.kextSection(info) { rep.sections.append(drv) }
        if let x = AppExtensions.section(AppExtensions.find(in: url)) {
            rep.sections.append(x.section)
            rep.summary.add(L("機能拡張", "Extensions"), x.summary)
        }
        let fwNames = ((try? fm.contentsOfDirectory(atPath: contents.appendingPathComponent("Frameworks").path)) ?? [])
        if let pv = Privacy.section(info: info, localized: localized, entitlements: ents,
                                    manifests: Privacy.manifests(in: url, deadline: opts.deep ? Date().addingTimeInterval(8) : start.addingTimeInterval(opts.budget)), frameworks: fwNames) {
            rep.sections.append(pv.section)
            rep.badges.append(contentsOf: pv.badges)
            rep.summary.add(L("プライバシー", "Privacy"), pv.summary)
        }
        if let sec = infoPlistSection(info, localized: localized) { rep.sections.append(sec) }

        // Components
        let deadline = opts.deep ? Date.distantFuture : start.addingTimeInterval(opts.budget)
        let comps = components(root: url, mainExec: execURL, opts: opts, deadline: deadline)
        if !comps.items.isEmpty {
            var blocks: [Block] = [.table(TableData(
                columns: [L("場所", "Path"), L("種類", "Kind"), L("アーキテクチャ", "Arch"), L("バージョン", "Version"), "Team ID", L("署名", "Signing")],
                rows: comps.items.map { [$0.path, $0.kind, $0.arch, $0.version, $0.team, $0.traits] }))]
            let mainTeam = sec.teamID ?? own?.teamID
            let foreign = Set(comps.items.map { $0.team }.filter { !$0.isEmpty && $0 != mainTeam })
            if let mainTeam, !foreign.isEmpty {
                blocks.append(.note(L("本体 (\(mainTeam)) と異なる Team ID のコンポーネントがあります: ", "Some components are signed by a different team than the app (\(mainTeam)): ") + foreign.sorted().joined(separator: ", ")))
            }
            if comps.truncated { blocks.append(.note(L("一覧は途中までです。Nakami で開くとすべて表示します。", "List truncated. Open in Nakami for everything."))) }
            rep.sections.append(ReportSection(id: "components", title: L("コンポーネント", "Components"), symbol: "shippingbox", blocks: blocks, count: comps.items.count))
        }

        // Provisioning profile
        for n in ["embedded.provisionprofile", "embedded.mobileprovision"] {
            if let blob = try? Data(contentsOf: contents.appendingPathComponent(n)), let p = profile(blob) {
                rep.sections.append(p.section)
                break
            }
        }

        // Executable details
        if let d = execData {
            rep.sections.append(contentsOf: MachO.sections(slices, data: d, opts: opts, includeSignature: false))
        }

        // Size on disk (deep mode only: walking a large bundle takes a while).
        if opts.deep, let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: []) {
            var total = 0, files = 0
            let limit = Date().addingTimeInterval(4)
            var partial = false
            for case let u as URL in en {
                if files & 0x3ff == 0, Date() > limit { partial = true; break }
                if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                    total += v.totalFileAllocatedSize ?? 0
                    files += 1
                }
            }
            rep.summary.add(L("ディスク上のサイズ", "Size on disk"), (partial ? "≥ " : "") + byteSize(total) + L("（\(files) ファイル）", " (\(files) files)"))
        }
        return rep
    }
    #endif
}
