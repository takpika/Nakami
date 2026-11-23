import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .info: return .blue
        case .neutral: return .secondary
        }
    }
}

/// Wrapping horizontal layout for badges.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map { $0.width }.max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat, y: CGFloat)] {
        var rows = [(items: [Int], width: CGFloat, height: CGFloat, y: CGFloat)]()
        var cur = (items: [Int](), width: CGFloat(0), height: CGFloat(0), y: CGFloat(0))
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let w = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if w > maxWidth, !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height, cur.y + cur.height + spacing)
            } else {
                cur.items.append(i)
                cur.width = w
                cur.height = max(cur.height, s.height)
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}

struct BadgeView: View {
    let badge: Badge
    var body: some View {
        Text(badge.text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(badge.tone == .neutral ? Color.primary.opacity(0.75) : badge.tone.color)
            .background((badge.tone == .neutral ? Color.secondary : badge.tone.color).opacity(0.14), in: Capsule())
    }
}

/// Plays an icon's frames in a loop, each for its own duration.
struct AnimatedIcon: View {
    let frames: [IconFrame]
    private let start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Image(decorative: frame(at: context.date.timeIntervalSince(start)), scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        }
    }

    private func frame(at elapsed: TimeInterval) -> CGImage {
        let total = frames.reduce(0) { $0 + $1.duration }
        var t = total > 0 ? elapsed.truncatingRemainder(dividingBy: total) : 0
        for f in frames {
            if t < f.duration { return f.image }
            t -= f.duration
        }
        return frames[0].image
    }
}

struct HeaderView: View {
    let report: Report
    var iconSize: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if report.iconFrames.count > 1 {
                AnimatedIcon(frames: report.iconFrames)
                    .frame(width: iconSize, height: iconSize)
            } else if let icon = report.icon {
                Image(decorative: icon, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(report.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(report.subtitle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !report.badges.isEmpty {
                    FlowLayout {
                        ForEach(report.badges, id: \.self) { BadgeView(badge: $0) }
                    }
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct RowsView: View {
    let rows: [Row]
    var selectable = true
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var keyWidth: CGFloat { sizeClass == .compact ? 110 : 190 }
    #else
    private let keyWidth: CGFloat = 190
    #endif

    var body: some View {
        let symbols = rows.contains { $0.symbol != nil }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: symbols ? 9 : 6) {
            ForEach(rows) { row in
                GridRow {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.key)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)   // long names wrap instead of being cut ("アーキテク…")
                        if symbols {
                            // Keys are right-aligned, so the symbols line up in a column of their own.
                            Image(systemName: row.symbol ?? "circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(row.tone == .neutral ? Color.accentColor : row.tone.color)
                                .opacity(row.symbol == nil ? 0 : 1)
                                .frame(width: 20)
                        }
                    }
                    .gridColumnAlignment(.trailing)
                    .frame(maxWidth: keyWidth + (symbols ? 28 : 0), alignment: .trailing)
                    value(row)
                }
            }
        }
    }

    @ViewBuilder private func value(_ row: Row) -> some View {
        let t = Text(row.value)
            .font(row.mono ? .system(.callout, design: .monospaced) : .body)
            .foregroundStyle(row.tone == .neutral ? Color.primary : row.tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if selectable { t.textSelection(.enabled) } else { t }
    }
}

/// Static grid table: used in Quick Look, in rendered images and for small tables in the app.
struct GridTableView: View {
    let table: TableData
    var limit: Int = .max
    var selectable = true

    var body: some View {
        let shown = Array(table.rows.prefix(limit))
        let total = table.total ?? table.rows.count
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, c in
                        Text(c).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                    GridRow {
                        ForEach(Array(table.columns.indices), id: \.self) { i in
                            cell(r[safe: i] ?? "")
                        }
                    }
                }
            }
            if total > shown.count {
                Text(L("ほか \(total - shown.count) 件", "\(total - shown.count) more"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func cell(_ s: String) -> some View {
        let t = Text(s).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(s.contains("/") ? .head : .tail)
        if selectable { t.textSelection(.enabled) } else { t }
    }
}

struct BlockView: View {
    let block: Block
    var tableLimit: Int = .max
    var selectable = true

    var body: some View {
        switch block {
        case .rows(let rows): RowsView(rows: rows, selectable: selectable)
        case .table(let t): GridTableView(table: t, limit: tableLimit, selectable: selectable)
        case .heading(let h): Text(h).font(.subheadline.weight(.semibold)).padding(.top, 6)
        case .note(let n):
            Label(n, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .text(let s):
            let lines = s.components(separatedBy: "\n")
            let cut = tableLimit == .max ? lines : Array(lines.prefix(tableLimit * 2))
            Text(cut.joined(separator: "\n") + (cut.count < lines.count ? "\n…" : ""))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct SectionTitle: View {
    let section: ReportSection
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: section.symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(section.title).font(.headline)
            if let c = section.count {
                Text("\(c)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
            }
        }
    }
}

/// One-page summary: header, key facts, then every section with its tables cut short.
/// Used for the Quick Look preview and for rendered images.
struct CompactReportContent: View {
    let report: Report
    var tableLimit = 8
    var selectable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(report: report)
            if !report.summary.isEmpty {
                RowsView(rows: report.summary, selectable: selectable)
            }
            ForEach(report.sections) { s in
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(section: s)
                    ForEach(Array(s.blocks.enumerated()), id: \.offset) { _, b in
                        BlockView(block: b, tableLimit: tableLimit, selectable: selectable)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
@MainActor
func renderPNG(_ report: Report, to url: URL, width: Double, dark: Bool = false) {
    let view = CompactReportContent(report: report, selectable: false)
        .frame(width: width)
        .background(dark ? Color(white: 0.12) : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        return
    }
    try? png.write(to: url)
}
#endif
