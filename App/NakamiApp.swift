import SwiftUI
import UniformTypeIdentifiers

enum DocumentTypes {
    static let all: [UTType] = [
        "com.apple.application-bundle", "com.apple.itunes.ipa", "com.apple.disk-image-udif", "public.disk-image", "com.microsoft.cab", "com.vmware.vm-disk", "com.vmware.foreign.vhd", "jp.takpika.nakami.wim", "jp.takpika.nakami.msu", "jp.takpika.nakami.vdisk", "jp.takpika.nakami.floppy", "jp.takpika.nakami.rom", "jp.takpika.nakami.rom.nes", "jp.takpika.nakami.rom.gb", "jp.takpika.nakami.rom.gbc", "jp.takpika.nakami.rom.gba", "jp.takpika.nakami.rom.nds", "jp.takpika.nakami.rom.n64", "jp.takpika.nakami.rom.snes", "jp.takpika.nakami.rom.megadrive", "jp.takpika.nakami.rom.cia", "jp.takpika.nakami.rom.3dsx", "jp.takpika.nakami.rom.wbfs", "jp.takpika.nakami.rom.gcm", "jp.takpika.nakami.rom.pbp", "public.iso-image", "com.apple.itunes.ipsw", "com.android.package-archive", "com.microsoft.windows-executable", "com.microsoft.windows-dynamic-link-library",
        "com.microsoft.msi-installer", "com.apple.installer-package-archive", "com.apple.xip-archive", "jp.takpika.nakami.xar", "jp.takpika.nakami.pe", "jp.takpika.nakami.elf", "jp.takpika.nakami.archive", "jp.takpika.nakami.appx",
        "jp.takpika.nakami.msi", "com.apple.mach-o-binary", "com.apple.mach-o-dylib", "public.unix-executable", "public.object-code",
        "jp.takpika.nakami.aab", "jp.takpika.nakami.pc98disk", "com.macromedia.shockwave-flash", "com.apple.macbinary-archive", "com.apple.binhex-archive", "com.stuffit.archive.sit", "jp.takpika.nakami.cpt", "jp.takpika.nakami.classicdisk", "com.roxio.disk-image-toast", "jp.takpika.nakami.rsrc",
        "com.sun.java-archive", "com.sun.web-application-archive", "jp.takpika.nakami.deb", "jp.takpika.nakami.rpm", "jp.takpika.nakami.appimage", "jp.takpika.nakami.snap", "jp.takpika.nakami.squashfs", "jp.takpika.nakami.flatpak", "jp.takpika.nakami.flatpakref", "jp.takpika.nakami.aar", "jp.takpika.nakami.zstd",
        "public.tar-archive", "org.gnu.gnu-zip-tar-archive", "org.gnu.gnu-zip-archive", "org.tukaani.xz-archive", "public.bzip2-archive",
        "public.zip-archive", "public.data",
        // Bundles of other kinds, as listed in Info.plist (the Mac's open panel offered them before).
        "com.apple.framework", "com.apple.bundle", "com.apple.xpc-service", "com.apple.application-and-system-extension", "com.apple.plugin", "com.apple.kernel-extension",
    ].compactMap { UTType($0) }
}

@main
enum Main {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        if env["NAKAMI_FILE"] != nil || env["NAKAMI_REPORT"] != nil { NakamiDirectApp.main() } else { NakamiApp.main() }
    }
}

/// One window shows one file. A window without a file shows the welcome screen.
struct NakamiApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            FileWindow(url: $url)
        }
        #if os(macOS)
        .restorationBehavior(.disabled)   // a file from last time may no longer be readable in the sandbox (iOS: see reopen())
        .defaultWindowPlacement { content, _ in WindowPlacement(size: content.sizeThatFits(.unspecified)) }   // welcome small, files large
        .windowResizability(.contentSize)   // the welcome window keeps its size; file windows resize from their minimum
        #endif
        .commands { NakamiCommands() }
        #if os(macOS)
        Window(L("Nakami について", "About Nakami", "關於 Nakami"), id: "about") { AboutView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .restorationBehavior(.disabled)
            .commandsRemoved()
        #endif
    }
}

struct NakamiCommands: Commands {
    @FocusedValue(\.chooseFile) private var chooseFile
    @AppStorage(FirstLaunch.key) private var welcomeShown = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(L("開く…", "Open…", "打開…")) { chooseFile?() }
                .keyboardShortcut("o")
                .disabled(chooseFile == nil)
            #if os(macOS)
            RecentMenu()
            #endif
        }
        #if os(macOS)
        CommandGroup(replacing: .appInfo) { AboutButton() }
        #endif
        CommandGroup(replacing: .help) {
            Button(L("Nakami へようこそ", "Welcome to Nakami", "歡迎使用 Nakami")) { welcomeShown = false }
        }
    }
}

extension FocusedValues {
    @Entry var chooseFile: (() -> Void)? = nil
}

struct FileWindow: View {
    @Binding var url: URL?
    @State private var scoped: URL?
    @State private var choosing = false
    @AppStorage(FirstLaunch.key) private var welcomeShown = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var multipleWindows

    var body: some View {
        Group {
            if let url {
                DocumentView(url: url)
                    .id(url)
                    #if os(iOS)
                    .environment(\.closeDocument, close)   // the Mac closes the window itself
                    #endif
            } else {
                WelcomeView(open: open, choose: { choosing = true })
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: DocumentTypes.all, allowsMultipleSelection: true) { result in
            if case .success(let files) = result { open(files) }
        }
        .onOpenURL { open([$0]) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])   // files come to an open window first, not to a new one
        .focusedSceneValue(\.chooseFile) { choosing = true }
        .sheet(isPresented: Binding(get: { !welcomeShown }, set: { if !$0 { welcomeShown = true } })) {
            OnboardingView(done: { welcomeShown = true })
                .interactiveDismissDisabled()
        }
        .onAppear(perform: reopen)
        .onDisappear(perform: release)
    }

    /// The first file goes to this window (or replaces what it shows, where there is only one window); the rest get windows of their own.
    private func open(_ urls: [URL]) {
        var files = urls.compactMap(Self.file)
        guard !files.isEmpty else { return }
        #if os(macOS)
        // The Mac's welcome window is small: it gives way to full-size file windows, as before.
        if url == nil {
            let welcome = NSApp.keyWindow   // this window: open files come to the front window
            files.forEach { openWindow(value: $0) }
            DispatchQueue.main.async { welcome?.close() }
            return
        }
        #endif
        if url == nil || !multipleWindows { show(files.removeFirst()) }
        if multipleWindows { files.forEach { openWindow(value: $0) } }
    }

    /// A window opened for a file, or brought back at launch. A file from last time may no longer be readable (sandbox): then it starts empty.
    private func reopen() {
        guard let url else { return }
        access(url)
        if !FileManager.default.isReadableFile(atPath: url.path) { close() }
    }

    private func show(_ file: URL) {
        release()
        access(file)
        url = file
    }

    private func access(_ file: URL) {
        if file.startAccessingSecurityScopedResource() { scoped = file }
        Recents.add(file)
    }

    private func close() {
        release()
        url = nil
    }

    private func release() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
    }

    private static func file(_ u: URL) -> URL? {
        if u.isFileURL { return u }
        #if os(macOS) && !MAS
        // Quick Look's "Open in Nakami" passes a path (outside the sandbox only; the App Store build is handed files).
        if u.scheme == "nakami", let path = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value {
            return URL(fileURLWithPath: path)
        }
        #endif
        return nil
    }
}

/// Used by automated checks only: shows one file directly (NAKAMI_FILE=/path).
struct NakamiDirectApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                DocumentView(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["NAKAMI_FILE"] ?? ""),
                             initialSection: ProcessInfo.processInfo.environment["NAKAMI_SECTION"])
            }
        }
    }
}
