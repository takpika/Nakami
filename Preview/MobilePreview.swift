#if os(iOS)
import UIKit
import QuickLook
import SwiftUI

/// Quick Look preview in the Files app: the same one-page summary as on the Mac.
final class PreviewViewController: UIViewController, QLPreviewingController {
    func preparePreviewOfFile(at url: URL) async throws {
        let report = await Task.detached(priority: .userInitiated) { () -> Report in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return Analyzer.analyze(url, opts: AnalyzeOptions(deep: false, budget: 1.2))
        }.value
        await MainActor.run {
            let host = UIHostingController(rootView: ScrollView { CompactReportContent(report: report) })
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
        }
    }
}
#endif
