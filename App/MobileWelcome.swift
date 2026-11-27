#if os(iOS)
import SwiftUI

/// The iOS welcome screen (a window with no file): the Mac window's dashed drop area, and the Files app's browser
/// below it (portrait) or beside it (landscape). Dashed outline = "closed, not yet opened".
struct MobileWelcome: View {
    let open: ([URL]) -> Void
    let choose: () -> Void
    @State private var targeted = false

    var body: some View {
        GeometryReader { geo in
            let layout = geo.size.width > geo.size.height ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                WelcomeDropArea(targeted: targeted, choose: choose)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !urls.isEmpty else { return false }
                        open(urls)
                        return true
                    } isTargeted: { targeted = $0 }
                // Recent files, browsing and search: the Files app's own browser (portrait: lower half, landscape: right half).
                FilesBrowser(open: open)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct WelcomeDropArea: View {
    let targeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: targeted ? "shippingbox.fill" : "shippingbox")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("Nakami")
                .font(.largeTitle.weight(.semibold))
            Text(L("アプリやインストーラーの中身を、実行せずに確認します。",
                   "See what is inside an app or installer without running it.",
                   "不執行即可查看應用程式或安裝檔的內容。"))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: choose) {
                Text(L("選ぶ…", "Choose…", "選擇…"))
                    .font(.headline)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 6)
            Text(L("他の App の共有シートからも開けます。",
                   "You can also open files from another app's Share sheet.",
                   "也可從其他 App 的分享選單開啟。"))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.1) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color(.separator),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [7, 6]))
        )
        .accessibilityElement(children: .contain)
    }
}

#endif

#if os(iOS)
/// The Files app's own browser (recents, browse, search), embedded as the welcome screen. Picking a file opens it here.
struct FilesBrowser: UIViewControllerRepresentable {
    let open: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: DocumentTypes.all)
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = true
        browser.delegate = context.coordinator
        return browser
    }

    func updateUIViewController(_ browser: UIDocumentBrowserViewController, context: Context) {
        context.coordinator.open = open
    }

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        var open: ([URL]) -> Void
        var look: AnyObject?   // drives the launch screen's magnifier
        init(open: @escaping ([URL]) -> Void) { self.open = open }
        func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) { open(urls) }
    }
}
#endif

#if os(iOS)
/// The system's document launch screen (as in Preview): the title on top, the Files browser below.
/// No "choose" button: the browser is right there (⌘O still opens the picker).
/// Shown by a document view controller that has no document; picks from its browser come back to `open`.
@available(iOS 18.0, *)
struct LaunchScreen: UIViewControllerRepresentable {
    let open: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentViewController {
        let controller = UIDocumentViewController()
        let browser = UIDocumentBrowserViewController(forOpening: DocumentTypes.all)
        browser.allowsDocumentCreation = false
        browser.delegate = context.coordinator
        let options = controller.launchOptions
        options.browserViewController = browser
        options.title = "Nakami"
        if #available(iOS 27.0, *) {
            options.subtitle = L("中身を、開かずに見る。", "Look inside, without opening.", "不開啟，直接看內容。")
        }
        context.coordinator.look = LaunchLook.apply(to: options, in: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentViewController, context: Context) {
        context.coordinator.open = open
    }

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        var open: ([URL]) -> Void
        var look: AnyObject?   // drives the launch screen's magnifier
        init(open: @escaping ([URL]) -> Void) { self.open = open }
        func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt urls: [URL]) { open(urls) }
    }
}
#endif
