import Foundation
import CoreSpotlight

/// Spotlight import extension. Apple's documentation says these do nothing on macOS, and on this Mac
/// (macOS 27.3) neither this nor a classic .mdimporter plug-in was ever called by Spotlight, although
/// `mdimport -e` lists the extension. It is kept for iOS / iPadOS, where the mechanism is supported.
final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let info = SpotlightInfo(url: url) else { return }
        attributes.title = info.title
        attributes.kind = info.kind
        attributes.contentDescription = info.summary
        attributes.version = info.version
        attributes.identifier = info.identifier
        attributes.publishers = info.publisher.map { [$0] }
        attributes.copyright = info.copyright
        if !info.keywords.isEmpty { attributes.keywords = info.keywords }
        attributes.comment = info.comment
    }
}
