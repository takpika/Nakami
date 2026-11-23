import Foundation
import CoreGraphics

/// Java archives (.jar / .war / .ear): the manifest, which Java they need, signing, and — for Minecraft mods
/// and server plugins — what the mod says about itself.
enum JAR {
    static func isJAR(_ zip: Zip) -> Bool {
        zip.entry("META-INF/MANIFEST.MF") != nil || zip.entries.prefix(4000).contains { $0.name.hasSuffix(".class") }
    }

    /// Main attributes of a manifest (continuation lines start with one space).
    static func manifest(_ d: Data) -> [(key: String, value: String)] {
        var out = [(String, String)]()
        let text = (String(data: d, encoding: .utf8) ?? String(decoding: d, as: Unicode.ASCII.self)).replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty { if !out.isEmpty { break } else { continue } }   // per-entry sections follow the first blank line
            if line.hasPrefix(" "), !out.isEmpty { out[out.count - 1].1 += line.dropFirst(); continue }
            guard let c = line.range(of: ": ") ?? line.range(of: ":") else { continue }
            out.append((String(line[..<c.lowerBound]), String(line[c.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    static func javaVersion(_ major: Int) -> String {
        switch major {
        case 45: return "1.1"
        case 46...48: return "1.\(major - 44)"
        case 49...: return "\(major - 44)"
        default: return "?"
        }
    }

    struct Mod {
        var loader: String
        var id: String?
        var name: String?
        var version: String?
        var mcVersion: String?
        var description: String?
        var authors: String?
        var url: String?
        var license: String?
        var logo: String?
        var depends: [String] = []
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let a = v as? [Any] {
            let parts = a.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// Old Forge files are often not strict JSON (raw line breaks inside strings): repair the common case.
    static func looseJSON(_ d: Data) -> Any? {
        if let j = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { return j }
        guard var s = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) else { return nil }
        var out = "", inStr = false, esc = false
        for ch in s {
            if inStr {
                if esc { esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { inStr = false }
                else if ch == "\n" { out += "\\n"; continue } else if ch == "\r" || ch == "\t" { continue }
            } else if ch == "\"" { inStr = true }
            out.append(ch)
        }
        s = out
        return try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
    }

    /// `key = "value"` pairs of a TOML table (enough for mods.toml).
    static func toml(_ text: String, table: String) -> [String: String] {
        var out = [String: String](), inside = table.isEmpty
        var pending: (key: String, text: String)?
        for raw in text.components(separatedBy: "\n") {
            if var p = pending {
                if let end = raw.range(of: "'''") ?? raw.range(of: "\"\"\"") { p.text += raw[..<end.lowerBound]; out[p.key] = p.text.trimmingCharacters(in: .whitespacesAndNewlines); pending = nil }
                else { p.text += raw + "\n"; pending = p }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line.replacingOccurrences(of: " ", with: "") == table; if !inside && out.count > 0 && !table.isEmpty { break }; continue }
            guard inside, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("'''") || v.hasPrefix("\"\"\"") {
                let body = String(v.dropFirst(3))
                if let end = body.range(of: "'''") ?? body.range(of: "\"\"\"") { out[k] = String(body[..<end.lowerBound]) } else { pending = (k, body + "\n") }
                continue
            }
            if let hash = v.range(of: " #"), !v.hasPrefix("\"") || v[..<hash.lowerBound].filter({ $0 == "\"" }).count % 2 == 0 { v = v[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
            if v.count >= 2, v.hasPrefix("\"") && v.hasSuffix("\"") || v.hasPrefix("'") && v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
            if out[k] == nil { out[k] = v }
        }
        return out
    }

    static func mods(_ zip: Zip, manifest: [String: String]) -> [Mod] {
        var out = [Mod]()
        func read(_ n: String) -> Data? { zip.read(n, max: 2 << 20) }
        // Fabric / Quilt
        if let d = read("fabric.mod.json"), let j = looseJSON(d) as? [String: Any] {
            var m = Mod(loader: "Fabric", id: j["id"] as? String, name: j["name"] as? String, version: j["version"] as? String)
            m.description = j["description"] as? String
            m.authors = string(j["authors"])
            m.url = ((j["contact"] as? [String: Any])?["homepage"] as? String) ?? ((j["contact"] as? [String: Any])?["sources"] as? String)
            m.license = string(j["license"])
            m.logo = j["icon"] as? String
            if let dep = j["depends"] as? [String: Any] {
                m.mcVersion = string(dep["minecraft"])
                m.depends = dep.keys.sorted().map { k in k + (string(dep[k]).map { " " + $0 } ?? "") }
            }
            out.append(m)
        }
        if let d = read("quilt.mod.json"), let j = looseJSON(d) as? [String: Any], let q = j["quilt_loader"] as? [String: Any] {
            let meta = q["metadata"] as? [String: Any] ?? [:]
            var m = Mod(loader: "Quilt", id: q["id"] as? String, name: meta["name"] as? String, version: q["version"] as? String)
            m.description = meta["description"] as? String
            m.logo = meta["icon"] as? String
            m.license = string(meta["license"])
            out.append(m)
        }
        // Forge 1.13+ / NeoForge
        for (file, loader) in [("META-INF/neoforge.mods.toml", "NeoForge"), ("META-INF/mods.toml", "Forge")] {
            guard let d = read(file), let text = String(data: d, encoding: .utf8) else { continue }
            let top = toml(text, table: ""), t = toml(text, table: "[[mods]]")
            guard !t.isEmpty else { continue }
            var m = Mod(loader: loader, id: t["modId"], name: t["displayName"], version: t["version"])
            if m.version?.contains("${") == true { m.version = manifest["Implementation-Version"] }
            m.description = t["description"]
            m.authors = t["authors"]
            m.url = t["displayURL"]
            m.license = top["license"]
            m.logo = t["logoFile"]
            // [[dependencies.modid]] blocks: modId + versionRange
            var deps = [String]()
            for block in text.components(separatedBy: "[[dependencies.").dropFirst() {
                let kv = toml("[x]\n" + block.drop { $0 != "\n" }, table: "[x]")
                guard let id = kv["modId"] else { continue }
                if id == "minecraft" { m.mcVersion = kv["versionRange"] }
                deps.append(id + (kv["versionRange"].map { " " + $0 } ?? ""))
            }
            m.depends = deps
            out.append(m)
        }
        // Forge 1.12 and earlier
        if let d = read("mcmod.info"), let j = looseJSON(d) {
            let list = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["modList"] as? [[String: Any]]) ?? []
            for e in list.prefix(20) {
                var m = Mod(loader: "Forge", id: e["modid"] as? String, name: e["name"] as? String, version: e["version"] as? String)
                m.mcVersion = e["mcversion"] as? String
                m.description = e["description"] as? String
                m.authors = string(e["authorList"]) ?? string(e["authors"])
                m.url = e["url"] as? String
                m.logo = e["logoFile"] as? String
                m.depends = (e["dependencies"] as? [String]) ?? []
                for k in ["version", "mcVersion"] where (k == "version" ? m.version : m.mcVersion)?.contains("${") == true {
                    if k == "version" { m.version = nil } else { m.mcVersion = nil }
                }
                out.append(m)
            }
        }
        // Bukkit / Spigot / Paper / BungeeCord / Velocity server plugins
        for (file, loader) in [("plugin.yml", "Bukkit / Spigot"), ("paper-plugin.yml", "Paper"), ("bungee.yml", "BungeeCord")] {
            guard let d = read(file), let text = String(data: d, encoding: .utf8) else { continue }
            var kv = [String: String]()
            for line in text.components(separatedBy: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("#") {
                guard let c = line.firstIndex(of: ":") else { continue }
                var v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                if v.count >= 2, v.hasPrefix("\"") && v.hasSuffix("\"") || v.hasPrefix("'") && v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
                kv[String(line[..<c])] = v
            }
            guard kv["name"] != nil || kv["main"] != nil else { continue }
            var m = Mod(loader: loader, id: kv["main"], name: kv["name"], version: kv["version"])
            m.mcVersion = kv["api-version"]
            m.description = kv["description"]
            m.authors = kv["author"] ?? kv["authors"]
            m.url = kv["website"]
            out.append(m)
        }
        if let d = read("velocity-plugin.json"), let j = looseJSON(d) as? [String: Any] {
            var m = Mod(loader: "Velocity", id: j["id"] as? String, name: j["name"] as? String, version: j["version"] as? String)
            m.description = j["description"] as? String
            m.authors = string(j["authors"])
            m.url = j["url"] as? String
            out.append(m)
        }
        // Tweakers / core mods with no descriptor (OptiFine, LiteLoader mods)
        if let d = read("litemod.json"), let j = looseJSON(d) as? [String: Any] {
            var m = Mod(loader: "LiteLoader", id: nil, name: j["name"] as? String, version: j["version"] as? String)
            m.mcVersion = j["mcversion"] as? String
            m.description = j["description"] as? String
            m.authors = j["author"] as? String
            out.append(m)
        }
        return out
    }

    /// Minecraft itself (client or server), as opposed to a mod for it.
    struct Game { var server: Bool; var version: String?; var rows: [Row] = []; var snapshot = false }

    static func minecraftGame(_ zip: Zip, url: URL, manifest: [String: String]) -> Game? {
        let client = zip.entry("net/minecraft/client/main/Main.class") != nil || zip.entry("net/minecraft/client/Minecraft.class") != nil || zip.entry("net/minecraft/client/MinecraftApplet.class") != nil
        let bundler = zip.entry("META-INF/versions.list") != nil && zip.entry("net/minecraft/bundler/Main.class") != nil
        let server = bundler || zip.entry("net/minecraft/server/MinecraftServer.class") != nil || manifest["Main-Class"] == "net.minecraft.server.Main"
        guard client || server else { return nil }
        // A mod loader's own jars also carry these classes; they describe themselves elsewhere.
        if zip.entry("install_profile.json") != nil || zip.entries.contains(where: { $0.name.hasPrefix("net/minecraftforge/") || $0.name.hasPrefix("cpw/mods/fml/") }) { return nil }
        var g = Game(server: !client)
        if let d = zip.read("version.json", max: 1 << 20), let j = looseJSON(d) as? [String: Any] {
            g.version = (j["name"] as? String) ?? (j["id"] as? String)
            g.snapshot = (j["stable"] as? Bool) == false
            g.rows.add(L("通信プロトコルの番号", "Protocol version"), string(j["protocol_version"]))
            g.rows.add(L("ワールドデータの番号", "World version"), string(j["world_version"]))
            if let p = j["pack_version"] as? [String: Any] {
                g.rows.add(L("パックの形式", "Pack format"), L("リソースパック \(string(p["resource"]) ?? "?")、データパック \(string(p["data"]) ?? "?")", "resource \(string(p["resource"]) ?? "?"), data \(string(p["data"]) ?? "?")"))
            } else { g.rows.add(L("パックの形式", "Pack format"), string(j["pack_version"])) }
            g.rows.add(L("ビルド日時", "Built"), (j["build_time"] as? String)?.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "+00:00", with: " UTC"))
            g.rows.add(L("指定の Java", "Java it asks for"), string(j["java_version"]).map { "Java \($0)" })
        }
        if g.version == nil, let d = zip.read("META-INF/versions.list", max: 1 << 16) {
            // "<hash>\t<id>\t<path>"
            g.version = String(decoding: d, as: UTF8.self).split(separator: "\n").first?.split(separator: "\t").dropFirst().first.map(String.init)
        }
        // Before 1.14 the jar does not say its version; the launcher's file next to it, or the file name, does.
        if g.version == nil {
            let side = url.deletingPathExtension().appendingPathExtension("json")
            if let d = try? Data(contentsOf: side), d.count < 4 << 20, let j = looseJSON(d) as? [String: Any] {
                g.version = j["id"] as? String
                g.snapshot = ["snapshot", "old_alpha", "old_beta"].contains((j["type"] as? String) ?? "")
                g.rows.add(L("公開日", "Released"), (j["releaseTime"] as? String).map { String($0.prefix(10)) })
            }
        }
        if g.version == nil { g.version = firstMatch(url.lastPathComponent, #"(\d+\.\d+(?:\.\d+)?(?:-(?:pre|rc)\d+)?|\d\dw\d\d[a-z])"#) }
        return g
    }

    /// Maven coordinates recorded inside the jar: its own, and those of libraries merged into it.
    static func maven(_ zip: Zip) -> [(group: String, artifact: String, version: String)] {
        var out = [(String, String, String)]()
        for e in zip.entries where e.name.hasPrefix("META-INF/maven/") && e.name.hasSuffix("/pom.properties") {
            guard out.count < 2000, let d = zip.read(e, max: 1 << 16) else { continue }
            var kv = [String: String]()
            for line in String(decoding: d, as: UTF8.self).split(separator: "\n") where !line.hasPrefix("#") {
                if let eq = line.firstIndex(of: "=") { kv[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
            }
            if let g = kv["groupId"], let a = kv["artifactId"] { out.append((g, a, kv["version"] ?? "")) }
        }
        return out
    }

    /// Languages and frameworks, judged from the packages and marker files inside.
    static func technologies(_ names: [String], manifest: [String: String]) -> [String] {
        var t = [String]()
        func has(_ prefix: String) -> Bool { names.contains { $0.hasPrefix(prefix) } }
        func ends(_ suffix: String) -> Bool { names.contains { $0.hasSuffix(suffix) } }
        if ends(".kotlin_module") || has("kotlin/") { t.append("Kotlin") }
        if has("scala/") || ends(".tasty") { t.append("Scala") }
        if has("groovy/") || has("org/codehaus/groovy/") { t.append("Groovy") }
        if has("clojure/") || ends("__init.class") { t.append("Clojure") }
        if has("javafx/") || manifest["JavaFX-Version"] != nil { t.append("JavaFX") }
        if has("org/springframework/boot/") || has("BOOT-INF/") { t.append("Spring Boot") }
        else if has("org/springframework/") { t.append("Spring") }
        if has("io/quarkus/") { t.append("Quarkus") }
        if has("org/lwjgl/") { t.append("LWJGL") }
        if has("com/badlogic/gdx/") { t.append("libGDX") }
        if has("processing/core/") { t.append("Processing") }
        if has("org/eclipse/swt/") { t.append("SWT") }
        if has("io/netty/") { t.append("Netty") }
        if has("META-INF/gradle-plugins/") { t.append(L("Gradle プラグイン", "Gradle plugin")) }
        if names.contains("META-INF/services/javax.annotation.processing.Processor") { t.append(L("注釈プロセッサー", "Annotation processor")) }
        if names.contains("META-INF/services/java.sql.Driver") { t.append(L("JDBC ドライバー", "JDBC driver")) }
        return t
    }

    static func logoData(_ zip: Zip, mods: [Mod]) -> Data? {
        for m in mods {
            guard var l = m.logo, !l.isEmpty else { continue }
            while l.hasPrefix("/") { l.removeFirst() }
            if let d = zip.read(l, max: 8 << 20) ?? zip.entries.first(where: { $0.name.lowercased() == l.lowercased() }).flatMap({ zip.read($0, max: 8 << 20) }) { return d }
        }
        if !mods.isEmpty { for n in ["pack.png", "icon.png", "logo.png"] { if let d = zip.read(n, max: 8 << 20) { return d } } }
        return nil
    }

    /// The mod's own logo, for Finder / Files thumbnails. Plain libraries have none.
    static func icon(_ zip: Zip) -> CGImage? {
        guard isJAR(zip) else { return nil }
        if let d = logoData(zip, mods: mods(zip, manifest: [:])) { return ImageKit.decode(d) }
        // Minecraft itself carries its pack picture.
        if zip.entry("net/minecraft/client/main/Main.class") != nil || zip.entry("net/minecraft/server/MinecraftServer.class") != nil, let d = zip.read("pack.png", max: 4 << 20) { return ImageKit.decode(d) }
        return nil
    }

    static func report(url: URL, zip: Zip, fileSize: Int, opts: AnalyzeOptions) -> Report {
        let started = Date()
        var rep = Report(kind: .apk, path: url.path, title: url.lastPathComponent)
        let mfRows = zip.read("META-INF/MANIFEST.MF", max: 8 << 20).map { manifest($0) } ?? []
        var mf = [String: String]()
        for (k, v) in mfRows where mf[k] == nil { mf[k] = v }
        let names = zip.entries.map { $0.name }
        let classes = zip.entries.filter { $0.name.hasSuffix(".class") }
        let game = minecraftGame(zip, url: url, manifest: mf)
        let mods = game == nil ? mods(zip, manifest: mf) : []
        let ext = url.pathExtension.lowercased()
        let coords = maven(zip)
        // The jar's own coordinates: the only one, or the one whose artifact name the file name starts with.
        let base = url.deletingPathExtension().lastPathComponent
        let own = coords.count == 1 ? coords.first : coords.filter { base.hasPrefix($0.artifact) }.max { $0.artifact.count < $1.artifact.count }
        let installer = zip.read("install_profile.json", max: 4 << 20).flatMap { looseJSON($0) as? [String: Any] }
        let ideaPlugin = zip.read("META-INF/plugin.xml", max: 2 << 20).flatMap { XMLNode.parse($0) }

        // ---- what kind of archive
        var kind = L("Java アーカイブ (jar)", "Java archive (jar)")
        var badges = [Badge]()
        var loaderTitle: String?
        let isWar = names.contains { $0.hasPrefix("WEB-INF/") }
        let isSpring = names.contains { $0.hasPrefix("BOOT-INF/") } || mf["Start-Class"] != nil
        let tweak = mf["TweakClass"], coremod = mf["FMLCorePlugin"]
        if let g = game {
            kind = g.server ? L("Minecraft のサーバー本体", "Minecraft server") : L("Minecraft 本体（Java 版）", "Minecraft: Java Edition")
            badges.append(Badge(text: "Minecraft", tone: .info))
            if g.snapshot { badges.append(Badge(text: L("開発版", "Snapshot"), tone: .warn)) }
        } else if let p = installer, p["minecraft"] != nil || p["install"] != nil {
            kind = L("Minecraft の Mod ローダーのインストーラー", "Minecraft mod loader installer")
            badges.append(Badge(text: "Minecraft", tone: .info))
        } else if let m = mods.first {
            let server = ["Bukkit / Spigot", "Paper", "BungeeCord", "Velocity"].contains(m.loader)
            kind = server ? L("Minecraft サーバーのプラグイン (\(m.loader))", "Minecraft server plugin (\(m.loader))") : L("Minecraft の Mod (\(m.loader))", "Minecraft mod (\(m.loader))")
            badges.append(Badge(text: m.loader, tone: .info))
            if let v = m.mcVersion, !v.isEmpty, !server { badges.append(Badge(text: "Minecraft " + v)) }
        } else if names.contains(where: { $0.hasPrefix("net/minecraftforge/common/") || $0.hasPrefix("cpw/mods/fml/common/") || $0.hasPrefix("net/fabricmc/loader/") }) {
            let fabric = names.contains { $0.hasPrefix("net/fabricmc/loader/") }
            kind = fabric ? L("Fabric Loader 本体（Minecraft の Mod ローダー）", "Fabric Loader (Minecraft mod loader)") : L("Minecraft Forge 本体（Mod ローダー）", "Minecraft Forge (mod loader)")
            badges.append(Badge(text: "Minecraft", tone: .info))
            loaderTitle = fabric ? "Fabric Loader" : "Minecraft Forge"
        } else if tweak != nil || coremod != nil {
            kind = L("Minecraft の Mod（起動時に組み込まれる型）", "Minecraft mod (tweaker / core mod)")
            badges.append(Badge(text: "Minecraft", tone: .info))
        } else if isSpring { kind = L("Spring Boot アプリケーション", "Spring Boot application"); badges.append(Badge(text: "Spring Boot", tone: .info)) }
        else if isWar || ext == "war" { kind = L("Java Web アプリケーション (war)", "Java web application (war)") }
        else if ext == "ear" { kind = L("Java エンタープライズアプリケーション (ear)", "Java enterprise application (ear)") }
        else if ext == "aar" || zip.entry("classes.jar") != nil { kind = L("Android ライブラリ (aar)", "Android library (aar)") }
        else if ideaPlugin?.name == "idea-plugin" { kind = L("IntelliJ 系 IDE のプラグイン", "IntelliJ Platform plugin") }
        else if coords.count <= 1, names.contains(where: { $0.hasPrefix("META-INF/gradle-plugins/") }) { kind = L("Gradle プラグイン (jar)", "Gradle plugin (jar)") }
        else if mf["Premain-Class"] != nil || mf["Agent-Class"] != nil { kind = L("Java エージェント", "Java agent") }
        else if mf["Main-Class"] != nil { kind = L("実行できる Java アーカイブ (jar)", "Runnable Java archive (jar)") }
        else if classes.isEmpty, names.contains(where: { $0.hasSuffix("-sources.jar") }) || url.lastPathComponent.contains("-sources") { kind = L("Java のソースアーカイブ", "Java source archive") }
        else { kind = L("Java のライブラリ (jar)", "Java library (jar)") }

        // ---- which Java it needs: the newest class-file version among a sample of classes
        var versions = [Int: Int]()
        var sampled = 0
        let step = Swift.max(1, classes.count / (opts.deep ? 4000 : 300))
        var i = 0
        while i < classes.count, opts.deep || Date().timeIntervalSince(started) < opts.budget * 0.6 {
            let e = classes[i]
            i += step
            guard !e.name.hasPrefix("META-INF/versions/"), !e.name.hasSuffix("module-info.class"), let d = zip.read(e, max: 4 << 20), d.count >= 8 else { continue }
            let r = Reader(d, little: false)
            guard r.u32(0) == 0xcafe_babe else { continue }
            versions[Int(r.u16(6)), default: 0] += 1
            sampled += 1
        }
        let newest = versions.keys.max()

        // ---- signing (same scheme as APK v1)
        let sigFiles = zip.entries.filter { e in e.name.hasPrefix("META-INF/") && [".RSA", ".DSA", ".EC"].contains { e.name.uppercased().hasSuffix($0) } }
        var signer: CMSInfo?
        if let s = sigFiles.first, let d = zip.read(s, max: 1 << 20) { signer = decodeCMS(d) }
        if !sigFiles.isEmpty { badges.append(Badge(text: L("署名あり", "Signed"), tone: .good)) }

        // ---- summary
        let m0 = mods.first
        if let g = game { rep.title = "Minecraft" + (g.version.map { " " + $0 } ?? "") + (g.server ? L(" サーバー", " Server") : "") }
        else if let p = installer, let prof = (p["profile"] as? String) ?? ((p["install"] as? [String: Any])?["profileName"] as? String) { rep.title = prof + L(" のインストーラー", " installer") }
        else if let t = loaderTitle { rep.title = t + (firstMatch(base, #"(?:forge|loader)-(.+?)(?:-universal|-installer)?$"#).map { " " + $0 } ?? "") }
        else if let n = ideaPlugin?.first("name")?.text, ideaPlugin?.name == "idea-plugin", !n.isEmpty { rep.title = n }
        else if let n = m0?.name ?? mf["Implementation-Title"] ?? mf["Bundle-Name"] ?? mf["Specification-Title"] ?? own?.artifact, !n.isEmpty { rep.title = n }
        rep.subtitle = kind
        rep.badges = badges
        var sum = [Row(L("種類", "Kind"), kind)]
        let version = game?.version ?? m0?.version ?? (installer?["version"] as? String) ?? ((installer?["install"] as? [String: Any])?["version"] as? String)
            ?? ideaPlugin?.first("version")?.text ?? mf["Implementation-Version"] ?? mf["Bundle-Version"] ?? own?.version ?? mf["Specification-Version"]
        sum.add(L("バージョン", "Version"), version)
        if let g = game { sum.append(contentsOf: g.rows) }
        if let p = installer {
            sum.add(L("対応する Minecraft", "For Minecraft"), (p["minecraft"] as? String) ?? ((p["install"] as? [String: Any])?["minecraft"] as? String))
        }
        if let x = ideaPlugin, x.name == "idea-plugin" {
            sum.add(L("プラグインの ID", "Plugin ID"), x.first("id")?.text, mono: true)
            sum.add(L("提供元", "Vendor"), x.first("vendor")?.text)
            if let iv = x.first("idea-version") { sum.add(L("対応する IDE のビルド", "IDE builds"), [iv.attrs["since-build"], iv.attrs["until-build"]].compactMap { $0 }.joined(separator: " – ")) }
        }
        if let o = own { sum.add(L("Maven の座標", "Maven coordinates"), "\(o.group):\(o.artifact):\(o.version)", mono: true) }
        sum.add(L("説明", "Description"), m0 == nil ? (mf["Bundle-Description"] ?? mf["Implementation-Description"]) : nil)
        sum.add(L("ライセンス", "License"), m0 == nil ? mf["Bundle-License"] : nil)
        let tech = technologies(names, manifest: mf)
        sum.add(L("技術", "Technologies"), tech.joined(separator: ", "))
        if let m = m0 {
            sum.add(L("Mod の ID", "Mod ID"), m.id, mono: true)
            sum.add(L("対応する Minecraft", "For Minecraft"), m.mcVersion)
            sum.add(L("作者", "Authors"), m.authors)
            sum.add(L("説明", "Description"), m.description?.trimmingCharacters(in: .whitespacesAndNewlines))
            sum.add(L("Web サイト", "Website"), m.url)
            sum.add(L("ライセンス", "License"), m.license)
        }
        sum.add(L("提供元", "Vendor"), mf["Implementation-Vendor"] ?? mf["Bundle-Vendor"] ?? mf["Specification-Vendor"])
        sum.add(L("起動するクラス", "Main class"), mf["Start-Class"] ?? mf["Main-Class"], mono: true)
        if let v = newest {
            sum.add(L("必要な Java", "Java required"), "Java \(javaVersion(v)) " + L("以降", "or later") + L("（クラスファイル形式 \(v)）", " (class file version \(v))"))
        }
        if names.contains(where: { $0.hasPrefix("META-INF/versions/") }) || mf["Multi-Release"]?.lowercased() == "true" {
            let vs = Set(names.compactMap { n -> Int? in n.hasPrefix("META-INF/versions/") ? Int(n.dropFirst(18).prefix { $0 != "/" }) : nil }).sorted()
            sum.add(L("Java のバージョン別のクラス", "Per-version classes"), vs.isEmpty ? L("あり", "Yes") : vs.map { "Java \($0)" }.joined(separator: ", "))
        }
        let module = mf["Automatic-Module-Name"] ?? (names.contains("module-info.class") ? L("あり (module-info.class)", "Yes (module-info.class)") : nil)
        sum.add(L("モジュール", "Module"), module, mono: mf["Automatic-Module-Name"] != nil)
        sum.add(L("OSGi バンドル名", "OSGi bundle"), mf["Bundle-SymbolicName"]?.split(separator: ";").first.map(String.init), mono: true)
        sum.add(L("起動時に組み込むクラス", "Tweak class"), tweak ?? coremod, mono: true)
        sum.add(L("Java エージェント", "Java agent"), mf["Premain-Class"] ?? mf["Agent-Class"], mono: true)
        sum.add(L("ビルドした Java", "Built with"), mf["Build-Jdk"] ?? mf["Build-Jdk-Spec"] ?? mf["Created-By"])
        if let s = signer { sum.add(L("署名者", "Signed by"), s.names.first, tone: .good) }
        else if !sigFiles.isEmpty { sum.add(L("署名", "Signature"), L("あり（署名者は読めませんでした）", "Present (signer could not be read)")) }
        else { sum.add(L("署名", "Signature"), L("なし", "None")) }
        sum.add(L("クラス数", "Classes"), classes.isEmpty ? nil : "\(classes.count)")
        sum.add(L("ファイル数", "Files"), "\(zip.entries.filter { !$0.name.hasSuffix("/") }.count)")
        sum.add(L("展開後のサイズ", "Unpacked size"), byteSize(zip.totalUncompressed))
        sum.add(L("サイズ", "Size"), byteSizeExact(fileSize))
        rep.summary = sum
        if let d = logoData(zip, mods: mods) { rep.icon = ImageKit.decode(d) }
        else if game != nil, let d = zip.read("pack.png", max: 4 << 20) { rep.icon = ImageKit.decode(d) }

        // ---- sections
        var sections = [ReportSection]()
        if mods.count > 1 || !(m0?.depends.isEmpty ?? true) {
            var blocks = [Block]()
            if mods.count > 1 {
                blocks.append(.table(TableData(columns: ["ID", L("名前", "Name"), L("バージョン", "Version"), L("種類", "Loader")],
                                               rows: mods.map { [$0.id ?? "", $0.name ?? "", $0.version ?? "", $0.loader] })))
            }
            let deps = mods.flatMap { $0.depends }
            if !deps.isEmpty { blocks.append(.heading(L("必要なもの", "Requires"))); blocks.append(.table(TableData(columns: [L("名前と範囲", "Name and range")], rows: Array(Set(deps)).sorted().map { [$0] }))) }
            sections.append(ReportSection(id: "mods", title: L("Mod の情報", "Mods"), symbol: "puzzlepiece.extension", blocks: blocks, count: mods.count))
        }
        if !mfRows.isEmpty {
            sections.append(ReportSection(id: "manifest", title: L("マニフェスト", "Manifest"), symbol: "list.bullet.rectangle",
                                          blocks: [.rows(mfRows.map { Row($0.key, $0.value, mono: true) })], count: mfRows.count))
        }
        // Libraries merged into this jar (their Maven records come along), and service providers it registers.
        let merged = coords.filter { own == nil || $0.artifact != own!.artifact || $0.group != own!.group }
        if !merged.isEmpty {
            sections.append(ReportSection(id: "merged", title: L("取り込まれたライブラリ", "Merged Libraries"), symbol: "books.vertical",
                blocks: [.table(TableData(columns: [L("グループ", "Group"), L("名前", "Artifact"), L("バージョン", "Version")],
                                          rows: merged.sorted { ($0.group, $0.artifact) < ($1.group, $1.artifact) }.map { [$0.group, $0.artifact, $0.version] }))], count: merged.count))
        }
        let services = zip.entries.filter { $0.name.hasPrefix("META-INF/services/") && !$0.name.hasSuffix("/") }
        if !services.isEmpty {
            var rows = [[String]]()
            for e in services.prefix(200) {
                let impls = zip.read(e, max: 1 << 16).map { String(decoding: $0, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") } } ?? []
                rows.append([String(e.name.dropFirst(18)), impls.prefix(6).joined(separator: "\n") + (impls.count > 6 ? L("\n… ほか \(impls.count - 6) 個", "\n… and \(impls.count - 6) more") : "")])
            }
            sections.append(ReportSection(id: "services", title: L("登録している機能 (ServiceLoader)", "Service Providers"), symbol: "point.3.connected.trianglepath.dotted",
                blocks: [.table(TableData(columns: [L("インターフェース", "Interface"), L("実装するクラス", "Implementations")], rows: rows, total: services.count))], count: services.count))
        }
        // Packages: where the classes live, largest first.
        var pkgs = [String: (count: Int, size: Int)]()
        for e in classes {
            var parts = e.name.split(separator: "/").dropLast()
            if parts.first == "BOOT-INF" || parts.first == "WEB-INF" { parts = parts.dropFirst(2) }
            if parts.first == "META-INF" { continue }
            let key = parts.prefix(3).joined(separator: ".")
            let cur = pkgs[key] ?? (0, 0)
            pkgs[key] = (cur.count + 1, cur.size + e.size)
        }
        if !pkgs.isEmpty {
            let rows = pkgs.sorted { $0.value.count > $1.value.count }.prefix(opts.deep ? 2000 : 200).map { [$0.key.isEmpty ? L("（パッケージなし）", "(default package)") : $0.key, "\($0.value.count)", byteSize($0.value.size)] }
            var blocks: [Block] = [.table(TableData(columns: [L("パッケージ", "Package"), L("クラス数", "Classes"), L("サイズ", "Size")], rows: rows, total: pkgs.count))]
            if versions.count > 1 {
                blocks.append(.heading(L("クラスファイルの形式（調べた \(sampled) 個の内訳）", "Class file versions (of \(sampled) sampled)")))
                blocks.append(.rows(versions.sorted { $0.key > $1.key }.map { Row("Java \(javaVersion($0.key))", "\($0.value)") }))
            }
            sections.append(ReportSection(id: "packages", title: L("パッケージ", "Packages"), symbol: "shippingbox", blocks: blocks, count: pkgs.count))
        }
        // Libraries packed inside (Spring Boot, war, fat jars with nested jars) and native code.
        let nested = zip.entries.filter { $0.name.hasSuffix(".jar") }
        if !nested.isEmpty {
            sections.append(ReportSection(id: "libs", title: L("同梱のライブラリ", "Bundled Libraries"), symbol: "books.vertical",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: nested.sorted { $0.name < $1.name }.prefix(3000).map { [$0.name, byteSize($0.size)] }, total: nested.count))], count: nested.count))
        }
        let native = zip.entries.filter { e in [".so", ".dll", ".dylib", ".jnilib"].contains { e.name.lowercased().hasSuffix($0) } }
        if !native.isEmpty {
            var rows = [[String]]()
            for e in native.prefix(300) {
                var what = ""
                if Date().timeIntervalSince(started) < opts.budget || opts.deep, let d = zip.read(e, max: 64 << 20) {
                    let r = Reader(d)
                    if ELF.isELF(r) { what = "ELF " + (ELF.machines[r.u8(5) == 2 ? r.be16(18) : r.le16(18)] ?? "") }
                    else if MachO.isMachO(r) { what = "Mach-O" }
                    else if let pe = PEFile(d) { what = "PE " + (PEFile.machines[pe.machine] ?? "") }
                }
                rows.append([e.name, what, byteSize(e.size)])
            }
            sections.append(ReportSection(id: "native", title: L("ネイティブコード", "Native Code"), symbol: "cpu",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("形式", "Format"), L("サイズ", "Size")], rows: rows, total: native.count))], count: native.count))
        }
        if let s = signer {
            var rows = [Row]()
            rows.add(L("署名者", "Signer"), s.names.first)
            rows.add(L("証明書の連鎖", "Certificate chain"), s.names.joined(separator: " → "))
            if let t = s.signingTime ?? s.timestamp { rows.add(L("署名日時", "Signed at"), dateString(t)) }
            rows.add(L("署名ファイル", "Signature files"), sigFiles.map { $0.name }.joined(separator: "\n"), mono: true)
            sections.append(ReportSection(id: "signature", title: L("署名", "Signature"), symbol: "checkmark.seal", blocks: [.rows(rows)]))
        }
        sections.append(IPA.largestFiles(zip, strip: "", deep: opts.deep))
        rep.sections = sections
        return rep
    }
}
