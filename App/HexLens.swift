import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The field of faint hex digits behind the iOS launch screen and the Mac's About window, after the app icon.
// Easter egg: pressing it brings up a magnifier, a true enlargement of the grid under it. Held over one of the
// sequences hidden in the field (NAKAMI, the app's own version, file signatures such as MZ, PK, ELF), its bytes
// turn into the characters they encode, one cell at a time.

enum HexPalette {
    #if os(macOS)
    static let baseColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1) : NSColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    }
    static let inkColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.62, green: 0.72, blue: 0.9, alpha: 1) : NSColor(red: 0.12, green: 0.2, blue: 0.4, alpha: 1)
    }
    static var base: Color { Color(nsColor: baseColor) }
    static var ink: Color { Color(nsColor: inkColor) }
    #else
    static let baseColor = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1) : UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    }
    static let inkColor = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.72, blue: 0.9, alpha: 1) : UIColor(red: 0.12, green: 0.2, blue: 0.4, alpha: 1)
    }
    static var base: Color { Color(uiColor: baseColor) }
    static var ink: Color { Color(uiColor: inkColor) }
    #endif
}

// MARK: - The grid

/// The byte grid: fixed cells, so a touch can be mapped to the bytes under it.
enum HexGrid {
    static let cell = CGSize(width: 26, height: 21)
    static let origin = CGPoint(x: 6, y: 4)
    static let font = Font.system(size: 14, design: .monospaced)

    static func cols(_ size: CGSize) -> Int { max(4, Int(size.width / cell.width) + 1) }
    static func rows(_ size: CGSize) -> Int { max(8, Int(size.height / cell.height) + 1) }
    static func center(_ r: Int, _ c: Int) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(c) + 0.5) * cell.width, y: origin.y + (CGFloat(r) + 0.5) * cell.height)
    }
    static func cellAt(_ p: CGPoint) -> (r: Int, c: Int) {
        (Int(floor((p.y - origin.y) / cell.height)), Int(floor((p.x - origin.x) / cell.width)))
    }
    static func text(_ s: String) -> Text { Text(s).font(font) }

    /// A sequence hidden in the field. Rows are given as a share of the band where the field can be seen.
    struct Word {
        let height: Double, place: Double   // both 0...1: down the band, across the row
        let bytes: [UInt8]
        func row(_ f: Field) -> Int { max(0, Int((height * f.band - origin.y) / cell.height)) }
        func col(_ f: Field) -> Int { max(0, min(f.cols - bytes.count, Int(Double(f.cols - bytes.count) * place))) }
    }

    /// The field's shape: its columns, and how tall the visible band is (the words are spread over it).
    struct Field {
        let cols: Int, band: Double
        init(size: CGSize, band: CGFloat?) { cols = HexGrid.cols(size); self.band = Double(band ?? size.height) }
    }

    static let words: [Word] = [
        Word(height: 0.35, place: 0.55, bytes: Array("NAKAMI".utf8)),
        Word(height: 0.5, place: 0.15, bytes: [0x4D, 0x5A]),                 // MZ: Windows executables
        Word(height: 0.6, place: 0.4, bytes: Array(version.utf8)),          // this build's own version
        Word(height: 0.71, place: 0.7, bytes: [0x50, 0x4B, 0x03, 0x04]),     // PK: ZIP (and so APK, IPA)
        Word(height: 0.92, place: 0.3, bytes: [0x7F, 0x45, 0x4C, 0x46]),     // ELF
    ]

    /// The running app's version, e.g. "v1.0" (read from the bundle, so it follows every release).
    static let version = "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")

    /// The character a byte encodes, if it is a printable one.
    static func character(_ b: UInt8) -> String? { (0x21...0x7E).contains(b) ? String(UnicodeScalar(b)) : nil }

    /// Deterministic bytes, the same on every launch, with the words written in.
    static func byte(_ r: Int, _ c: Int, in f: Field) -> UInt8 {
        for w in words where w.row(f) == r {
            let start = w.col(f)
            if c >= start && c < start + w.bytes.count { return w.bytes[c - start] }
        }
        var s = UInt32(truncatingIfNeeded: (r &* 7919 &+ c) &* 2654435761 &+ 12345)
        s = s &* 1664525 &+ 1013904223
        return UInt8((s >> 16) & 0xFF)
    }

    static func word(at cell: (r: Int, c: Int), in f: Field) -> Int? {
        words.firstIndex { $0.row(f) == cell.r && cell.c >= $0.col(f) && cell.c < $0.col(f) + $0.bytes.count }
    }
}

// MARK: - State

/// Where the magnifier is, and what it has found (shared by the field and the magnifier; input comes from the host).
@MainActor final class HexLens: ObservableObject {
    @Published var point: CGPoint?       // the finger (or pointer): the end of the handle
    @Published var word: Int?            // the hidden sequence being read
    @Published var revealed = 0          // how many of its cells show characters
    @Published var size: CGSize = .zero
    var flippedAt: [Int: Date] = [:]     // when each of those cells turned (for its animation)
    /// The height over which the words are spread (where the field can be seen); nil for all of it.
    let band: CGFloat?
    private var reading: Task<Void, Never>?

    init(band: CGFloat? = nil) { self.band = band }

    var field: HexGrid.Field { HexGrid.Field(size: size, band: band) }

    static let diameter: CGFloat = 132
    static let zoom: CGFloat = 1.5
    static let handle: CGFloat = 48
    /// The finger holds the end of the handle; the glass sits up and to the left, and enlarges what is under its own center.
    static func center(for p: CGPoint) -> CGPoint {
        let k = (diameter / 2 + handle) / 2.squareRoot()
        return CGPoint(x: p.x - k, y: p.y - k)
    }

    /// Whether any part of a word is still inside the glass (so what has been read stays read).
    private func inView(_ index: Int, center: CGPoint) -> Bool {
        let w = HexGrid.words[index], f = field
        let reach = Self.diameter / 2 / Self.zoom
        return (0..<w.bytes.count).contains { i in
            let m = HexGrid.center(w.row(f), w.col(f) + i)
            let nx = min(max(center.x, m.x - HexGrid.cell.width / 2), m.x + HexGrid.cell.width / 2)
            let ny = min(max(center.y, m.y - HexGrid.cell.height / 2), m.y + HexGrid.cell.height / 2)
            return hypot(nx - center.x, ny - center.y) < reach
        }
    }

    func move(to p: CGPoint) {
        let center = Self.center(for: p)
        var target = HexGrid.word(at: HexGrid.cellAt(center), in: field)
        if target == nil, let word, inView(word, center: center) { target = word }   // keep the word while it is in the glass
        if target != word {
            reading?.cancel()
            word = target
            revealed = 0
            flippedAt = [:]
            if let target {
                let count = HexGrid.words[target].bytes.count
                reading = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))   // held still for a moment
                    for i in 1...count {
                        guard !Task.isCancelled, let self else { return }
                        self.flippedAt[i - 1] = Date()
                        self.revealed = i
                        Self.tick()
                        try? await Task.sleep(for: .milliseconds(110))
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    Self.success()   // the whole word is read
                }
            }
        }
        point = p
    }

    func end() {
        reading?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { point = nil; word = nil; revealed = 0 }
    }

    #if os(macOS)
    private static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    private static func success() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    #else
    private static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    private static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    #endif
}

// MARK: - Views

struct HexField: View {
    @ObservedObject var lens: HexLens

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let f = HexGrid.Field(size: size, band: lens.band), rows = HexGrid.rows(size)
                for r in 0..<rows {
                    for c in 0..<f.cols {
                        ctx.draw(HexGrid.text(String(format: "%02X", HexGrid.byte(r, c, in: f))), at: HexGrid.center(r, c))
                    }
                }
            }
            .foregroundStyle(HexPalette.ink)
            .opacity(0.13)
            .mask(
                LinearGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white.opacity(0.7), location: 0.35),
                    .init(color: .clear, location: 0.7)
                ], startPoint: .top, endPoint: .bottom)
            )
            .onAppear { lens.size = geo.size }
            .onChange(of: geo.size) { _, s in lens.size = s }
        }
        .ignoresSafeArea()   // same coordinates as the input (and as the magnifier)
        .accessibilityHidden(true)
    }
}

struct HexMagnifier: View {
    @ObservedObject var lens: HexLens

    var body: some View {
        GeometryReader { _ in
            if let p = lens.point {
                let d = HexLens.diameter, zoom = HexLens.zoom
                let center = HexLens.center(for: p)
                ZStack {
                    Circle().fill(HexPalette.base)
                    // The field itself, enlarged around the glass's center: the same cells, darker.
                    TimelineView(.animation(paused: lens.word == nil)) { timeline in
                        Canvas { ctx, size in
                            let f = lens.field
                            ctx.translateBy(x: size.width / 2, y: size.height / 2)
                            ctx.scaleBy(x: zoom, y: zoom)
                            ctx.translateBy(x: -center.x, y: -center.y)
                            let reach = d / zoom / 2 + HexGrid.cell.width
                            let a = HexGrid.cellAt(CGPoint(x: center.x - reach, y: center.y - reach))
                            let b = HexGrid.cellAt(CGPoint(x: center.x + reach, y: center.y + reach))
                            let word = lens.word.map { HexGrid.words[$0] }
                            let ink = HexPalette.ink
                            for r in max(0, a.r)...max(0, b.r) {
                                for c in max(0, a.c)...max(0, b.c) {
                                    let m = HexGrid.center(r, c)
                                    let byte = HexGrid.byte(r, c, in: f)
                                    let hex = HexGrid.text(String(format: "%02X", byte)).foregroundStyle(ink)
                                    // A cell of the word being read: the hex shrinks away and its character pops in.
                                    if let word, word.row(f) == r, case let i = c - word.col(f), i >= 0, i < lens.revealed,
                                       let ch = HexGrid.character(byte), let at = lens.flippedAt[i] {
                                        let t = min(1, max(0, timeline.date.timeIntervalSince(at) / 0.24))
                                        if t < 1 { draw(hex, at: m, scale: 1 - 0.5 * t, opacity: 1 - t, in: &ctx) }
                                        draw(HexGrid.text(ch).fontWeight(.bold).foregroundStyle(ink), at: m, scale: 0.4 + 0.6 * overshoot(t), opacity: t, in: &ctx)
                                    } else {
                                        ctx.draw(hex, at: m)
                                    }
                                }
                            }
                        }
                    }
                    Circle().strokeBorder(HexPalette.ink, lineWidth: 5)
                }
                .frame(width: d, height: d)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .position(center)
                .background {
                    // The handle, from the rim to the finger.
                    let rim = d / 2 / 2.squareRoot()
                    Path { path in
                        path.move(to: CGPoint(x: center.x + rim, y: center.y + rim))
                        path.addLine(to: p)
                    }
                    .stroke(HexPalette.ink, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.15), value: lens.point == nil)
    }

    private func draw(_ text: Text, at p: CGPoint, scale: CGFloat, opacity: Double, in ctx: inout GraphicsContext) {
        ctx.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: p.x, y: p.y)
            layer.scaleBy(x: scale, y: scale)
            layer.draw(text, at: .zero)
        }
    }

    /// Ease out with a little overshoot, for the character popping in.
    private func overshoot(_ t: Double) -> Double {
        let s = 1.7, u = t - 1
        return 1 + (s + 1) * u * u * u + s * u * u
    }
}
