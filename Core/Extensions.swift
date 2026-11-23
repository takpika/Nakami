import Foundation

/// App extensions embedded in an app (Quick Look, Share, Widgets, Safari …): what each one is and what it handles.
enum AppExtensions {
    static let points: [String: (ja: String, en: String)] = [
        "com.apple.quicklook.preview": ("Quick Look プレビュー", "Quick Look preview"),
        "com.apple.quicklook.thumbnail": ("Quick Look サムネイル", "Quick Look thumbnail"),
        "com.apple.spotlight.import": ("Spotlight 取り込み", "Spotlight import"),
        "com.apple.spotlight.index": ("Spotlight 索引", "Spotlight index"),
        "com.apple.share-services": ("共有", "Share"),
        "com.apple.ui-services": ("アクション", "Action"),
        "com.apple.services": ("アクション（画面なし）", "Action (no UI)"),
        "com.apple.widgetkit-extension": ("ウィジェット", "Widget"),
        "com.apple.widget-extension": ("通知センターのウィジェット（旧式）", "Today widget (legacy)"),
        "com.apple.FinderSync": ("Finder 同期", "Finder Sync"),
        "com.apple.fileprovider-nonui": ("ファイルプロバイダー", "File Provider"),
        "com.apple.fileprovider-actionsui": ("ファイルプロバイダーの操作画面", "File Provider UI"),
        "com.apple.usernotifications.service": ("通知サービス", "Notification service"),
        "com.apple.usernotifications.content-extension": ("通知の表示", "Notification content"),
        "com.apple.Safari.web-extension": ("Safari Web 拡張", "Safari web extension"),
        "com.apple.Safari.content-blocker": ("Safari コンテンツブロッカー", "Safari content blocker"),
        "com.apple.Safari.extension": ("Safari App 拡張", "Safari app extension"),
        "com.apple.intents-service": ("Siri インテント", "Siri intents"),
        "com.apple.intents-ui-service": ("Siri インテントの画面", "Siri intents UI"),
        "com.apple.appintents-extension": ("App Intents", "App Intents"),
        "com.apple.keyboard-service": ("キーボード", "Keyboard"),
        "com.apple.photo-editing": ("写真編集", "Photo editing"),
        "com.apple.photo-project": ("写真プロジェクト", "Photos project"),
        "com.apple.networkextension.packet-tunnel": ("VPN（パケットトンネル）", "VPN (packet tunnel)"),
        "com.apple.networkextension.app-proxy": ("VPN（アプリプロキシ）", "VPN (app proxy)"),
        "com.apple.networkextension.filter-data": ("通信フィルター", "Content filter"),
        "com.apple.networkextension.filter-control": ("通信フィルターの制御", "Content filter control"),
        "com.apple.networkextension.dns-proxy": ("DNS プロキシ", "DNS proxy"),
        "com.apple.authentication-services-credential-provider-ui": ("パスワードの自動入力", "Password AutoFill"),
        "com.apple.authentication-services-account-authentication-modification-ui": ("アカウントの認証変更", "Account authentication modification"),
        "com.apple.AppSSO.idp-extension": ("シングルサインオン", "Single sign-on"),
        "com.apple.message-payload-provider": ("iMessage", "iMessage"),
        "com.apple.callkit.call-directory": ("着信の識別・拒否", "Call directory"),
        "com.apple.identitylookup.message-filter": ("メッセージフィルター", "Message filter"),
        "com.apple.broadcast-services-upload": ("画面のブロードキャスト", "Broadcast upload"),
        "com.apple.broadcast-services-setupui": ("ブロードキャストの設定画面", "Broadcast setup UI"),
        "com.apple.watchkit": ("Apple Watch アプリ", "WatchKit"),
        "com.apple.tv-services": ("Apple TV のトップシェルフ", "TV Top Shelf"),
        "com.apple.dt.Xcode.extension.source-editor": ("Xcode ソースエディター拡張", "Xcode source editor"),
        "com.apple.AudioUnit-UI": ("Audio Unit", "Audio Unit"),
        "com.apple.AudioUnit": ("Audio Unit", "Audio Unit"),
        "com.apple.email.extension": ("メール拡張", "Mail extension"),
        "com.apple.ctk-tokens": ("スマートカード", "Smart card token"),
        "com.apple.deviceactivity.monitor-extension": ("スクリーンタイムの監視", "Device activity monitor"),
        "com.apple.ManagedSettingsUI.shield-configuration-service": ("スクリーンタイムの制限画面", "Shield configuration"),
        "com.apple.background-asset-downloader-extension": ("バックグラウンドのアセット取得", "Background assets"),
        "com.apple.textinputmethod": ("入力メソッド", "Input method"),
        "com.apple.printing.discovery": ("プリンターの検出", "Printer discovery"),
        "com.apple.classkit.context-provider": ("ClassKit", "ClassKit"),
        "com.apple.matter.support.extension.device-setup": ("Matter デバイスの設定", "Matter device setup"),
        "com.apple.live-lookup": ("着信のリアルタイム識別", "Live caller ID"),
        "com.apple.accessory-setup-kit": ("アクセサリの設定", "Accessory setup"),
    ]

    static func pointName(_ id: String) -> String {
        points[id].map { L($0.ja, $0.en) } ?? id
    }

    /// One extension, described from its Info.plist.
    static func describe(path: String, info: [String: Any]) -> (name: String, point: String, pointID: String, rows: [Row]) {
        let ext = info["NSExtension"] as? [String: Any]
        let ek = info["EXAppExtensionAttributes"] as? [String: Any]
        let pointID = (ext?["NSExtensionPointIdentifier"] as? String) ?? (ek?["EXExtensionPointIdentifier"] as? String) ?? ""
        let attrs = (ext?["NSExtensionAttributes"] as? [String: Any]) ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var rows = [Row]()
        rows.add(L("種類", "Kind"), pointID.isEmpty ? L("不明", "Unknown") : pointName(pointID) + (points[pointID] != nil ? "\n" + pointID : ""))
        rows.add(L("識別子", "Identifier"), info["CFBundleIdentifier"] as? String, mono: true)
        let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
        rows.add(L("バージョン", "Version"), short.map { $0 + (build != nil && build != $0 ? " (\(build!))" : "") } ?? build)
        func list(_ key: String) -> String? {
            guard let a = attrs[key] as? [String], !a.isEmpty else { return nil }
            return a.joined(separator: "\n")
        }
        // What the extension is offered for.
        rows.add(L("対応するファイルの種類", "Supported file types"), list("QLSupportedContentTypes") ?? list("CSSupportedContentTypes") ?? list("UTTypeIdentifiers"), mono: true)
        if let rule = attrs["NSExtensionActivationRule"] {
            if let s = rule as? String {
                rows.add(L("現れる条件", "Activation rule"), s == "TRUEPREDICATE" ? L("常に（すべての項目）", "Always (any item)") : s, mono: s != "TRUEPREDICATE")
            } else if let d = rule as? [String: Any] {
                let names: [String: String] = [
                    "NSExtensionActivationSupportsWebURLWithMaxCount": L("Web の URL", "Web URLs"), "NSExtensionActivationSupportsWebPageWithMaxCount": L("Web ページ", "Web pages"),
                    "NSExtensionActivationSupportsText": L("テキスト", "Text"), "NSExtensionActivationSupportsImageWithMaxCount": L("画像", "Images"),
                    "NSExtensionActivationSupportsMovieWithMaxCount": L("動画", "Movies"), "NSExtensionActivationSupportsFileWithMaxCount": L("ファイル", "Files"),
                    "NSExtensionActivationSupportsAttachmentsWithMaxCount": L("添付ファイル", "Attachments"),
                ]
                let parts = d.keys.sorted().compactMap { k -> String? in
                    let v = describePlistValue(d[k]!)
                    if v == "0" || v == "false" { return nil }
                    return (names[k] ?? k) + (v == "true" ? "" : L("（最大 \(v)）", " (up to \(v))"))
                }
                rows.add(L("現れる条件", "Offered for"), parts.joined(separator: "\n"))
            }
        }
        rows.add(L("対応する Siri の操作", "Supported intents"), list("IntentsSupported"), mono: true)
        rows.add(L("通知のカテゴリ", "Notification categories"), (attrs["UNNotificationExtensionCategory"] as? String) ?? list("UNNotificationExtensionCategory"), mono: true)
        rows.add(L("ファイルプロバイダーのグループ", "File Provider group"), ext?["NSExtensionFileProviderDocumentGroup"] as? String, mono: true)
        if (attrs["QLIsDataBasedPreview"] as? Bool) == true { rows.add(L("プレビューの方式", "Preview style"), L("データを返す方式", "Data-based")) }
        if let min = attrs["QLThumbnailMinimumDimension"] { rows.add(L("サムネイルの最小サイズ", "Minimum thumbnail size"), describePlistValue(min)) }
        rows.add(L("主クラス", "Principal class"), (ext?["NSExtensionPrincipalClass"] as? String) ?? (ext?["NSExtensionMainStoryboard"] as? String).map { "Storyboard: \($0)" }, mono: true)
        rows.add(L("場所", "Path"), path, mono: true)
        return (name, pointID.isEmpty ? L("不明", "Unknown") : pointName(pointID), pointID, rows)
    }

    static func section(_ exts: [(path: String, info: [String: Any])]) -> (section: ReportSection, summary: String)? {
        guard !exts.isEmpty else { return nil }
        var blocks = [Block]()
        var kinds = [String]()
        for e in exts.sorted(by: { $0.path < $1.path }) {
            let d = describe(path: e.path, info: e.info)
            blocks.append(.heading(d.name))
            blocks.append(.rows(d.rows))
            if !kinds.contains(d.point) { kinds.append(d.point) }
        }
        return (ReportSection(id: "extensions", title: L("機能拡張", "Extensions"), symbol: "puzzlepiece.extension", blocks: blocks, count: exts.count),
                "\(exts.count)" + L(" 個（", " (") + kinds.joined(separator: L("、", ", ")) + L("）", ")"))
    }

    /// Extensions inside a bundle on disk (macOS): PlugIns, Extensions, and one level into nested apps.
    static func find(in bundle: URL) -> [(path: String, info: [String: Any])] {
        let fm = FileManager.default
        var out = [(String, [String: Any])]()
        func scan(_ contents: URL, prefix: String, depth: Int) {
            for dir in ["PlugIns", "Extensions"] {
                let d = contents.appendingPathComponent(dir)
                for name in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted() where name.hasSuffix(".appex") {
                    let u = d.appendingPathComponent(name)
                    let plist = [u.appendingPathComponent("Contents/Info.plist"), u.appendingPathComponent("Info.plist")].first { fm.fileExists(atPath: $0.path) }
                    guard let p = plist, let data = try? Data(contentsOf: p),
                          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                    out.append((prefix + dir + "/" + name, info))
                }
            }
            guard depth < 2 else { return }
            // Helper apps and watch apps bundled inside carry their own extensions.
            for sub in ["Helpers", "Library/LoginItems", "Watch", "Resources", "SharedSupport", "Applications"] {
                let d = contents.appendingPathComponent(sub)
                for name in ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).sorted() where name.hasSuffix(".app") {
                    let app = d.appendingPathComponent(name)
                    let c = fm.fileExists(atPath: app.appendingPathComponent("Contents").path) ? app.appendingPathComponent("Contents") : app
                    scan(c, prefix: prefix + sub + "/" + name + "/", depth: depth + 1)
                }
            }
        }
        let c = fm.fileExists(atPath: bundle.appendingPathComponent("Contents").path) ? bundle.appendingPathComponent("Contents") : bundle
        scan(c, prefix: "", depth: 0)
        return out
    }

    /// Extensions inside an app stored in an archive or folder listing (ipa, zipped app, .app folder on iOS).
    static func find(in zip: Zip, appDir: String) -> [(path: String, info: [String: Any])] {
        var out = [(String, [String: Any])]()
        for e in zip.entries where e.name.hasPrefix(appDir) && e.name.hasSuffix("Info.plist") {
            let rel = String(e.name.dropFirst(appDir.count))
            let parts = rel.split(separator: "/").map(String.init)
            // …/PlugIns/Foo.appex/Info.plist or …/Extensions/Foo.appex/Contents/Info.plist, at any depth (watch apps nest theirs).
            guard let i = parts.lastIndex(where: { $0.hasSuffix(".appex") }), i >= 1, ["PlugIns", "Extensions"].contains(parts[i - 1]),
                  parts.count - i <= 3, parts.count - i >= 2, parts.last == "Info.plist", parts.count - i == 2 || parts[i + 1] == "Contents" else { continue }
            guard let d = zip.read(e, max: 4 << 20), let info = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { continue }
            out.append((parts[...i].joined(separator: "/"), info))
        }
        return out
    }
}
