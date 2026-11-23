import Foundation
import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// File icon for firmware images: a document page carrying the SF Symbol of the device the firmware is for.
enum DeviceIcon {
    enum Shape { case phoneHome, phoneNotch, phoneIsland, phoneFold, padHome, padFull, watch, tv, speaker, speakerMini, headset, laptop, desktop }

    /// Picks the device shape from the first supported product type ("iPhone17,3").
    static func shape(for types: [String]) -> Shape {
        guard let t = types.first else { return .phoneIsland }
        let name = DeviceNames.name(t) ?? ""
        let nums = t.drop { !$0.isNumber }.split(separator: ",").compactMap { Int($0) }
        let major = nums.first ?? 0, minor = nums.count > 1 ? nums[1] : 0
        if t.hasPrefix("iPhone") {
            if name.contains("Duo") || name.contains("Fold") { return .phoneFold }
            if name.contains("SE") || major < 10 { return .phoneHome }
            if major == 10 { return minor == 3 || minor == 6 ? .phoneNotch : .phoneHome }
            if name.hasSuffix("16e") { return .phoneNotch }
            if major <= 14 { return .phoneNotch }
            return .phoneIsland
        }
        if t.hasPrefix("iPod") { return .phoneHome }
        if t.hasPrefix("iPad") {
            // Home-button iPads: everything up to the 9th-generation iPad and the older Air / mini / Pro models.
            let full = name.contains("M1") || name.contains("M2") || name.contains("M4") || name.contains("M5") || name.contains("A16") || name.contains("A17")
                || major >= 13 || (major == 8 && name.contains("Pro"))
            return full ? .padFull : .padHome
        }
        if t.hasPrefix("Watch") { return .watch }
        if t.hasPrefix("AppleTV") { return .tv }
        if t.hasPrefix("AudioAccessory") || t.hasPrefix("HomeAccessory") { return name.contains("mini") ? .speakerMini : .speaker }
        if t.hasPrefix("RealityDevice") { return .headset }
        if types.count > 3 || name.contains("MacBook") || t.hasPrefix("MacBook") || t.hasPrefix("VirtualMac") { return .laptop }
        return .desktop
    }

    static func symbolName(_ shape: Shape) -> String {
        switch shape {
        case .phoneHome: return "iphone.gen1"
        case .phoneNotch: return "iphone.gen2"
        case .phoneIsland: return "iphone.gen3"
        case .phoneFold: return "iphone.duo"
        case .padHome: return "ipad.gen1"
        case .padFull: return "ipad.gen2"
        case .watch: return "applewatch"
        case .tv: return "appletv"
        case .speaker: return "homepod"
        case .speakerMini: return "homepodmini"
        case .headset: return "visionpro"
        case .laptop: return "macbook"
        case .desktop: return "desktopcomputer"
        }
    }

    /// An SF Symbol rendered as coverage values (255 = ink), with its pixel size.
    static func symbolMask(_ name: String, pointSize: CGFloat) -> (mask: CGImage, size: CGSize)? {
        #if os(macOS)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) else { return nil }
        var r = CGRect(origin: .zero, size: img.size)
        let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        #else
        let cg = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))?.cgImage
        #endif
        guard let cg, cg.width > 0, cg.height > 0 else { return nil }
        let w = cg.width, h = cg.height
        var alpha = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = alpha.withUnsafeMutableBytes { buf in
            guard let a = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            a.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok, let provider = CGDataProvider(data: Data(alpha) as CFData),
              let mask = CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, provider: provider, decode: [1, 0], shouldInterpolate: true) else { return nil }
        return (mask, CGSize(width: w, height: h))
    }

    /// A document page (folded corner) with a symbol in the middle and the file type underneath.
    /// `fullPage`: no margins, shadow or folded corner — a plain 3:4 page that fills the image, for thumbnails
    /// that the system frames itself.
    static func document(symbol: String?, label: String, side: Int = 512, fullPage: Bool = false) -> CGImage? {
        let k = CGFloat(side) / 512
        let made: CGContext? = fullPage
            ? CGContext(data: nil, width: side * 3 / 4, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            : ImageKit.context(side)
        guard let ctx = made else { return nil }
        ctx.scaleBy(x: k, y: k)   // drawn in a 512 × 512 space, y up
        if fullPage { ctx.translateBy(x: -64, y: 0) }   // the page spans x 64…448
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

        let L: CGFloat = fullPage ? 64 : 92, R: CGFloat = fullPage ? 448 : 420, B: CGFloat = fullPage ? 0 : 20, T: CGFloat = fullPage ? 512 : 492
        let rad: CGFloat = 26, fold: CGFloat = 96
        if fullPage {
            ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [rgb(1, 1, 1), rgb(0.94, 0.95, 0.97)] as CFArray, locations: [0, 1])!,
                                   start: CGPoint(x: 0, y: T), end: CGPoint(x: 0, y: B), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if !fullPage {
            let page = CGMutablePath()
            page.move(to: CGPoint(x: L + rad, y: B))
            page.addArc(tangent1End: CGPoint(x: R, y: B), tangent2End: CGPoint(x: R, y: T), radius: rad)
            page.addLine(to: CGPoint(x: R, y: T - fold))
            page.addLine(to: CGPoint(x: R - fold, y: T))
            page.addArc(tangent1End: CGPoint(x: L, y: T), tangent2End: CGPoint(x: L, y: B), radius: rad)
            page.addArc(tangent1End: CGPoint(x: L, y: B), tangent2End: CGPoint(x: R, y: B), radius: rad)
            page.closeSubpath()

            // Page with a soft shadow, a faint top-to-bottom shade and a hairline edge.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: rgb(0, 0, 0, 0.28))
            ctx.addPath(page); ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(page); ctx.clip()
            ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [rgb(1, 1, 1), rgb(0.93, 0.94, 0.96)] as CFArray, locations: [0, 1])!,
                                   start: CGPoint(x: 0, y: T), end: CGPoint(x: 0, y: B), options: [])
            ctx.restoreGState()
            ctx.addPath(page); ctx.setStrokeColor(rgb(0.76, 0.78, 0.82)); ctx.setLineWidth(2); ctx.strokePath()

            // Folded corner.
            let corner = CGMutablePath()
            corner.move(to: CGPoint(x: R - fold, y: T))
            corner.addArc(tangent1End: CGPoint(x: R - fold, y: T - fold), tangent2End: CGPoint(x: R, y: T - fold), radius: 16)
            corner.addLine(to: CGPoint(x: R, y: T - fold))
            corner.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: -3, height: -4), blur: 8, color: rgb(0, 0, 0, 0.20))
            ctx.addPath(corner); ctx.setFillColor(rgb(0.90, 0.91, 0.94)); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(corner); ctx.setStrokeColor(rgb(0.76, 0.78, 0.82)); ctx.setLineWidth(2); ctx.strokePath()
        }

        // Symbol, tinted with a blue gradient.
        if let symbol, let sym = symbolMask(symbol, pointSize: 200) {
            let box = CGSize(width: 214, height: 214)
            let s = Swift.min(box.width / sym.size.width, box.height / sym.size.height)
            let r = CGRect(x: (L + R) / 2 - sym.size.width * s / 2, y: 268 - sym.size.height * s / 2, width: sym.size.width * s, height: sym.size.height * s)
            ctx.saveGState()
            ctx.clip(to: r, mask: sym.mask)
            ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [rgb(0.25, 0.60, 1.0), rgb(0.10, 0.36, 0.86)] as CFArray, locations: [0, 1])!,
                                   start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
            ctx.restoreGState()
        }

        // File type along the bottom.
        var font = CTFontCreateUIFontForLanguage(.system, 58, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 58, nil)
        if let b = CTFontCreateCopyWithSymbolicTraits(font, 58, nil, .traitBold, .traitBold) { font = b }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0.56, 0.58, 0.63),
            NSAttributedString.Key(kCTKernAttributeName as String): 3.0,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: (L + R) / 2 - w / 2 + 1.5, y: 64)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    static func firmware(types: [String], side: Int = 512) -> CGImage? {
        document(symbol: symbolName(shape(for: types)), label: "IPSW", side: side)
    }
}
