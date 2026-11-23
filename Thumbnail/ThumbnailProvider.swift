import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// Finder / Files icons for exe, msi, ipa, apk and appx/msix files: the program's own icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = ThumbnailProvider.icon(at: url) else {
            handler(nil, CocoaError(.fileReadUnknown))
            return
        }
        // Square for app icons; page-shaped (3:4) for document-style thumbnails, so the page fills the
        // whole thumbnail and the system frames it like any other document.
        let fit = min(request.maximumSize.width / CGFloat(image.width), request.maximumSize.height / CGFloat(image.height))
        let size = CGSize(width: (CGFloat(image.width) * fit).rounded(), height: (CGFloat(image.height) * fit).rounded())
        handler(QLThumbnailReply(contextSize: size) { (ctx: CGContext) -> Bool in
            // The context is in points on some systems and in pixels on others (iOS hands over
            // size × scale pixels with no transform), so fill whatever area it actually covers.
            let full = ctx.boundingBoxOfClipPath
            let k = min(full.width / CGFloat(image.width), full.height / CGFloat(image.height))
            let rect = CGRect(x: full.midX - CGFloat(image.width) * k / 2, y: full.midY - CGFloat(image.height) * k / 2,
                              width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
            let device = ctx.convertToDeviceSpace(rect)
            // Small pixel-art icons stay crisp; everything else is smoothed.
            ctx.interpolationQuality = CGFloat(image.width) * 2 < device.width ? .none : .high
            ctx.draw(image, in: rect)
            return true
        }, nil)
    }

    static func icon(at url: URL) -> CGImage? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // An .app bundle (a folder): its icon files are read straight from disk.
            return Zip(directory: url, limit: 20_000).flatMap { IPA.icon($0) }
        }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return icon(data)
    }

    static func icon(_ data: Data) -> CGImage? {
        let r = Reader(data)
        if let pe = PEFile(data) { return pe.iconData(pe.resources()).flatMap { MSI.image($0) } }
        if CompoundFile.isCFB(r) { return MSI.icon(data) }
        guard Zip.isZip(r), let zip = Zip(data) else {
            // Optical disc images keep the system's own icon (only game discs show their cover icon);
            // what is inside is shown in the preview instead.
            let isISO = r.fixedStr(32769, 5) == "CD001" || r.fixedStr(37633, 5) == "CD001"
            if ELF.isELF(r) { return AppImage.icon(data) }
            if RPM.isRPM(r) { return RPM.icon(data) }
            if Snap.isSquash(r) { return Snap.icon(data) }
            if r.fixedStr(0, 8) == "!<arch>\n" { return Deb.icon(data) }
            return Console.icon(data) ?? (isISO ? nil : DiskImage.icon(data)) ?? Flatpak.icon(data) ?? ClassicMac.icon(data, name: "") ?? ClassicMac.Resources(data).flatMap { ClassicMac.bundleIcon($0, type: "APPL") }
        }
        return IPSW.thumbnail(zip) ?? IPA.icon(zip) ?? APK.icon(zip) ?? AAB.icon(zip) ?? Appx.icon(zip) ?? JAR.icon(zip)
    }
}
