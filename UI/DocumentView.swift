import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TableRowItem: Identifiable {
    let id: Int
    let cells: [String]
}

func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

/// Full table with every row: a real multi-column table on the Mac and on wide iPad windows,
/// a list of stacked rows on narrow screens.
struct FullTableView: View {
    let table: TableData
    let filter: String
    @State private var selection = Set<Int>()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var rows: [TableRowItem] {
        let all = table.rows.enumerated().map { TableRowItem(id: $0.offset, cells: $0.element) }
        guard !filter.isEmpty else { return all }
        return all.filter { r in r.cells.contains { $0.localizedCaseInsensitiveContains(filter) } }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            content(rows)
            HStack {
                let total = table.total ?? table.rows.count
                Text(filter.isEmpty ? L("\(rows.count) 件", "\(rows.count) items", "\(rows.count) 個項目") : L("\(rows.count) / \(table.rows.count) 件", "\(rows.count) of \(table.rows.count)", "\(rows.count) / \(table.rows.count) 個項目"))
                if total > table.rows.count {
                    Text(L("（全 \(total) 件のうち先頭 \(table.rows.count) 件を表示）", "(first \(table.rows.count) of \(total))", "（共 \(total) 個項目，顯示前 \(table.rows.count) 個）"))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }

    @ViewBuilder private func content(_ rows: [TableRowItem]) -> some View {
        #if os(macOS)
        wide(rows)
            .onCopyCommand {
                let text = rows.filter { selection.contains($0.id) }.map { $0.cells.joined(separator: "\t") }.joined(separator: "\n")
                return [NSItemProvider(object: text as NSString)]
            }
        #else
        if sizeClass == .regular && table.columns.count > 1 { wide(rows) } else { stacked(rows) }
        #endif
    }

    private func wide(_ rows: [TableRowItem]) -> some View {
        Table(rows, selection: $selection) {
            TableColumnForEach(Array(table.columns.enumerated()), id: \.offset) { col in
                TableColumn(col.element) { (row: TableRowItem) in
                    let s = row.cells[safe: col.offset] ?? ""
                    Text(s)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        #if os(macOS)
                        .help(s)
                        #endif
                }
            }
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            Button(L("コピー", "Copy")) {
                copyToPasteboard(rows.filter { ids.contains($0.id) }.map { $0.cells.joined(separator: "\t") }.joined(separator: "\n"))
            }
        }
    }

    /// Narrow layout: first column as the title, the remaining columns as labelled lines below it.
    private func stacked(_ rows: [TableRowItem]) -> some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 3) {
                Text(row.cells.first ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(3)
                ForEach(Array(table.columns.enumerated().dropFirst()), id: \.offset) { i, name in
                    let v = row.cells[safe: i] ?? ""
                    if !v.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                            Text(v).font(.system(.caption, design: .monospaced)).lineLimit(2)
                        }
                    }
                }
            }
            .contextMenu {
                Button(L("コピー", "Copy")) { copyToPasteboard(row.cells.joined(separator: "\t")) }
            }
        }
        .listStyle(.plain)
    }
}

struct SectionDetailView: View {
    let section: ReportSection
    let filter: String

    /// A long trailing table gets the real table view and the remaining height.
    private var split: (top: [Block], main: TableData?) {
        if case .table(let t)? = section.blocks.last, t.rows.count > 14 {
            return (Array(section.blocks.dropLast()), t)
        }
        return (section.blocks, nil)
    }

    var body: some View {
        let parts = split
        VStack(spacing: 0) {
            if let main = parts.main {
                if !parts.top.isEmpty {
                    ViewThatFits(in: .vertical) {
                        blocks(parts.top)
                        ScrollView { blocks(parts.top) }
                    }
                    .frame(maxHeight: 250)
                    Divider()
                }
                FullTableView(table: main, filter: filter)
            } else {
                ScrollView { blocks(parts.top) }
            }
        }
    }

    private func blocks(_ list: [Block]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, b in
                BlockView(block: filtered(b))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filtered(_ b: Block) -> Block {
        guard !filter.isEmpty else { return b }
        switch b {
        case .table(var t):
            t.rows = t.rows.filter { r in r.contains { $0.localizedCaseInsensitiveContains(filter) } }
            t.total = nil
            return .table(t)
        case .rows(let rows):
            return .rows(rows.filter { $0.key.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) })
        default: return b
        }
    }
}

struct DocumentView: View {
    let url: URL
    var initialSection: String? = nil
    @State private var report: Report?
    @State private var selection: String? = nil
    @State private var filter = ""
    @State private var exportDoc: JSONExport?
    /// Screenshots only: the detail page opened right away on a phone (NAKAMI_SECTION).
    @State private var autoPush: ReportSection?

    #if os(iOS)
    // iOS: the document scene already has a navigation bar (back to the file browser, file name).
    // So no split view of our own: the overview comes first, the detail pages are pushed onto that same bar.
    // (A ≡ menu that switches pages in place was tried and rejected in favour of this.)
    // Used on iPhone and in narrow iPad windows.
    private var listBody: some View {
        Group {
            if let report {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            HeaderView(report: report, iconSize: 72)
                            RowsView(rows: report.summary)
                        }
                        .padding(.vertical, 6)
                    }
                    if !report.sections.isEmpty {
                        Section(L("詳細", "Details")) {
                            ForEach(report.sections) { s in
                                NavigationLink {
                                    SectionPage(section: s)
                                } label: {
                                    Label(s.title, systemImage: s.symbol)
                                        .badge(s.count.map { Text("\($0)") })
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                #if NAKAMI_SELFTEST
                .navigationDestination(isPresented: Binding(get: { autoPush != nil }, set: { if !$0 { autoPush = nil } })) {
                    if let s = autoPush { SectionPage(section: s) }
                }
                #endif
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("解析中…", "Analyzing…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { exportJSON() } label: { Label(L("JSON で書き出す", "Export JSON"), systemImage: "square.and.arrow.up") }
                    .disabled(report == nil)
                Button { load() } label: { Label(L("再読み込み", "Reload"), systemImage: "arrow.clockwise") }
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .json,
                      defaultFilename: url.deletingPathExtension().lastPathComponent + ".json") { _ in exportDoc = nil }
        .task { if report == nil { load() } }
    }

    @Environment(\.dismiss) private var dismiss

    /// Windows at least this wide get the Mac layout (sidebar + detail).
    static let wideLayoutWidth: CGFloat = 640

    // Wide windows look like the Mac, whatever the device: iPad, iPad mini, an unfolded iPhone, a phone in
    // landscape. It goes by the window's real width, not the size class, and the split view is told it has
    // room so it does not collapse. The document scene's own bar is hidden there (two stacked bars otherwise)
    // and the sidebar gets the button that closes the document.
    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= DocumentView.wideLayoutWidth {
                splitBody
                    .environment(\.horizontalSizeClass, .regular)
                    .toolbar(.hidden, for: .navigationBar)
            } else {
                listBody
            }
        }
    }
    #else
    var body: some View { splitBody }
    #endif

    private func sidebarRow(_ s: ReportSection) -> some View {
        let count: Text? = s.count.map { Text("\($0)") }
        return Label(s.title, systemImage: s.symbol).badge(count)
    }

    private var splitBody: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(L("概要", "Overview"), systemImage: "rectangle.and.text.magnifyingglass").tag("overview")
                if let report, !report.sections.isEmpty {
                    Section(L("詳細", "Details")) {
                        ForEach(report.sections) { s in sidebarRow(s).tag(s.id) }
                    }
                }
            }
            // iOS: no fixed width, so that on a half-folded iPhone Duo the system sizes the columns to the fold.
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            #else
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label(L("閉じる", "Close"), systemImage: "chevron.backward") }
                }
            }
            #endif
        } detail: {
            detail
                #if os(macOS)
                .navigationSubtitle(url.lastPathComponent)
                #endif
        }
        .searchable(text: $filter, prompt: L("この画面を絞り込む", "Filter"))
        .toolbar {
            ToolbarItemGroup {
                #if os(macOS)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label(L("Finder に表示", "Show in Finder"), systemImage: "folder")
                }
                .help(L("Finder に表示", "Show in Finder"))
                #endif
                Button { exportJSON() } label: {
                    Label(L("JSON で書き出す", "Export JSON"), systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil)
                Button { load() } label: {
                    Label(L("再読み込み", "Reload"), systemImage: "arrow.clockwise")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 460)
        #endif
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .json,
                      defaultFilename: url.deletingPathExtension().lastPathComponent + ".json") { _ in exportDoc = nil }
        .task { if report == nil { load() } }
    }

    @ViewBuilder private var detail: some View {
        if let report {
            if let s = report.sections.first(where: { $0.id == selection }) {
                SectionDetailView(section: s, filter: filter)
                    .navigationTitle(s.title)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HeaderView(report: report, iconSize: 96)
                        RowsView(rows: report.summary)
                        Text(report.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(report.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(L("解析中…", "Analyzing…")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        report = nil
        let url = self.url
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var r = Analyzer.analyze(url, opts: AnalyzeOptions(deep: true))
            #if NAKAMI_SELFTEST
            // Screenshots: show a report from sample data instead (NAKAMI_REPORT=sample.json, NAKAMI_ICON=icon.png).
            let env = ProcessInfo.processInfo.environment
            if let p = env["NAKAMI_REPORT"], let d = FileManager.default.contents(atPath: p), var sample = try? JSONDecoder().decode(Report.self, from: d) {
                if let i = env["NAKAMI_ICON"], let d = FileManager.default.contents(atPath: i) { sample.icon = ImageKit.decode(d) }
                r = sample
            }
            #endif
            let result = r
            await MainActor.run {
                let r = result
                report = r
                if selection == nil, let initialSection { selection = initialSection }
                #if NAKAMI_SELFTEST
                autoPush = r.sections.first { $0.id == initialSection }
                #endif
                if selection == nil { selection = "overview" }
                if let sel = selection, sel != "overview", !r.sections.contains(where: { $0.id == sel }) { selection = "overview" }
            }
        }
    }

    private func exportJSON() {
        guard let report else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(report) { exportDoc = JSONExport(data: d) }
    }
}

#if os(iOS)
/// One detail page on iOS, with its own filter field.
struct SectionPage: View {
    let section: ReportSection
    @State private var filter = ""

    var body: some View {
        SectionDetailView(section: section, filter: filter)
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter, prompt: L("絞り込む", "Filter"))
    }
}
#endif

struct JSONExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
