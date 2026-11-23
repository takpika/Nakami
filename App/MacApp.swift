#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct NakamiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Windows belong to documents (BinaryDocument); this scene only supplies the menus.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button(L("開く…", "Open…")) { NSDocumentController.shared.openDocument(nil) }
                        .keyboardShortcut("o")
                    RecentMenu()
                }
                CommandGroup(replacing: .appSettings) {}
            }
    }
}

struct RecentMenu: View {
    var body: some View {
        Menu(L("最近使った項目を開く", "Open Recent")) {
            let urls = NSDocumentController.shared.recentDocumentURLs
            ForEach(urls, id: \.self) { u in
                Button(u.lastPathComponent) { AppDelegate.open(u) }
            }
            if !urls.isEmpty { Divider() }
            Button(L("メニューを消去", "Clear Menu")) { NSDocumentController.shared.clearRecentDocuments(nil) }
        }
    }
}

/// One inspected item = one document = one window (title bar shows the file, no tabs).
final class BinaryDocument: NSDocument {
    override class var autosavesInPlace: Bool { false }
    override var isDocumentEdited: Bool { false }

    // Nothing is loaded here: the view analyses the file itself, memory-mapped, in the background.
    override func read(from url: URL, ofType typeName: String) throws {}

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func makeWindowControllers() {
        guard let url = fileURL else { return }
        #if NAKAMI_SELFTEST
        // Test builds only: write the report where a test can read it, to check what the sandboxed app can see.
        if ProcessInfo.processInfo.environment["NAKAMI_DUMP"] != nil {
            DispatchQueue.global().async {
                let rep = Analyzer.analyze(url, opts: AnalyzeOptions(deep: true))
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("nakami-dump-" + url.lastPathComponent + ".json")
                try? enc.encode(rep).write(to: out)
            }
        }
        #endif
        let host = NSHostingController(rootView: DocumentView(url: url))
        host.sceneBridgingOptions = [.toolbars]
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.tabbingMode = .disallowed
        w.setContentSize(NSSize(width: 980, height: 680))
        w.center()
        let wc = NSWindowController(window: w)
        wc.shouldCascadeWindows = true
        addWindowController(wc)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: NSWindow?
    private var observer: NSObjectProtocol?

    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Give documents passed at launch a moment to open before deciding to show the welcome window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            if NSDocumentController.shared.documents.isEmpty { showWelcome() }
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, w !== self.welcome, w.windowController?.document != nil else { return }
            self.welcome?.close()
            self.welcome = nil
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if u.scheme == "nakami" {
                // Opening by path only works outside the sandbox (the App Store build is handed files, never paths).
                #if !MAS
                let path = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
                if let path { AppDelegate.open(URL(fileURLWithPath: path)) }
                #endif
            } else if u.isFileURL {
                AppDelegate.open(u)
            }
        }
    }

    func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); return }
        let host = NSHostingController(rootView: WelcomeView(open: { AppDelegate.open($0) }, choose: { NSDocumentController.shared.openDocument(nil) }))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.title = "Nakami"
        w.tabbingMode = .disallowed
        w.setContentSize(NSSize(width: 460, height: 340))
        w.isReleasedWhenClosed = false
        w.center()
        welcome = w
        w.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let open: (URL) -> Void
    let choose: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(L("ここにドロップ", "Drop here"))
                .font(.title2.weight(.semibold))
            Text(L("アプリ、実行ファイル、インストーラーやパッケージの中身を調べます。\nFinder でスペースキーを押しても概要を見られます。",
                   "Inspect apps, executables, installers and packages.\nPress Space in Finder for a quick summary."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(L("選ぶ…", "Choose…"), action: choose)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(14)
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(open)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }
}
#endif
