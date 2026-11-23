import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// First-launch screens: what the app does, and on macOS, whether its Quick Look extension is switched on.
enum FirstLaunch {
    private static let key = "welcomeShown"
    static var needed: Bool { !UserDefaults.standard.bool(forKey: key) }
    static func finish() { UserDefaults.standard.set(true, forKey: key) }
}

private struct Feature: Identifiable {
    let symbol: String, title: String, text: String
    var id: String { symbol }
}

private var features: [Feature] {
    #if os(macOS)
    [Feature(symbol: "checkmark.shield", title: L("開く前に確認", "Check before you open", "打開前先確認"),
             text: L("アプリやインストーラーの署名・権限・対応 OS が分かります。", "See who signed an app or installer, what it can access and which OS it needs.", "查看 App 或安裝程式的簽章、權限與系統需求。")),
     Feature(symbol: "space", title: L("Finder でスペースキー", "Press Space in Finder", "在 Finder 按下空白鍵"),
             text: L("ファイルを選んでスペースキーを押すと、概要が表示されます。", "Select a file and press Space to see a summary.", "選取檔案後按下空白鍵，即可看到摘要。")),
     Feature(symbol: "app.dashed", title: L("アイコンで見分ける", "Real icons", "用圖像分辨"),
             text: L("exe や apk にも、アプリのアイコンが付きます。", "EXE and APK files show the app's own icon.", "exe 與 apk 檔也會顯示 App 的圖像。"))]
    #else
    [Feature(symbol: "checkmark.shield", title: L("入れる前に確認", "Check before you install", "安裝前先確認"),
             text: L("ipa や apk などの署名・権限・対応 OS が分かります。", "See who signed an IPA or APK, what it can access and which OS it needs.", "查看 ipa、apk 等檔案的簽章、權限與系統需求。")),
     Feature(symbol: "folder", title: L("ファイルを選ぶだけ", "Just pick a file", "選擇檔案即可"),
             text: L("次の画面でファイルを選びます。ほかのアプリの共有メニューからも開けます。", "Pick a file on the next screen, or open one from another app's share menu.", "在下一個畫面選擇檔案，也可以從其他 App 的分享選單打開。")),
     Feature(symbol: "lock", title: L("端末の中で処理", "Stays on your device", "只在裝置上處理"),
             text: L("ファイルの内容を外部に送信しません。", "Nothing about your files leaves your device.", "檔案內容不會傳送到外部。"))]
    #endif
}

private struct AppIconView: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp?.applicationIconImage ?? NSImage()).resizable().frame(width: 84, height: 84)
        #else
        if let name = ((Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]).flatMap({ ($0["CFBundleIconFiles"] as? [String])?.last }),
           let image = UIImage(named: name) {
            Image(uiImage: image).resizable().frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        } else {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
        }
        #endif
    }
}

private struct FeatureList: View {
    #if os(macOS)
    private let titleFont = Font.title3.weight(.semibold), textFont = Font.body
    #else
    private let titleFont = Font.headline, textFont = Font.subheadline
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(features) { f in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: f.symbol)
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.tint)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).font(titleFont)
                        Text(f.text).font(textFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct IntroPage: View {
    var body: some View {
        VStack(spacing: 0) {
            AppIconView().padding(.bottom, 14)
            Text(L("Nakami へようこそ", "Welcome to Nakami", "歡迎使用 Nakami"))
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 30)
            FeatureList()
        }
    }
}

#if os(macOS)
/// Whether the user has switched the Quick Look preview extension off in System Settings. `nil` when it cannot be read.
enum QuickLookExtension {
    static func isEnabled() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-m", "-A", "-i", "jp.takpika.Nakami.Preview"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // One line per registered copy: "+" switched on by the user, "-" switched off, blank = the default (on).
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("jp.takpika.Nakami.Preview") }
        guard p.terminationStatus == 0, !lines.isEmpty else { return nil }
        return !lines.allSatisfy { $0.hasPrefix("-") }
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems") { NSWorkspace.shared.open(u) }
    }
}

private struct SetupPage: View {
    let enabled: Bool?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "eye").font(.system(size: 50, weight: .light)).foregroundStyle(.tint).frame(height: 84).padding(.bottom, 14)
            Text(L("クイックルックの準備", "Set Up Quick Look", "準備快速查看"))
                .font(.largeTitle.weight(.bold))
                .padding(.bottom, 12)
            Text(L("Finder でスペースキーを押したときの表示は、Nakami の機能拡張が担当します。", "A Nakami extension provides the view you get when you press Space in Finder.", "在 Finder 按下空白鍵時的顯示內容，由 Nakami 的延伸功能提供。"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
            status
            if enabled != true {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, L("「システム設定を開く」を押します。", "Click Open System Settings.", "按一下「打開系統設定」。"))
                    step(2, L("「機能拡張」の「クイックルック」を開きます。", "Under Extensions, open Quick Look.", "在「延伸功能」中打開「快速查看」。"))
                    step(3, L("Nakami をオンにします。", "Turn on Nakami.", "開啟 Nakami。"))
                }
                .padding(.top, 18)
                Button(L("システム設定を開く", "Open System Settings", "打開系統設定")) { QuickLookExtension.openSettings() }
                    .padding(.top, 16)
            }
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
            Image(systemName: enabled == true ? "checkmark.circle.fill" : enabled == false ? "exclamationmark.circle.fill" : "info.circle")
                .font(.title2)
                .foregroundStyle(enabled == true ? Color.green : enabled == false ? Color.orange : Color.secondary)
            Text(enabled == true ? L("機能拡張はオンになっています。このまま使えます。", "The extension is on. You are all set.", "延伸功能已開啟，可以直接使用。")
                 : enabled == false ? L("機能拡張がオフになっています。", "The extension is turned off.", "延伸功能已關閉。")
                 : L("ふつうは最初からオンです。表示されないときは、次の手順で確かめます。", "It is normally on from the start. If nothing shows up, check it this way.", "通常一開始就是開啟的。如果沒有顯示，請依下列步驟確認。"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif

struct OnboardingView: View {
    let done: () -> Void
    @State private var page = 0
    #if os(macOS)
    @State var enabled: Bool? = nil
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Group {
                if page == 0 { IntroPage() } else { SetupPage(enabled: enabled) }
            }
            .frame(maxWidth: 400)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 40).padding(.top, 44)
            Button(action: next) {
                Text(page == 0 ? L("続ける", "Continue", "繼續") : L("始める", "Get Started", "開始使用")).frame(minWidth: 160)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 30).padding(.top, 18)
            #else
            ScrollView {
                IntroPage().frame(maxWidth: 420).padding(.horizontal, 32).padding(.top, 64).padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
            }
            Button(action: done) {
                Text(L("続ける", "Continue", "繼續")).font(.headline).frame(maxWidth: 360).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32).padding(.bottom, 28).padding(.top, 10)
            #endif
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        .task {
            let v = await Task.detached { QuickLookExtension.isEnabled() }.value
            enabled = v
        }
        // Coming back from System Settings: read the switch again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { enabled = await Task.detached { QuickLookExtension.isEnabled() }.value }
        }
        #endif
    }

    #if os(macOS)
    private func next() {
        if page == 0 { page = 1 } else { done() }
    }
    #endif
}

#if os(iOS)
/// The document browser is the app's first screen, so the welcome sheet is put on top of it once the scene is active.
enum WelcomePresenter {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard FirstLaunch.needed, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            guard FirstLaunch.needed, let scene = note.object as? UIWindowScene,
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController,
                  root.presentedViewController == nil else { return }
            let host = UIHostingController(rootView: OnboardingView(done: {
                FirstLaunch.finish()
                root.dismiss(animated: true)
            }))
            host.modalPresentationStyle = .formSheet
            host.isModalInPresentation = true
            root.present(host, animated: true)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
#endif

#if os(macOS) && NAKAMI_SELFTEST
/// Test builds only: draw the first-launch pages to PNG files (NAKAMI_WELCOME_PNG=/dir).
@MainActor func renderWelcomePages(to dir: String) {
    func save<V: View>(_ v: V, _ name: String) {
        let r = ImageRenderer(content: v.frame(width: 520, height: 560).background(Color(nsColor: .windowBackgroundColor)).tint(.accentColor))
        r.scale = 2
        if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        }
    }
    func page<V: View>(_ v: V, _ button: String) -> some View {
        VStack(spacing: 0) {
            v.frame(maxWidth: 400).frame(maxHeight: .infinity).padding(.horizontal, 40).padding(.top, 44)
            Button(action: {}) { Text(button).frame(minWidth: 160) }.controlSize(.large).buttonStyle(.borderedProminent)
                .padding(.bottom, 30).padding(.top, 18)
        }
    }
    save(page(IntroPage(), L("続ける", "Continue", "繼續")), "welcome-1")
    for (e, n) in [(Bool?.some(true), "on"), (Bool?.some(false), "off"), (Bool?.none, "unknown")] {
        save(page(SetupPage(enabled: e), L("始める", "Get Started", "開始使用")), "welcome-2-" + n)
    }
}
#endif
