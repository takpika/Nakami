import Foundation
import CoreGraphics
import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Platform-neutral image helpers (icons are passed around as CGImage).
enum ImageKit {
    /// Decodes PNG / WebP / ICO / BMP …; for multi-image files (icons) the largest image wins.
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        var best: CGImage?
        for i in 0..<Swift.min(n, 64) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            if best == nil || img.width > best!.width { best = img }
        }
        return best
    }

    static func context(_ side: Int) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Clips a square icon to the continuous-corner shape the iOS home screen uses.
    static func squircle(_ image: CGImage, radius: CGFloat = 0.2237) -> CGImage {
        let side = Swift.min(image.width, image.height)
        guard side > 0, let ctx = context(side) else { return image }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.interpolationQuality = .high
        ctx.addPath(RoundedRectangle(cornerRadius: CGFloat(side) * radius, style: .continuous).path(in: rect).cgPath)
        ctx.clip()
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// The icon the system shows for a file (macOS only).
    static func systemIcon(_ url: URL) -> CGImage? {
        #if os(macOS)
        var r = CGRect(x: 0, y: 0, width: 256, height: 256)
        return NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &r, context: nil, hints: nil)
        #else
        return nil
        #endif
    }
}
