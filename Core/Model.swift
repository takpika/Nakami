import Foundation
import CoreGraphics

/// Japanese when the user's first language is Japanese, otherwise English.
/// `NAKAMI_LANG=en` / `ja` overrides it (used by the tests, and handy on the command line).
let prefersJapanese: Bool = (ProcessInfo.processInfo.environment["NAKAMI_LANG"] ?? Locale.preferredLanguages.first ?? "ja").hasPrefix("ja")
func L(_ ja: String, _ en: String) -> String { prefersJapanese ? ja : en }

enum Tone: String, Codable { case neutral, good, warn, bad, info }

struct Badge: Codable, Hashable {
    var text: String
    var tone: Tone = .neutral
}

struct Row: Codable, Hashable, Identifiable {
    var key: String
    var value: String
    var mono = false
    var tone: Tone = .neutral
    var id: String { key + "\u{1}" + value }

    init(_ key: String, _ value: String, mono: Bool = false, tone: Tone = .neutral) {
        self.key = key
        self.value = value
        self.mono = mono
        self.tone = tone
    }
}

struct TableData: Codable, Hashable {
    var columns: [String]
    var rows: [[String]]
    /// Total number of entries when `rows` was capped.
    var total: Int?
}

enum Block: Codable, Hashable {
    case rows([Row])
    case table(TableData)
    case text(String)
    case note(String)
    case heading(String)
}

struct ReportSection: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var symbol: String
    var blocks: [Block]
    /// Short count shown next to the title ("12").
    var count: Int?
}

struct IconFrame {
    var image: CGImage
    var duration: Double
}

enum ReportKind: String, Codable { case bundle, macho, pe, elf, ipa, apk, appx, msi, pkg, ipsw, xip, rom, disc, disk, unknown }

struct Report: Codable {
    var kind: ReportKind = .unknown
    var path: String = ""
    var title: String = ""
    var subtitle: String = ""
    var badges: [Badge] = []
    var summary: [Row] = []
    var sections: [ReportSection] = []
    var icon: CGImage?
    /// Animated icon (DSi titles): frames with how long each one stays, in seconds. Empty for a still icon.
    var iconFrames: [IconFrame] = []

    enum CodingKeys: String, CodingKey { case kind, path, title, subtitle, badges, summary, sections }
}

struct AnalyzeOptions {
    /// Deep mode (app / CLI): strings, full signature validation, no time limits.
    var deep = false
    /// Soft time budget in seconds for the optional parts.
    var budget: TimeInterval = 1.5
    /// Header and signature only (used for nested components).
    var light = false
}

extension Array where Element == Row {
    mutating func add(_ k: String, _ v: String?, mono: Bool = false, tone: Tone = .neutral) {
        guard let v, !v.isEmpty else { return }
        append(Row(k, v, mono: mono, tone: tone))
    }
}

func describePlistValue(_ v: Any) -> String {
    switch v {
    case let b as Bool where CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID(): return b ? "true" : "false"
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case let d as Date: return dateString(d)
    case let d as Data: return "<\(d.count) bytes>"
    case let a as [Any]:
        if a.isEmpty { return "[]" }
        return a.map { describePlistValue($0) }.joined(separator: ", ")
    case let d as [String: Any]:
        if d.isEmpty { return "{}" }
        return "{ " + d.keys.sorted().map { "\($0): \(describePlistValue(d[$0]!))" }.joined(separator: ", ") + " }"
    default: return "\(v)"
    }
}
