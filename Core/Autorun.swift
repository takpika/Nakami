import Foundation
import CoreGraphics

/// Windows discs: `autorun.inf` names the program started when the disc is inserted, the disc's icon and its label.
enum Autorun {
    static func decode(_ d: Data) -> String {
        if d.count >= 2, d[d.startIndex] == 0xff, d[d.startIndex + 1] == 0xfe { return String(data: d, encoding: .utf16) ?? "" }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .shiftJIS) ?? String(data: d, encoding: .isoLatin1) ?? ""
    }

    /// Keys of the [autorun] section (lower-cased). Sections for one CPU type ("[AutoRun.Amd64]") are folded in.
    static func parse(_ text: String) -> [(key: String, value: String)] {
        var out = [(String, String)]()
        var inside = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.dropFirst().prefix { $0 != "]" }.lowercased()
                inside = name == "autorun" || name.hasPrefix("autorun.")
                continue
            }
            guard inside, !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, !out.contains(where: { $0.0 == k }) { out.append((k, v)) }
        }
        return out
    }

    static func inspect(_ fs: DiscFS) -> (rows: [Row], section: ReportSection, icon: CGImage?)? {
        guard let size = fs.size("autorun.inf"), size > 0, size < 256 << 10, let d = fs.read("autorun.inf", length: size) else { return nil }
        let text = decode(d)
        let keys = parse(text)
        guard !keys.isEmpty else { return nil }
        func v(_ k: String) -> String? { keys.first { $0.key == k }?.value }
        var rows = [Row]()
        rows.add(L("挿入時に起動するプログラム", "Program started on insert"), v("open") ?? v("shellexecute"), mono: true)
        rows.add(L("ディスクの表示名", "Disc label"), v("label"))
        rows.add(L("ディスクのアイコン", "Disc icon"), v("icon"), mono: true)
        let menu = keys.filter { $0.key.hasPrefix("shell\\") && !$0.key.hasSuffix("\\command") }.map { m -> String in
            let cmd = v(m.key + "\\command")
            return m.value.replacingOccurrences(of: "&", with: "") + (cmd.map { "  →  " + $0 } ?? "")
        }
        rows.add(L("右クリックメニューの項目", "Context menu items"), menu.joined(separator: "\n"))

        // The icon is an .ico file, or a program / library with an index ("setup.exe,0").
        var icon: CGImage?
        if var spec = v("icon") ?? v("open") {
            spec = spec.replacingOccurrences(of: "\"", with: "")
            if let comma = spec.lastIndex(of: ","), Int(spec[spec.index(after: comma)...].trimmingCharacters(in: .whitespaces)) != nil { spec = String(spec[..<comma]) }
            var path = spec.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
            // "open=setup.exe /auto" — drop arguments when the whole thing is not a file.
            if fs.size(path) == nil, let sp = path.firstIndex(of: " ") { path = String(path[..<sp]) }
            while path.hasPrefix("/") || path.hasPrefix("./") { path = String(path.drop { $0 == "." || $0 == "/" }) }
            if let n = fs.size(path), n > 0, n <= 96 << 20, let file = fs.read(path, length: n) {
                if let pe = PEFile(file) { icon = pe.iconData(pe.resources()).flatMap { MSI.image($0) } }
                else { icon = MSI.image(file) ?? ImageKit.decode(file) }
            }
        }
        let sec = ReportSection(id: "autorun", title: L("自動再生 (autorun.inf)", "AutoRun (autorun.inf)"), symbol: "play.circle",
                                blocks: [.rows(rows), .text(text.trimmingCharacters(in: .whitespacesAndNewlines))])
        return (rows, sec, icon)
    }
}
