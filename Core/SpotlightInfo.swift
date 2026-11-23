import Foundation

/// What Nakami tells Spotlight about a file (shared by the macOS importer plug-in and the iOS import extension).
struct SpotlightInfo {
    var title: String?
    var kind: String?
    var summary: String?
    var version: String?
    var identifier: String?
    var publisher: String?
    var copyright: String?
    var keywords: [String] = []
    var comment: String?

    init?(url: URL) {
        let report = Analyzer.analyze(url, opts: AnalyzeOptions(deep: false, budget: 1.0))
        guard report.kind != .unknown else { return nil }
        func value(_ keys: [String]) -> String? {
            for k in keys { if let r = report.summary.first(where: { $0.key == k }) { return r.value } }
            return nil
        }
        if !report.title.isEmpty, report.title != url.lastPathComponent { title = report.title }
        // The first part of the subtitle is the most specific description of what the file is.
        kind = value([L("種類", "Kind")]) ?? report.subtitle.components(separatedBy: " · ").first
        summary = report.subtitle
        version = value([L("バージョン", "Version")])
        identifier = value([L("識別子", "Identifier"), L("パッケージ名", "Package"), L("ゲーム ID", "Game ID"), L("ゲームコード", "Game code"), L("タイトル ID", "Title ID")])
        publisher = value([L("署名者", "Signed by"), L("メーカー", "Maker"), L("会社名", "Company"), L("製造元", "Manufacturer"), L("発行元", "Publisher"), L("発行者", "Publisher")])
        copyright = value([L("著作権", "Copyright")])
        if let arch = value([L("アーキテクチャ", "Architectures"), L("アーキテクチャ", "Architecture"), L("対応 CPU", "ABIs")]) {
            keywords = arch.components(separatedBy: CharacterSet(charactersIn: ",、\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let badges = report.badges.map { $0.text }.joined(separator: ", ")
        comment = badges.isEmpty ? nil : badges
    }
}
