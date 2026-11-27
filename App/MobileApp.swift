#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The document handed over by the Files app. Nothing is read here: the view analyses the file itself, memory-mapped.
struct BinaryFile: FileDocument {
    static var readableContentTypes: [UTType] { DocumentTypes.all }
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { throw CocoaError(.fileWriteNoPermission) }
}

enum DocumentTypes {
    static let all: [UTType] = [
        "com.apple.application-bundle", "com.apple.itunes.ipa", "com.apple.disk-image-udif", "public.disk-image", "com.microsoft.cab", "com.vmware.vm-disk", "com.vmware.foreign.vhd", "jp.takpika.nakami.wim", "jp.takpika.nakami.msu", "jp.takpika.nakami.vdisk", "jp.takpika.nakami.floppy", "jp.takpika.nakami.rom", "jp.takpika.nakami.rom.nes", "jp.takpika.nakami.rom.gb", "jp.takpika.nakami.rom.gbc", "jp.takpika.nakami.rom.gba", "jp.takpika.nakami.rom.nds", "jp.takpika.nakami.rom.n64", "jp.takpika.nakami.rom.snes", "jp.takpika.nakami.rom.megadrive", "jp.takpika.nakami.rom.cia", "jp.takpika.nakami.rom.3dsx", "jp.takpika.nakami.rom.wbfs", "jp.takpika.nakami.rom.gcm", "jp.takpika.nakami.rom.pbp", "public.iso-image", "com.apple.itunes.ipsw", "com.android.package-archive", "com.microsoft.windows-executable", "com.microsoft.windows-dynamic-link-library",
        "com.microsoft.msi-installer", "com.apple.installer-package-archive", "com.apple.xip-archive", "jp.takpika.nakami.xar", "jp.takpika.nakami.pe", "jp.takpika.nakami.elf", "jp.takpika.nakami.archive", "jp.takpika.nakami.appx",
        "jp.takpika.nakami.msi", "com.apple.mach-o-binary", "com.apple.mach-o-dylib", "public.unix-executable", "public.object-code",
        "jp.takpika.nakami.aab", "jp.takpika.nakami.pc98disk", "com.macromedia.shockwave-flash", "com.apple.macbinary-archive", "com.apple.binhex-archive", "com.stuffit.archive.sit", "jp.takpika.nakami.cpt", "jp.takpika.nakami.classicdisk", "com.roxio.disk-image-toast", "jp.takpika.nakami.rsrc",
        "com.sun.java-archive", "com.sun.web-application-archive", "jp.takpika.nakami.deb", "jp.takpika.nakami.rpm", "jp.takpika.nakami.appimage", "jp.takpika.nakami.snap", "jp.takpika.nakami.squashfs", "jp.takpika.nakami.flatpak", "jp.takpika.nakami.flatpakref", "jp.takpika.nakami.aar", "jp.takpika.nakami.zstd",
        "public.tar-archive", "org.gnu.gnu-zip-tar-archive", "org.gnu.gnu-zip-archive", "org.tukaani.xz-archive", "public.bzip2-archive",
        "public.zip-archive", "public.data",
    ].compactMap { UTType($0) }
}

struct NakamiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() { WelcomePresenter.install() }

    var body: some Scene {
        // Document-based: the Files browser is the launch screen and each open file gets its own scene.
        DocumentGroup(viewing: BinaryFile.self) { file in
            if let url = file.fileURL {
                DocumentView(url: url)
            } else {
                ContentUnavailableView(L("ファイルを開けません", "Cannot open the file"), systemImage: "exclamationmark.triangle")
            }
        }
    }
}

/// While the app is running, DocumentGroup ignores a file handed over by another app (Files' "Open in Nakami").
/// The file is given to the system document browser as if it had been picked there, after closing the open one.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = HandOverSceneDelegate.self
        return config
    }
}

final class HandOverSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.first?.url, let root = (scene as? UIWindowScene)?.windows.first?.rootViewController else { return }
        if let open = root.children.first as? UIDocumentViewController, open.document != nil { open.document = nil }
        pick(url, in: root, triesLeft: 30)
    }

    /// Waits (up to 3 s) for the browser to be back on screen with no transition running.
    private func pick(_ url: URL, in root: UIViewController, triesLeft: Int) {
        if let browser = Self.browser(in: root), browser.viewIfLoaded?.window != nil, root.transitionCoordinator == nil {
            browser.delegate?.documentBrowser?(browser, didPickDocumentsAt: [url])
        } else if triesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.pick(url, in: root, triesLeft: triesLeft - 1) }
        }
    }

    private static func browser(in vc: UIViewController) -> UIDocumentBrowserViewController? {
        (vc as? UIDocumentBrowserViewController) ?? (vc.children + [vc.presentedViewController].compactMap { $0 }).lazy.compactMap(browser).first
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

@main
enum Main {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        if env["NAKAMI_FILE"] != nil || env["NAKAMI_REPORT"] != nil { NakamiDirectApp.main() } else { NakamiMobileApp.main() }
    }
}
#endif
