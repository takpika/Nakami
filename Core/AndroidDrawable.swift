import Foundation
import CoreGraphics
import SwiftUI

/// Renders Android adaptive icons (background + foreground layers) whose layers are colors,
/// bitmaps or vector drawables. Enough for launcher icons; not a general drawable renderer.
struct AndroidDrawable {
    let zip: Zip
    let arsc: ARSC?

    // MARK: Attribute values

    func number(_ v: AXML.Value?, depth: Int = 0) -> CGFloat? {
        guard let v else { return nil }
        switch v.type {
        case 4: return CGFloat(Float(bitPattern: v.data))
        case 0x10, 0x11: return CGFloat(Int32(bitPattern: v.data))
        case 5:  // dimension: 24-bit mantissa with a radix selector
            let radix = [1.0 / 256, 1.0 / 32768, 1.0 / 8_388_608, 1.0 / 2_147_483_648][Int((v.data >> 4) & 3)]
            return CGFloat(Double(Int32(bitPattern: v.data & 0xffff_ff00)) * radix)
        case 1:
            guard depth < 4, let h = arsc?.lookup(v.data).first else { return nil }
            return number(AXML.Value(type: h.type, data: h.data, string: h.string), depth: depth + 1)
        default: return v.string.flatMap { Double($0) }.map { CGFloat($0) }
        }
    }

    func color(_ v: AXML.Value?, depth: Int = 0) -> CGColor? {
        guard let v else { return nil }
        switch v.type {
        case 0x1c, 0x1d, 0x1e, 0x1f:
            let d = v.data
            return CGColor(srgbRed: CGFloat((d >> 16) & 0xff) / 255, green: CGFloat((d >> 8) & 0xff) / 255, blue: CGFloat(d & 0xff) / 255, alpha: CGFloat(d >> 24) / 255)
        case 1:
            guard depth < 4, let hits = arsc?.lookup(v.data) else { return nil }
            for h in hits { if let c = color(AXML.Value(type: h.type, data: h.data, string: h.string), depth: depth + 1) { return c } }
            return nil
        default:
            guard var s = v.string, s.hasPrefix("#") else { return nil }
            s.removeFirst()
            if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
            guard var n = UInt32(s, radix: 16) else { return nil }
            if s.count == 6 { n |= 0xff00_0000 }
            return color(AXML.Value(type: 0x1c, data: n, string: nil))
        }
    }

    // MARK: Layers

    /// Draws one drawable reference into `rect` (y-down coordinates).
    func draw(_ v: AXML.Value?, in rect: CGRect, ctx: CGContext, depth: Int = 0) -> Bool {
        guard let v, depth < 5 else { return false }
        if let c = v.type != 1 ? color(v) : nil {
            ctx.setFillColor(c); ctx.fill(rect)
            return true
        }
        var paths = [(String, Int)]()
        if v.type == 1 {
            let hits = arsc?.lookup(v.data) ?? []
            for h in hits where h.type >= 0x1c && h.type <= 0x1f {
                return draw(AXML.Value(type: h.type, data: h.data, string: nil), in: rect, ctx: ctx, depth: depth + 1)
            }
            paths = hits.compactMap { h in h.string.map { ($0, h.density >= 0xfffe ? 0 : h.density) } }
        } else if let s = v.string {
            paths = [(s, 0)]
        }
        // Bitmaps first (highest density), then XML drawables.
        for (p, _) in paths.filter({ !$0.0.hasSuffix(".xml") }).sorted(by: { $0.1 > $1.1 }) {
            guard let d = zip.read(p, max: 8 << 20), let cg = ImageKit.decode(d) else { continue }
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
            return true
        }
        for (p, _) in paths where p.hasSuffix(".xml") {
            guard let d = zip.read(p, max: 4 << 20), let x = AXML(d) ?? AXML(proto: d), let root = x.elements.first else { continue }
            if drawXML(x, root: root, in: rect, ctx: ctx, depth: depth) { return true }
        }
        return false
    }

    func drawXML(_ x: AXML, root: AXML.Element, in rect: CGRect, ctx: CGContext, depth: Int) -> Bool {
        switch root.name {
        case "vector": return drawVector(x, in: rect, ctx: ctx)
        case "adaptive-icon":
            var any = false
            for layer in ["background", "foreground"] {
                if let e = x.elements.first(where: { $0.name == layer }), draw(e.attrs["drawable"], in: rect, ctx: ctx, depth: depth + 1) { any = true }
            }
            return any
        case "layer-list":
            var any = false
            for e in x.elements where e.name == "item" { if draw(e.attrs["drawable"], in: rect, ctx: ctx, depth: depth + 1) { any = true } }
            return any
        case "inset":
            let all = number(root.attrs["inset"]) ?? 0
            let total = Swift.max(rect.width, 1)
            func frac(_ k: String) -> CGFloat { let v = number(root.attrs[k]) ?? all; return v < 1 ? v : v / 108 }
            let r = CGRect(x: rect.minX + frac("insetLeft") * total, y: rect.minY + frac("insetTop") * total,
                           width: total * (1 - frac("insetLeft") - frac("insetRight")), height: rect.height * (1 - frac("insetTop") - frac("insetBottom")))
            return draw(root.attrs["drawable"], in: r, ctx: ctx, depth: depth + 1)
        case "bitmap": return draw(root.attrs["src"], in: rect, ctx: ctx, depth: depth + 1)
        case "shape", "color":
            let solid = x.elements.first { $0.name == "solid" }
            guard let c = color(solid?.attrs["color"] ?? root.attrs["color"]) else { return false }
            ctx.setFillColor(c); ctx.fill(rect)
            return true
        default: return false
        }
    }

    func drawVector(_ x: AXML, in rect: CGRect, ctx: CGContext) -> Bool {
        guard let root = x.elements.first else { return false }
        let vw = number(root.attrs["viewportWidth"]) ?? 24, vh = number(root.attrs["viewportHeight"]) ?? 24
        guard vw > 0, vh > 0 else { return false }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / vw, y: rect.height / vh)
        let rootAlpha = number(root.attrs["alpha"]) ?? 1
        var open = [Int]()  // depths of groups whose graphics state is saved
        var drew = false
        for e in x.elements.dropFirst() {
            while let last = open.last, last >= e.depth { ctx.restoreGState(); open.removeLast() }
            if e.name == "group" {
                ctx.saveGState()
                open.append(e.depth)
                let px = number(e.attrs["pivotX"]) ?? 0, py = number(e.attrs["pivotY"]) ?? 0
                ctx.translateBy(x: (number(e.attrs["translateX"]) ?? 0) + px, y: (number(e.attrs["translateY"]) ?? 0) + py)
                ctx.rotate(by: (number(e.attrs["rotation"]) ?? 0) * .pi / 180)
                ctx.scaleBy(x: number(e.attrs["scaleX"]) ?? 1, y: number(e.attrs["scaleY"]) ?? 1)
                ctx.translateBy(x: -px, y: -py)
            } else if e.name == "path" || e.name == "clip-path", let dstr = e.attrs["pathData"]?.string {
                let path = SVGPath.parse(dstr)
                if e.name == "clip-path" { ctx.addPath(path); ctx.clip(); continue }
                let evenOdd = (number(e.attrs["fillType"]) ?? 0) == 1
                if let c = color(e.attrs["fillColor"]) {
                    ctx.addPath(path)
                    ctx.setFillColor(c.copy(alpha: c.alpha * (number(e.attrs["fillAlpha"]) ?? 1) * rootAlpha) ?? c)
                    ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
                    drew = true
                }
                if let c = color(e.attrs["strokeColor"]), let w = number(e.attrs["strokeWidth"]), w > 0 {
                    ctx.addPath(path)
                    ctx.setStrokeColor(c.copy(alpha: c.alpha * (number(e.attrs["strokeAlpha"]) ?? 1) * rootAlpha) ?? c)
                    ctx.setLineWidth(w)
                    ctx.setLineCap([CGLineCap.butt, .round, .square][Int(number(e.attrs["strokeLineCap"]) ?? 0) % 3])
                    ctx.setLineJoin([CGLineJoin.miter, .round, .bevel][Int(number(e.attrs["strokeLineJoin"]) ?? 0) % 3])
                    ctx.strokePath()
                    drew = true
                }
            }
        }
        for _ in open { ctx.restoreGState() }
        ctx.restoreGState()
        return drew
    }

    /// An adaptive icon: 108×108 layers of which the centre 72×72 is visible, clipped to a rounded square.
    func adaptiveIcon(xmlPath: String, side: Int = 512) -> CGImage? {
        guard let d = zip.read(xmlPath, max: 4 << 20), let x = AXML(d) ?? AXML(proto: d), let root = x.elements.first, let ctx = ImageKit.context(side) else { return nil }
        let s = CGFloat(side)
        ctx.translateBy(x: 0, y: s)
        ctx.scaleBy(x: 1, y: -1)  // Android coordinates: y grows downwards
        let adaptive = root.name == "adaptive-icon"
        let full = adaptive ? CGRect(x: -s * 0.25, y: -s * 0.25, width: s * 1.5, height: s * 1.5) : CGRect(x: 0, y: 0, width: s, height: s)
        if adaptive {
            ctx.addPath(RoundedRectangle(cornerRadius: s * 0.22, style: .continuous).path(in: CGRect(x: 0, y: 0, width: s, height: s)).cgPath)
            ctx.clip()
        }
        guard drawXML(x, root: root, in: full, ctx: ctx, depth: 0) else { return nil }
        return ctx.makeImage()
    }
}

/// SVG / Android `pathData` parser.
enum SVGPath {
    static func parse(_ s: String) -> CGPath {
        let path = CGMutablePath()
        let u = Array(s.utf8)
        var i = 0
        func skip() { while i < u.count, u[i] == 0x20 || u[i] == 0x2c || u[i] == 0x0a || u[i] == 0x09 || u[i] == 0x0d { i += 1 } }
        func num() -> CGFloat? {
            skip()
            let st = i
            if i < u.count, u[i] == 0x2d || u[i] == 0x2b { i += 1 }
            var dot = false
            while i < u.count {
                let c = u[i]
                if c >= 0x30 && c <= 0x39 { i += 1 }
                else if c == 0x2e, !dot { dot = true; i += 1 }
                else if c == 0x65 || c == 0x45 {
                    i += 1
                    if i < u.count, u[i] == 0x2d || u[i] == 0x2b { i += 1 }
                } else { break }
            }
            guard i > st, let d = Double(String(decoding: u[st..<i], as: UTF8.self)) else { return nil }
            return CGFloat(d)
        }
        func flag() -> Bool? {
            skip()
            guard i < u.count, u[i] == 0x30 || u[i] == 0x31 else { return nil }
            i += 1
            return u[i - 1] == 0x31
        }
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?
        var lastCmd: UInt8 = 0
        var cmd: UInt8 = 0
        var guardN = 0
        while i < u.count, guardN < 200_000 {
            guardN += 1
            skip()
            guard i < u.count else { break }
            let c = u[i]
            if (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) { cmd = c; i += 1 }
            else if cmd == 0 { break }
            else if cmd == 0x4d { cmd = 0x4c } else if cmd == 0x6d { cmd = 0x6c }  // implicit lineto after moveto
            let rel = cmd >= 0x61
            func pt() -> CGPoint? {
                guard let x = num(), let y = num() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            var ctrl: CGPoint?
            switch cmd | 0x20 {
            case 0x6d:  // m
                guard let p = pt() else { return path }
                path.move(to: p); cur = p; start = p
            case 0x6c:  // l
                guard let p = pt() else { return path }
                path.addLine(to: p); cur = p
            case 0x68:  // h
                guard let x = num() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case 0x76:  // v
                guard let y = num() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case 0x63:  // c
                guard let a = pt(), let b = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: a, control2: b); ctrl = b; cur = p
            case 0x73:  // s
                guard let b = pt(), let p = pt() else { return path }
                let prev = [0x63, 0x73].contains(lastCmd | 0x20) ? lastCtrl : nil
                let a = prev.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addCurve(to: p, control1: a, control2: b); ctrl = b; cur = p
            case 0x71:  // q
                guard let a = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, control: a); ctrl = a; cur = p
            case 0x74:  // t
                guard let p = pt() else { return path }
                let prev = [0x71, 0x74].contains(lastCmd | 0x20) ? lastCtrl : nil
                let a = prev.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                path.addQuadCurve(to: p, control: a); ctrl = a; cur = p
            case 0x61:  // a
                guard let rx = num(), let ry = num(), let rot = num(), let large = flag(), let sweep = flag(), let p = pt() else { return path }
                arc(path, from: cur, to: p, rx: abs(rx), ry: abs(ry), rotation: rot * .pi / 180, large: large, sweep: sweep)
                cur = p
            case 0x7a:  // z
                path.closeSubpath(); cur = start
            default: return path
            }
            lastCtrl = ctrl
            lastCmd = cmd
        }
        return path
    }

    /// Endpoint-parameterised elliptical arc → cubic Béziers (SVG implementation notes, F.6.5).
    static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation phi: CGFloat, large: Bool, sweep: Bool) {
        guard rx0 > 0, ry0 > 0, p0 != p1 else { path.addLine(to: p1); return }
        var rx = rx0, ry = ry0
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lam = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lam > 1 { rx *= sqrt(lam); ry *= sqrt(lam) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var co = den == 0 ? 0 : sqrt(Swift.max(0, num / den))
        if large == sweep { co = -co }
        let cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2, cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let th1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dth = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, dth > 0 { dth -= 2 * .pi } else if sweep, dth < 0 { dth += 2 * .pi }
        let segs = Swift.max(1, Int(ceil(abs(dth) / (.pi / 2))))
        let step = dth / CGFloat(segs)
        let t = 4 / 3 * tan(step / 4)
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        var a = th1
        for _ in 0..<segs {
            let b = a + step
            let pa = point(a), pb = point(b), da = deriv(a), db = deriv(b)
            path.addCurve(to: pb, control1: CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y), control2: CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y))
            a = b
        }
    }
}
