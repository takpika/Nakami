import Foundation
import AppKit

// nakami <path> [--json] [--deep] [--png out.png [--width N]]
var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let json = flag("--json")
let deep = flag("--deep")
let png = option("--png")
let width = option("--width").flatMap { Double($0) } ?? 640
guard let path = args.first else {
    FileHandle.standardError.write(Data("usage: nakami <file-or-bundle> [--json] [--deep] [--png out.png [--width N]]\n".utf8))
    exit(2)
}

let t0 = Date()
let report = Analyzer.analyze(URL(fileURLWithPath: path), opts: AnalyzeOptions(deep: deep))
let elapsed = Date().timeIntervalSince(t0)

if let png {
    MainActor.assumeIsolated { renderPNG(report, to: URL(fileURLWithPath: png), width: width) }
} else if json {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try enc.encode(report))
    print()
} else {
    func pad(_ s: String, _ n: Int) -> String {
        var w = 0
        for u in s.unicodeScalars { w += u.value > 0x2e7f ? 2 : 1 }
        return s + String(repeating: " ", count: max(1, n - w))
    }
    func printRows(_ rows: [Row]) {
        for r in rows {
            let lines = r.value.components(separatedBy: "\n")
            print("  " + pad(r.key, 28) + lines[0])
            for l in lines.dropFirst() { print("  " + pad("", 28) + l) }
        }
    }
    print(report.title)
    print(report.subtitle)
    if !report.badges.isEmpty { print(report.badges.map { "[\($0.text)]" }.joined(separator: " ")) }
    print()
    printRows(report.summary)
    for s in report.sections {
        print("\n== \(s.title)" + (s.count.map { " (\($0))" } ?? "") + " ==")
        for b in s.blocks {
            switch b {
            case .rows(let r): printRows(r)
            case .heading(let h): print("\n  -- \(h) --")
            case .note(let n): print("  * \(n)")
            case .text(let t): print(t.components(separatedBy: "\n").prefix(deep ? 10000 : 12).map { "  | " + $0 }.joined(separator: "\n"))
            case .table(let t):
                let limit = deep ? Int.max : 12
                let shown = t.rows.prefix(limit)
                var w = t.columns.map { $0.count }
                for r in shown { for (i, c) in r.enumerated() where i < w.count { w[i] = min(60, max(w[i], c.count)) } }
                print("  " + t.columns.enumerated().map { pad($0.element, w[$0.offset] + 2) }.joined())
                for r in shown { print("  " + r.enumerated().map { pad($0.element, (w[safe: $0.offset] ?? 10) + 2) }.joined()) }
                let total = t.total ?? t.rows.count
                if total > shown.count { print("  … " + L("他 \(total - shown.count) 件", "\(total - shown.count) more")) }
            }
        }
    }
    FileHandle.standardError.write(Data(String(format: "\n(%.0f ms)\n", elapsed * 1000).utf8))
}
