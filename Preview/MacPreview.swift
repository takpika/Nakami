#if os(macOS)
import Cocoa
import Quartz
import SwiftUI

struct PreviewRoot: View {
    let report: Report
    let url: URL

    var body: some View {
        ScrollView {
            CompactReportContent(report: report)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                // The App Store build has no helper that may launch the app, so it shows no button.
                #if !MAS
                Button(L("Nakami で開く", "Open in Nakami")) { Opener.open(url) }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

@objc protocol LauncherProtocol {
    func open(_ url: URL, reply: @escaping (Bool) -> Void)
}

/// Opens the file in the main app. The extension's sandbox cannot launch apps itself,
/// so the request goes through the helper service embedded in the extension.
enum Opener {
    static func open(_ file: URL) {
        var c = URLComponents()
        c.scheme = "nakami"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: file.path)]
        guard let u = c.url else { return }
        let conn = NSXPCConnection(serviceName: "jp.takpika.Nakami.Launcher")
        conn.remoteObjectInterface = NSXPCInterface(with: LauncherProtocol.self)
        conn.resume()
        let proxy = conn.remoteObjectProxyWithErrorHandler { err in
            NSLog("Nakami: launcher unavailable: %@", "\(err)")
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
            conn.invalidate()
        } as? LauncherProtocol
        proxy?.open(u) { ok in
            if !ok { NSLog("Nakami: launcher could not open %@", u.absoluteString) }
            conn.invalidate()
        }
    }
}

final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 640))
        preferredContentSize = NSSize(width: 680, height: 640)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let report = await Task.detached(priority: .userInitiated) {
            Analyzer.analyze(url, opts: AnalyzeOptions(deep: false, budget: 1.2))
        }.value
        await MainActor.run {
            let host = NSHostingView(rootView: PreviewRoot(report: report, url: url))
            // Fixed to the panel's size: letting the hosting view report its own ideal size makes Quick Look re-lay out endlessly.
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor),
                host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }
}
#endif
