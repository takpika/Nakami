import Foundation

/// Everything privacy-related an app declares: permission prompts, privacy manifests (its own and its SDKs'),
/// tracking, sensitive entitlements, network security exceptions and background activity.
enum Privacy {
    static let usage: [String: (ja: String, en: String)] = [
        "NSCameraUsageDescription": ("カメラ", "Camera"), "NSMicrophoneUsageDescription": ("マイク", "Microphone"),
        "NSLocationWhenInUseUsageDescription": ("位置情報（使用中のみ）", "Location (while using)"), "NSLocationAlwaysUsageDescription": ("位置情報（常に）", "Location (always)"),
        "NSLocationAlwaysAndWhenInUseUsageDescription": ("位置情報（常に）", "Location (always)"), "NSLocationUsageDescription": ("位置情報", "Location"),
        "NSLocationTemporaryUsageDescriptionDictionary": ("正確な位置情報（一時的）", "Precise location (temporary)"),
        "NSPhotoLibraryUsageDescription": ("写真", "Photos"), "NSPhotoLibraryAddUsageDescription": ("写真への追加", "Add to Photos"),
        "NSContactsUsageDescription": ("連絡先", "Contacts"), "NSCalendarsUsageDescription": ("カレンダー", "Calendars"),
        "NSCalendarsFullAccessUsageDescription": ("カレンダー（すべて）", "Calendars (full access)"), "NSCalendarsWriteOnlyAccessUsageDescription": ("カレンダー（追加のみ）", "Calendars (add only)"),
        "NSRemindersUsageDescription": ("リマインダー", "Reminders"), "NSRemindersFullAccessUsageDescription": ("リマインダー（すべて）", "Reminders (full access)"),
        "NSBluetoothAlwaysUsageDescription": ("Bluetooth", "Bluetooth"), "NSBluetoothPeripheralUsageDescription": ("Bluetooth", "Bluetooth"),
        "NSLocalNetworkUsageDescription": ("ローカルネットワーク", "Local network"), "NSFaceIDUsageDescription": ("Face ID", "Face ID"),
        "NSSpeechRecognitionUsageDescription": ("音声認識", "Speech recognition"), "NSMotionUsageDescription": ("モーションとフィットネス", "Motion & fitness"),
        "NSHealthShareUsageDescription": ("ヘルスケア（読み取り）", "Health (read)"), "NSHealthUpdateUsageDescription": ("ヘルスケア（書き込み）", "Health (write)"),
        "NSHealthClinicalHealthRecordsShareUsageDescription": ("ヘルスケアの医療記録", "Clinical health records"),
        "NSHomeKitUsageDescription": ("HomeKit", "HomeKit"), "NSAppleMusicUsageDescription": ("メディアライブラリ", "Media library"), "NSSiriUsageDescription": ("Siri", "Siri"),
        "NSUserTrackingUsageDescription": ("トラッキング（他社のアプリや Web サイトをまたぐ追跡）", "Tracking across apps and websites"),
        "NSAppleEventsUsageDescription": ("ほかのアプリの操作", "Controlling other apps"), "NSSystemAdministrationUsageDescription": ("システムの管理", "System administration"),
        "NSDesktopFolderUsageDescription": ("デスクトップフォルダー", "Desktop folder"), "NSDocumentsFolderUsageDescription": ("書類フォルダー", "Documents folder"),
        "NSDownloadsFolderUsageDescription": ("ダウンロードフォルダー", "Downloads folder"), "NSRemovableVolumesUsageDescription": ("外付けボリューム", "Removable volumes"),
        "NSNetworkVolumesUsageDescription": ("ネットワークボリューム", "Network volumes"), "NSFileProviderDomainUsageDescription": ("クラウドストレージのファイル", "File Provider files"),
        "NSNearbyInteractionUsageDescription": ("近くのデバイスとの距離測定", "Nearby interaction"), "NSNearbyInteractionAllowOnceUsageDescription": ("近くのデバイスとの距離測定", "Nearby interaction"),
        "NFCReaderUsageDescription": ("NFC", "NFC"), "NSFocusStatusUsageDescription": ("集中モードの状態", "Focus status"),
        "NSGKFriendListUsageDescription": ("Game Center の友達", "Game Center friends"), "NSScreenCaptureUsageDescription": ("画面の収録", "Screen recording"),
        "NSInputMonitoringUsageDescription": ("キー入力の監視", "Input monitoring"), "NSAccessibilityUsageDescription": ("アクセシビリティ", "Accessibility"),
        "NSSensorKitUsageDescription": ("研究用センサー", "SensorKit"), "NSIdentityUsageDescription": ("身分証明書", "Identity documents"),
        "NSWorldSensingUsageDescription": ("周囲の空間の認識", "World sensing"), "NSHandsTrackingUsageDescription": ("手の動きの認識", "Hand tracking"),
        "NSAudioCaptureUsageDescription": ("システムの音声の収録", "System audio capture"), "NSVideoSubscriberAccountUsageDescription": ("TV プロバイダー", "TV provider"),
        "NSAlarmKitUsageDescription": ("アラーム", "Alarms"), "NSCriticalMessagingUsageDescription": ("重大なメッセージ", "Critical messaging"),
    ]

    static let entitlements: [String: (ja: String, en: String)] = [
        "com.apple.security.device.camera": ("カメラ", "Camera"), "com.apple.security.device.audio-input": ("マイク", "Microphone"),
        "com.apple.security.device.microphone": ("マイク", "Microphone"), "com.apple.security.device.bluetooth": ("Bluetooth", "Bluetooth"),
        "com.apple.security.device.usb": ("USB デバイス", "USB devices"), "com.apple.security.personal-information.location": ("位置情報", "Location"),
        "com.apple.security.personal-information.addressbook": ("連絡先", "Contacts"), "com.apple.security.personal-information.calendars": ("カレンダー", "Calendars"),
        "com.apple.security.personal-information.photos-library": ("写真", "Photos"), "com.apple.security.network.client": ("外部への通信", "Outgoing network connections"),
        "com.apple.security.network.server": ("外部からの接続の受け付け", "Incoming network connections"), "com.apple.security.automation.apple-events": ("ほかのアプリの操作", "Controlling other apps"),
        "com.apple.security.files.user-selected.read-only": ("選んだファイルの読み取り", "Read files you choose"), "com.apple.security.files.user-selected.read-write": ("選んだファイルの読み書き", "Read and write files you choose"),
        "com.apple.security.files.downloads.read-write": ("ダウンロードフォルダーの読み書き", "Downloads folder"), "com.apple.security.files.all": ("すべてのファイル", "All files"),
        "com.apple.security.cs.disable-library-validation": ("ほかの開発元のコードの読み込み", "Loads code from other developers"),
        "com.apple.security.cs.allow-jit": ("実行時のコード生成 (JIT)", "JIT code generation"), "com.apple.security.cs.allow-unsigned-executable-memory": ("署名のない実行可能メモリー", "Unsigned executable memory"),
        "com.apple.security.cs.allow-dyld-environment-variables": ("起動時の環境変数による差し替え", "dyld environment variables"), "com.apple.security.get-task-allow": ("デバッガーの接続", "Debugger attachment"),
        "get-task-allow": ("デバッガーの接続", "Debugger attachment"), "aps-environment": ("プッシュ通知", "Push notifications"), "com.apple.developer.aps-environment": ("プッシュ通知", "Push notifications"),
        "com.apple.developer.healthkit": ("ヘルスケア", "HealthKit"), "com.apple.developer.homekit": ("HomeKit", "HomeKit"), "com.apple.developer.siri": ("Siri", "Siri"),
        "com.apple.developer.nfc.readersession.formats": ("NFC の読み取り", "NFC reading"), "com.apple.developer.associated-domains": ("関連付けられたドメイン", "Associated domains"),
        "com.apple.developer.icloud-container-identifiers": ("iCloud", "iCloud"), "com.apple.developer.ubiquity-kvstore-identifier": ("iCloud のキー値ストア", "iCloud key-value store"),
        "com.apple.security.application-groups": ("アプリグループ（ほかのアプリとのデータ共有）", "App groups (shared data)"), "keychain-access-groups": ("キーチェーンの共有", "Keychain sharing"),
        "com.apple.developer.networking.networkextension": ("ネットワーク拡張（VPN / フィルター）", "Network extensions (VPN / filtering)"), "com.apple.developer.networking.vpn.api": ("VPN の構成", "VPN configuration"),
        "com.apple.developer.networking.wifi-info": ("Wi-Fi の情報", "Wi-Fi information"), "com.apple.developer.networking.multicast": ("マルチキャスト通信", "Multicast networking"),
        "com.apple.developer.family-controls": ("スクリーンタイム（ファミリー管理）", "Family Controls"), "com.apple.developer.usernotifications.time-sensitive": ("即時通知", "Time-sensitive notifications"),
        "com.apple.developer.usernotifications.critical-alerts": ("重大な通知", "Critical alerts"), "com.apple.developer.carplay-audio": ("CarPlay", "CarPlay"),
        "com.apple.developer.in-app-payments": ("Apple Pay", "Apple Pay"), "com.apple.developer.applesignin": ("Apple でサインイン", "Sign in with Apple"),
        "com.apple.developer.devicecheck.appattest-environment": ("App Attest", "App Attest"), "com.apple.developer.location.push": ("位置情報のプッシュ", "Location push"),
        "com.apple.developer.kernel.increased-memory-limit": ("メモリー上限の引き上げ", "Increased memory limit"), "com.apple.developer.system-extension.install": ("システム拡張のインストール", "Install system extensions"),
        "com.apple.developer.endpoint-security.client": ("エンドポイントセキュリティ（システム全体の監視）", "Endpoint Security (system-wide monitoring)"),
        "com.apple.developer.driverkit": ("ドライバー", "DriverKit"), "com.apple.developer.screen-capture.include-passthrough": ("画面の取り込み", "Screen capture"),
    ]

    /// Entitlements that weaken the protections an app normally runs under.
    static let risky: Set<String> = [
        "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-jit", "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.files.all",
        "com.apple.developer.endpoint-security.client",
    ]

    /// SF Symbol for a usage-description key or an entitlement, matched on a part of the key.
    static func symbol(for key: String) -> String {
        let k = key.lowercased()
        let table: [(String, String)] = [
            ("camera", "camera.fill"), ("microphone", "mic.fill"), ("audio-input", "mic.fill"), ("audiocapture", "waveform"), ("speech", "waveform"),
            ("location", "location.fill"), ("photo", "photo.fill"), ("contacts", "person.crop.circle.fill"), ("addressbook", "person.crop.circle.fill"),
            ("calendar", "calendar"), ("reminders", "checklist"), ("bluetooth", "dot.radiowaves.left.and.right"), ("usertracking", "eye.fill"),
            ("networkextension", "lock.shield.fill"), ("vpn", "lock.shield.fill"), ("wifi", "wifi"), ("network", "network"), ("multicast", "network"),
            ("faceid", "faceid"), ("motion", "figure.walk"), ("health", "heart.fill"), ("homekit", "house.fill"), ("applemusic", "music.note"),
            ("siri", "mic.circle.fill"), ("appleevents", "gearshape.2.fill"), ("apple-events", "gearshape.2.fill"), ("systemadministration", "gearshape.2.fill"),
            ("screencapture", "rectangle.dashed.badge.record"), ("screen-capture", "rectangle.dashed.badge.record"), ("inputmonitoring", "keyboard.fill"),
            ("accessibility", "accessibility"), ("usb", "cable.connector"), ("nfc", "wave.3.right.circle.fill"), ("nearbyinteraction", "wave.3.right.circle.fill"),
            ("aps-environment", "bell.badge.fill"), ("usernotifications", "bell.badge.fill"), ("alarm", "alarm.fill"), ("critical", "bell.badge.fill"),
            ("icloud", "icloud.fill"), ("ubiquity", "icloud.fill"), ("keychain", "key.fill"), ("application-groups", "square.stack.3d.up.fill"),
            ("in-app-payments", "creditcard.fill"), ("applesignin", "person.badge.key.fill"), ("family-controls", "hourglass"), ("carplay", "car.fill"),
            ("get-task-allow", "ant.fill"), ("security.cs.", "exclamationmark.triangle.fill"), ("endpoint-security", "eye.fill"),
            ("system-extension", "puzzlepiece.extension.fill"), ("driverkit", "puzzlepiece.extension.fill"), ("memory", "memorychip.fill"),
            ("associated-domains", "link"), ("appattest", "checkmark.shield.fill"), ("focusstatus", "moon.fill"), ("gkfriend", "gamecontroller.fill"),
            ("identity", "person.text.rectangle.fill"), ("worldsensing", "cube.transparent"), ("hands", "hand.raised.fill"), ("sensorkit", "sensor.fill"),
            ("videosubscriber", "tv.fill"), ("folder", "folder.fill"), ("files", "folder.fill"), ("volumes", "externaldrive.fill"), ("fileprovider", "folder.fill"),
        ]
        return table.first { k.contains($0.0) }?.1 ?? "hand.raised.fill"
    }

    /// SDKs recognised from the names of bundled frameworks.
    static let sdks: [(match: String, name: String, kind: String)] = [
        ("firebaseanalytics", "Firebase Analytics", "analytics"), ("firebasecrashlytics", "Firebase Crashlytics", "crash"), ("firebase", "Firebase", "analytics"),
        ("googlemobileads", "Google Mobile Ads (AdMob)", "ads"), ("fbsdk", "Facebook SDK", "ads"), ("fbaudiencenetwork", "Meta Audience Network", "ads"),
        ("appsflyer", "AppsFlyer", "attribution"), ("adjust", "Adjust", "attribution"), ("branch", "Branch", "attribution"), ("amplitude", "Amplitude", "analytics"),
        ("mixpanel", "Mixpanel", "analytics"), ("sentry", "Sentry", "crash"), ("bugsnag", "Bugsnag", "crash"), ("applovin", "AppLovin", "ads"), ("unityads", "Unity Ads", "ads"),
        ("ironsource", "ironSource", "ads"), ("vungle", "Vungle", "ads"), ("chartboost", "Chartboost", "ads"), ("onesignal", "OneSignal", "push"), ("braze", "Braze", "marketing"),
        ("segment", "Segment", "analytics"), ("flurry", "Flurry", "analytics"), ("newrelic", "New Relic", "monitoring"), ("datadog", "Datadog", "monitoring"),
        ("tiktok", "TikTok SDK", "ads"), ("singular", "Singular", "attribution"), ("kochava", "Kochava", "attribution"), ("instabug", "Instabug", "crash"),
        ("appcenter", "App Center", "crash"), ("revenuecat", "RevenueCat", "purchases"), ("sparkle", "Sparkle", "updates"), ("pangle", "Pangle", "ads"), ("mopub", "MoPub", "ads"),
    ]

    /// The display text for a term these tables give in Japanese: Japanese, its Traditional Chinese, or the readable key.
    static func termText(_ ja: String?, fallback: String) -> String {
        guard let ja else { return fallback }
        if prefersJapanese { return ja }
        if prefersTraditionalChinese { return zhHant[ja] ?? fallback }
        return fallback
    }

    static func humanize(_ id: String, prefix: String) -> String {
        var s = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        var out = ""
        for (i, c) in s.enumerated() {
            if c.isUppercase, i > 0, let prev = out.last, prev.isLowercase { out.append(" ") }
            out.append(c)
        }
        s = out
        return s
    }

    static let dataTypes: [String: String] = [
        "Name": "名前", "EmailAddress": "メールアドレス", "PhoneNumber": "電話番号", "PhysicalAddress": "住所", "OtherUserContactInfo": "そのほかの連絡先情報",
        "Health": "ヘルスケア", "Fitness": "フィットネス", "PaymentInfo": "支払い情報", "CreditInfo": "信用情報", "OtherFinancialInfo": "そのほかの金融情報",
        "PreciseLocation": "正確な位置情報", "CoarseLocation": "おおよその位置情報", "SensitiveInfo": "機微な情報", "Contacts": "連絡先", "EmailsOrTextMessages": "メールやメッセージ",
        "PhotosorVideos": "写真や動画", "AudioData": "音声", "GameplayContent": "ゲームのプレイ内容", "CustomerSupport": "サポートへの問い合わせ", "OtherUserContent": "そのほかのユーザーコンテンツ",
        "BrowsingHistory": "閲覧履歴", "SearchHistory": "検索履歴", "UserID": "ユーザー ID", "DeviceID": "デバイス ID", "PurchaseHistory": "購入履歴",
        "ProductInteraction": "アプリ内の操作", "AdvertisingData": "広告データ", "OtherUsageData": "そのほかの使用状況", "CrashData": "クラッシュデータ",
        "PerformanceData": "パフォーマンスデータ", "OtherDiagnosticData": "そのほかの診断データ", "EnvironmentScanning": "周囲のスキャン", "Hands": "手の動き", "Head": "頭の動き", "OtherDataTypes": "そのほかのデータ",
    ]
    static let purposes: [String: String] = [
        "ThirdPartyAdvertising": "他社の広告", "DeveloperAdvertising": "開発元の広告・マーケティング", "Analytics": "分析", "ProductPersonalization": "パーソナライズ",
        "AppFunctionality": "アプリの機能", "Other": "そのほか",
    ]
    static let apiTypes: [String: String] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": "ファイルの日時", "NSPrivacyAccessedAPICategorySystemBootTime": "システムの起動時刻",
        "NSPrivacyAccessedAPICategoryDiskSpace": "ディスクの空き容量", "NSPrivacyAccessedAPICategoryActiveKeyboards": "有効なキーボードの一覧",
        "NSPrivacyAccessedAPICategoryUserDefaults": "ユーザーデフォルト（設定の保存領域）",
    ]

    static func section(info: [String: Any], localized: [String: Any] = [:], entitlements ents: [String: Any]?, manifests: [(path: String, plist: [String: Any])], frameworks: [String])
        -> (section: ReportSection, badges: [Badge], summary: String?)? {
        var blocks = [Block]()
        var badges = [Badge]()
        var points = [String]()

        // 1. Permission prompts
        let keys = info.keys.filter { $0.hasSuffix("UsageDescription") || $0 == "NFCReaderUsageDescription" || $0 == "NSLocationTemporaryUsageDescriptionDictionary" }.sorted()
        if !keys.isEmpty {
            blocks.append(.heading(L("求める可能性のある許可（アプリが示す理由）", "Permissions it may ask for (with the app's stated reason)")))
            var rows = [Row]()
            for k in keys {
                let row = Row(usage[k].map { L($0.ja, $0.en) } ?? humanize(k.replacingOccurrences(of: "UsageDescription", with: ""), prefix: "NS"),
                              describePlistValue(localized[k] ?? info[k]!), tone: k == "NSUserTrackingUsageDescription" ? .warn : .neutral, symbol: symbol(for: k))
                if !rows.contains(row) { rows.append(row) }   // old and new keys for the same thing often carry the same text
            }
            blocks.append(.rows(rows))
            points.append(L("許可 \(keys.count) 種", "\(keys.count) permissions", "\(keys.count) 種許可"))
        }
        let tracksByPrompt = info["NSUserTrackingUsageDescription"] != nil

        // 2. Privacy manifests: the app's own and those of bundled SDKs
        var tracking = false
        var domains = [String]()
        var collected = [[String]]()
        var apis = [[String]]()
        for m in manifests {
            let who = m.path.components(separatedBy: "/").last { $0.hasSuffix(".framework") || $0.hasSuffix(".bundle") || $0.hasSuffix(".appex") || $0.hasSuffix(".app") } ?? L("アプリ本体", "The app")
            if (m.plist["NSPrivacyTracking"] as? Bool) == true { tracking = true }
            domains += (m.plist["NSPrivacyTrackingDomains"] as? [String]) ?? []
            for d in (m.plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? [] {
                let type = humanize((d["NSPrivacyCollectedDataType"] as? String) ?? "", prefix: "NSPrivacyCollectedDataType").replacingOccurrences(of: " ", with: "")
                let purposeList = ((d["NSPrivacyCollectedDataTypePurposes"] as? [String]) ?? []).map { p -> String in
                    let k = p.replacingOccurrences(of: "NSPrivacyCollectedDataTypePurpose", with: "")
                    return termText(purposes[k], fallback: humanize(k, prefix: ""))
                }
                collected.append([termText(dataTypes[type], fallback: humanize(type, prefix: "")),
                                  (d["NSPrivacyCollectedDataTypeLinked"] as? Bool) == true ? L("ひも付ける", "Linked") : L("ひも付けない", "Not linked"),
                                  (d["NSPrivacyCollectedDataTypeTracking"] as? Bool) == true ? L("使う", "Yes") : L("使わない", "No"),
                                  purposeList.joined(separator: L("、", ", ")), who])
            }
            for a in (m.plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? [] {
                let t = (a["NSPrivacyAccessedAPIType"] as? String) ?? ""
                apis.append([termText(apiTypes[t], fallback: humanize(t, prefix: "NSPrivacyAccessedAPICategory")),
                             ((a["NSPrivacyAccessedAPITypeReasons"] as? [String]) ?? []).joined(separator: ", "), who])
            }
        }
        if !manifests.isEmpty {
            blocks.append(.heading(L("プライバシーマニフェスト（\(manifests.count) 個）", "Privacy manifests (\(manifests.count))", "隱私權清單（\(manifests.count) 個）")))
            var rows = [Row]()
            rows.add(L("トラッキング", "Tracking"), tracking ? L("行うと宣言しています", "Declared") : L("行わないと宣言しています", "Declared as none"), tone: tracking ? .warn : .good)
            rows.add(L("トラッキング用のドメイン", "Tracking domains"), Array(Set(domains)).sorted().joined(separator: "\n"), mono: true)
            blocks.append(.rows(rows))
            if !collected.isEmpty {
                blocks.append(.table(TableData(columns: [L("収集するデータ", "Data collected"), L("本人とのひも付け", "Linked to you"), L("トラッキングに使用", "Used for tracking"), L("目的", "Purposes"), L("宣言元", "Declared by")], rows: collected)))
                points.append(L("収集データ \(collected.count) 種", "\(collected.count) data types", "\(collected.count) 種收集的資料"))
            }
            if !apis.isEmpty {
                blocks.append(.table(TableData(columns: [L("理由の申告が必要な API", "Required-reason API"), L("理由コード", "Reason codes"), L("宣言元", "Declared by")], rows: apis)))
            }
        } else if (info["CFBundleSupportedPlatforms"] as? [String])?.first != "MacOSX" || !keys.isEmpty {
            blocks.append(.note(L("プライバシーマニフェスト (PrivacyInfo.xcprivacy) は入っていません。", "No privacy manifest (PrivacyInfo.xcprivacy) is included.")))
        }
        if tracking || tracksByPrompt {
            badges.append(Badge(text: L("トラッキングあり", "Tracking"), tone: .warn))
            points.insert(L("トラッキングあり", "tracking"), at: 0)
        }

        // 3. Bundled SDKs known for analytics / ads
        var found = [[String]]()
        var seen = Set<String>()
        for f in frameworks {
            let low = f.lowercased()
            if let s = sdks.first(where: { low.contains($0.match) }), !seen.contains(s.name) {
                seen.insert(s.name)
                let kind = ["analytics": L("分析", "Analytics"), "ads": L("広告", "Advertising"), "attribution": L("広告の効果測定", "Attribution"), "crash": L("クラッシュ報告", "Crash reporting"),
                            "push": L("プッシュ通知", "Push"), "marketing": L("マーケティング", "Marketing"), "monitoring": L("監視", "Monitoring"), "purchases": L("課金", "Purchases"),
                            "updates": L("自動アップデート", "Updates")][s.kind] ?? s.kind
                found.append([s.name, kind, f])
            }
        }
        if !found.isEmpty {
            blocks.append(.heading(L("含まれている SDK（フレームワーク名からの推定）", "Bundled SDKs (guessed from framework names)")))
            blocks.append(.table(TableData(columns: ["SDK", L("用途", "Purpose"), L("フレームワーク", "Framework")], rows: found)))
            points.append("SDK \(found.count)")
        }

        // 4. Entitlements that give access to personal data or widen what the app may do
        if let ents {
            // The raw keys and values are listed in the Entitlements section; here they are named in plain words.
            let hits = ents.keys.sorted().compactMap { k -> Row? in
                guard let name = entitlements[k] else { return nil }
                let v = describePlistValue(ents[k]!)
                if v == "false" { return nil }
                return Row(L(name.ja, name.en), v == "true" ? L("認められています", "Granted") : v, mono: v != "true",
                           tone: risky.contains(k) ? .warn : .neutral, symbol: symbol(for: k))
            }
            if !hits.isEmpty {
                blocks.append(.heading(L("署名で認められている権限", "Capabilities granted by the signature")))
                blocks.append(.rows(hits))
            }
        }

        // 5. Network security, background activity, other apps it looks for
        var rows = [Row]()
        if let ats = info["NSAppTransportSecurity"] as? [String: Any] {
            if (ats["NSAllowsArbitraryLoads"] as? Bool) == true { rows.add(L("暗号化なしの通信", "Unencrypted connections"), L("すべての接続先で許可 (NSAllowsArbitraryLoads)", "Allowed everywhere (NSAllowsArbitraryLoads)"), tone: .warn) }
            if (ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool) == true { rows.add(L("Web 表示での暗号化なしの通信", "Unencrypted web content"), L("許可", "Allowed")) }
            if (ats["NSAllowsLocalNetworking"] as? Bool) == true { rows.add(L("ローカルネットワークでの暗号化なしの通信", "Unencrypted local networking"), L("許可", "Allowed")) }
            if let ex = ats["NSExceptionDomains"] as? [String: Any], !ex.isEmpty { rows.add(L("通信の例外を設けたドメイン", "Exception domains"), ex.keys.sorted().joined(separator: "\n"), mono: true) }
        }
        if let bg = info["UIBackgroundModes"] as? [String], !bg.isEmpty {
            let names = ["audio": L("音声の再生・録音", "Audio"), "location": L("位置情報の更新", "Location updates"), "voip": L("通話 (VoIP)", "VoIP"), "fetch": L("定期的な取得", "Background fetch"),
                         "remote-notification": L("通知による起動", "Remote notifications"), "processing": L("バックグラウンド処理", "Processing"), "bluetooth-central": L("Bluetooth 機器との通信", "Bluetooth"),
                         "bluetooth-peripheral": L("Bluetooth 周辺機器としての動作", "Bluetooth peripheral"), "external-accessory": L("外部アクセサリ", "External accessory"), "nearby-interaction": L("近くのデバイスとの距離測定", "Nearby interaction")]
            rows.add(L("バックグラウンドでの動作", "Background activity"), bg.map { names[$0] ?? $0 }.joined(separator: L("、", ", ")))
        }
        if let q = info["LSApplicationQueriesSchemes"] as? [String], !q.isEmpty {
            rows.add(L("インストール有無を調べられるアプリ（URL スキーム）", "Apps it can check for (URL schemes)"), q.prefix(60).joined(separator: ", ") + (q.count > 60 ? " …" : ""), mono: true)
        }
        if (info["NSLocationDefaultAccuracyReduced"] as? Bool) == true { rows.add(L("位置情報の既定の精度", "Default location accuracy"), L("おおよその位置", "Approximate")) }
        if !rows.isEmpty {
            blocks.append(.heading(L("通信とバックグラウンド", "Network and background")))
            blocks.append(.rows(rows))
        }

        guard !blocks.isEmpty else { return nil }
        return (ReportSection(id: "privacy", title: L("プライバシー", "Privacy"), symbol: "hand.raised", blocks: blocks), badges, points.isEmpty ? nil : points.joined(separator: L("、", ", ")))
    }

    /// Privacy manifests inside a bundle on disk (the app's own and one per SDK).
    static func manifests(in bundle: URL, deadline: Date) -> [(path: String, plist: [String: Any])] {
        var out = [(String, [String: Any])]()
        guard let en = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil, options: []) else { return out }
        let base = bundle.path
        var n = 0
        for case let u as URL in en {
            n += 1
            if n & 0xff == 0, Date() > deadline { break }
            guard u.lastPathComponent == "PrivacyInfo.xcprivacy", let d = try? Data(contentsOf: u),
                  let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { continue }
            out.append((String(u.path.dropFirst(base.count + 1)), p))
            if out.count >= 200 { break }
        }
        return out
    }

    static func manifests(in zip: Zip, appDir: String) -> [(path: String, plist: [String: Any])] {
        var out = [(String, [String: Any])]()
        for e in zip.entries where e.name.hasPrefix(appDir) && e.name.hasSuffix("PrivacyInfo.xcprivacy") && out.count < 200 {
            guard let d = zip.read(e, max: 4 << 20), let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { continue }
            out.append((String(e.name.dropFirst(appDir.count)), p))
        }
        return out
    }
}
