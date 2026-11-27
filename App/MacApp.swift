#if os(macOS)
import SwiftUI
import AppKit

/// Mac-only behaviour that SwiftUI scenes do not cover.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        #if NAKAMI_SELFTEST
        if let dir = ProcessInfo.processInfo.environment["NAKAMI_WELCOME_PNG"] {
            renderWelcomePages(to: dir)
            exit(0)
        }
        #endif
        NSWindow.allowsAutomaticWindowTabbing = false   // one file, one window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The system's Open Recent list (the sandbox lets the app read these files again).
struct RecentMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu(L("最近使った項目を開く", "Open Recent", "打開最近使用的項目")) {
            let urls = NSDocumentController.shared.recentDocumentURLs
            ForEach(urls, id: \.self) { u in
                Button(u.lastPathComponent) { openWindow(value: u) }
            }
            if !urls.isEmpty { Divider() }
            Button(L("メニューを消去", "Clear Menu", "清除選單")) { NSDocumentController.shared.clearRecentDocuments(nil) }
        }
    }
}

/// About Nakami: the icon, name, version and copyright over the same hex field as the iOS launch screen,
/// with its magnifier (press and drag; the pointer holds the end of the handle).
struct AboutView: View {
    @StateObject private var lens = HexLens()

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?", b = info["CFBundleVersion"] as? String ?? "?"
        return L("バージョン \(v)（\(b)）", "Version \(v) (\(b))", "版本 \(v)（\(b)）")
    }

    var body: some View {
        ZStack {
            HexPalette.base
            HexField(lens: lens)
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Nakami")
                    .font(.system(size: 26, weight: .bold))
                Text(versionLine)
                    .foregroundStyle(.secondary)
                Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
            HexMagnifier(lens: lens)
        }
        .frame(width: 420, height: 300)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { lens.move(to: $0.location) }
            .onEnded { _ in lens.end() })
        .ignoresSafeArea()
    }
}

/// The app menu's "About Nakami", opening the window above instead of the standard panel.
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L("Nakami について", "About Nakami", "關於 Nakami")) { openWindow(id: "about") }
    }
}
#endif
