import Foundation
import CoreGraphics

/// Apple firmware restore images (.ipsw): iOS, iPadOS, macOS, tvOS, watchOS, visionOS …
enum IPSW {
    static func isIPSW(_ zip: Zip) -> Bool { zip.entry("BuildManifest.plist") != nil }

    static func plist(_ zip: Zip, _ name: String) -> [String: Any]? {
        guard let d = zip.read(name, max: 64 << 20) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
    }

    static func osName(_ types: [String]) -> String {
        guard let t = types.first else { return "OS" }
        if t.hasPrefix("iPhone") || t.hasPrefix("iPod") { return "iOS" }
        if t.hasPrefix("iPad") { return "iPadOS" }
        if t.hasPrefix("AppleTV") { return "tvOS" }
        if t.hasPrefix("Watch") { return "watchOS" }
        if t.hasPrefix("RealityDevice") { return "visionOS" }
        if t.hasPrefix("AudioAccessory") { return "audioOS (HomePod)" }
        if t.hasPrefix("iBridge") { return "bridgeOS" }
        if t.hasPrefix("Mac") || t.hasPrefix("VirtualMac") || t.contains("Mac") { return "macOS" }
        return "OS"
    }

    static var names: [String: String] { DeviceNames.table }

    /// IM4P header: type tag ("ibot", "krnl" …), description (version string) and whether a keybag follows (= encrypted).
    static func im4p(_ d: Data) -> (type: String, description: String, encrypted: Bool)? {
        let b = [UInt8](d.prefix(1 << 16))
        // The payload is longer than the prefix we read, so walk the header fields by hand.
        func header(_ i: Int) -> (tag: UInt8, start: Int, len: Int)? {
            guard i + 2 <= b.count else { return nil }
            var len = Int(b[i + 1]), s = i + 2
            if len & 0x80 != 0 {
                let n = len & 0x7f
                guard n > 0, n <= 4, s + n <= b.count else { return nil }
                len = 0
                for k in 0..<n { len = len << 8 | Int(b[s + k]) }
                s += n
            }
            return (b[i], s, len)
        }
        func str(_ h: (tag: UInt8, start: Int, len: Int)) -> String {
            guard h.start + h.len <= b.count else { return "" }
            return String(decoding: b[h.start..<(h.start + h.len)], as: Unicode.ASCII.self)
        }
        guard let seq = header(0), seq.tag == 0x30, let magic = header(seq.start), magic.tag == 0x16, str(magic) == "IM4P",
              let type = header(magic.start + magic.len), type.tag == 0x16,
              let desc = header(type.start + type.len), desc.tag == 0x16,
              let payload = header(desc.start + desc.len), payload.tag == 0x04 else { return nil }
        // Anything after the payload inside the sequence is the keybag.
        let end = payload.start + payload.len
        let encrypted = end < seq.start + seq.len && end < d.count && (d.count > end ? d[d.startIndex + end] == 0x04 : false)
        return (str(type), str(desc), encrypted)
    }

    /// File icon: a document page with the symbol of the device the firmware is for.
    static func icon(_ zip: Zip) -> CGImage? {
        guard isIPSW(zip) else { return nil }
        let bm = plist(zip, "BuildManifest.plist") ?? [:]
        let types = (bm["SupportedProductTypes"] as? [String]) ?? []
        return DeviceIcon.firmware(types: types)
    }

    /// Finder / Files thumbnail: the same page, but filling the whole thumbnail (the system draws the frame).
    /// The folded-corner version was tried here too; the plain page looked more natural inside the system's frame.
    static func thumbnail(_ zip: Zip) -> CGImage? {
        guard isIPSW(zip) else { return nil }
        let types = (plist(zip, "BuildManifest.plist")?["SupportedProductTypes"] as? [String]) ?? []
        return DeviceIcon.document(symbol: DeviceIcon.symbolName(DeviceIcon.shape(for: types)), label: "IPSW", fullPage: true)
    }

    static func report(url: URL, zip: Zip, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .ipsw, path: url.path, title: url.lastPathComponent)
        let bm = plist(zip, "BuildManifest.plist") ?? [:]
        let restore = plist(zip, "Restore.plist") ?? [:]
        let types = (bm["SupportedProductTypes"] as? [String]) ?? (restore["SupportedProductTypes"] as? [String]) ?? []
        let os = osName(types)
        let version = (bm["ProductVersion"] as? String) ?? (restore["ProductVersion"] as? String)
        let build = (bm["ProductBuildVersion"] as? String) ?? (restore["ProductBuildVersion"] as? String)
        let identities = (bm["BuildIdentities"] as? [[String: Any]]) ?? []
        rep.title = "\(os) \(version ?? "")".trimmingCharacters(in: .whitespaces) + (build.map { " (\($0))" } ?? "")
        rep.icon = DeviceIcon.firmware(types: types)
        rep.subtitle = L("ファームウェア復元イメージ (ipsw)", "Firmware restore image (ipsw)") + " · " + L("\(types.count) 機種", "\(types.count) device\(types.count == 1 ? "" : "s")")

        // Devices
        let deviceMap = (restore["DeviceMap"] as? [[String: Any]]) ?? []
        var boards = [String: [String]]()   // product type → board configs
        for id in identities {
            guard let info = id["Info"] as? [String: Any], let cls = info["DeviceClass"] as? String else { continue }
            let pt = (id["Ap,ProductType"] as? String) ?? ""
            if !pt.isEmpty, !(boards[pt] ?? []).contains(cls) { boards[pt, default: []].append(cls) }
        }
        let platforms = Dictionary(deviceMap.compactMap { m -> (String, String)? in
            guard let b = (m["BoardConfig"] as? String)?.lowercased(), let p = m["Platform"] as? String else { return nil }
            return (b, p)
        }, uniquingKeysWith: { a, _ in a })
        let deviceRows: [[String]] = types.map { t in
            let bs = boards[t] ?? []
            // Platform codes from the file itself, else from the built-in device table.
            var codes = Array(Set(bs.compactMap { platforms[$0.lowercased()]?.lowercased() })).sorted()
            if codes.isEmpty { codes = DeviceNames.platforms[t] ?? [] }
            let plat = codes.map { DeviceNames.chip($0) }.joined(separator: ", ")
            return [t, names[t] ?? "", bs.joined(separator: ", "), plat]
        }

        // Variants (erase / update …)
        var variants = [String]()
        for id in identities {
            if let info = id["Info"] as? [String: Any], let v = info["Variant"] as? String, !variants.contains(v) { variants.append(v) }
        }
        let behaviors = Set(identities.compactMap { ($0["Info"] as? [String: Any])?["RestoreBehavior"] as? String })

        // Disk images
        let dmgs = zip.entries.filter { !$0.name.contains("/") && ($0.name.hasSuffix(".dmg") || $0.name.hasSuffix(".dmg.aea")) }.sorted { $0.size > $1.size }
        let encryptedOS = dmgs.first?.name.hasSuffix(".aea") == true
        let fsMap = (restore["SystemRestoreImageFileSystems"] as? [String: String]) ?? [:]
        let osImages = Set(((restore["SystemRestoreImages"] as? [String: String]) ?? [:]).values)

        // Components of the first identity
        var comps = [[String]]()
        var bootVersion: String?
        var bootEncrypted: Bool?
        if let manifest = identities.first?["Manifest"] as? [String: Any] {
            for key in manifest.keys.sorted() {
                guard let c = manifest[key] as? [String: Any], let path = (c["Info"] as? [String: Any])?["Path"] as? String else { continue }
                let e = zip.entry(path)
                comps.append([key, path, e.map { byteSize($0.size) } ?? L("（同梱なし）", "(not in the file)")])
                if key == "iBoot" || (key == "LLB" && bootVersion == nil), let e, e.size < 8 << 20, let d = zip.read(e), let h = im4p(d) {
                    if key == "iBoot" || bootVersion == nil { bootVersion = h.description; bootEncrypted = h.encrypted }
                }
            }
        }
        let baseband = zip.entries.filter { $0.name.hasSuffix(".bbfw") }

        rep.badges.append(Badge(text: os, tone: .info))
        if encryptedOS { rep.badges.append(Badge(text: L("システムイメージは暗号化 (AEA)", "OS image encrypted (AEA)"), tone: .neutral)) }
        if behaviors.contains("Update") && behaviors.contains("Erase") { rep.badges.append(Badge(text: L("復元・アップデート両対応", "Erase + Update"), tone: .neutral)) }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("\(os) のファームウェア (ipsw)", "\(os) firmware (ipsw)", "\(os) 韌體 (ipsw)"))
        sum.add(L("バージョン", "Version"), version)
        sum.add(L("ビルド", "Build"), build, mono: true)
        sum.add(L("対応機種", "Devices"), types.count <= 6 ? types.map { t in names[t].map { "\($0) (\(t))" } ?? t }.joined(separator: "\n") : "\(types.count)" + L(" 機種（下の一覧を参照）", " devices (see the list below)"))
        sum.add(L("iBoot", "iBoot"), bootVersion, mono: true)
        sum.add(L("ブートローダーの暗号化", "Bootloader encryption"), bootEncrypted.map { $0 ? L("あり", "Encrypted") : L("なし", "Not encrypted") })
        sum.add(L("システムイメージ", "OS image"), dmgs.first.map { "\($0.name)（\(byteSize($0.size))）" }, mono: true)
        sum.add(L("ベースバンド", "Baseband"), baseband.isEmpty ? nil : baseband.map { ($0.name as NSString).lastPathComponent }.joined(separator: ", "), mono: true)
        sum.add(L("復元の種類", "Variants"), variants.prefix(6).joined(separator: "\n"))
        sum.add(L("サイズ", "Size"), byteSize(fileSize) + L("（展開後 ", " (unpacked ") + byteSize(zip.totalUncompressed) + L("、\(zip.entries.count) 項目）", ", \(zip.entries.count) items)", "，\(zip.entries.count) 個項目）"))
        rep.summary = sum

        if !deviceRows.isEmpty {
            rep.sections.append(ReportSection(id: "devices", title: L("対応機種", "Supported Devices"), symbol: "iphone",
                blocks: [.table(TableData(columns: [L("識別子", "Identifier"), L("名前", "Name"), L("ボード", "Board"), L("チップ", "Platform")], rows: deviceRows)),
                         .note(L("Apple がこのバージョンをまだ署名しているか（＝今も復元に使えるか）は、通信が必要なので確認していません。", "Whether Apple still signs this version (i.e. whether it can still be restored) needs a network check and is not shown."))],
                count: deviceRows.count))
        }
        if !dmgs.isEmpty {
            rep.sections.append(ReportSection(id: "images", title: L("ディスクイメージ", "Disk Images"), symbol: "opticaldiscdrive",
                blocks: [.table(TableData(columns: [L("ファイル", "File"), L("サイズ", "Size"), L("用途", "Role"), L("形式", "Format")], rows: dmgs.map {
                    [$0.name, byteSize($0.size),
                     osImages.contains($0.name) || $0.name == dmgs.first?.name ? L("システム", "OS") : L("復元用 RAM ディスクなど", "Restore ramdisk etc."),
                     $0.name.hasSuffix(".aea") ? L("暗号化 (AEA)", "Encrypted (AEA)") : (fsMap[$0.name] ?? "dmg")]
                }))], count: dmgs.count))
        }
        if !identities.isEmpty {
            let rows: [[String]] = identities.prefix(opts.deep ? 2000 : 200).map { id in
                let info = (id["Info"] as? [String: Any]) ?? [:]
                return [(id["Ap,ProductType"] as? String) ?? "", (info["DeviceClass"] as? String) ?? "", (id["ApChipID"] as? String) ?? "", (id["ApBoardID"] as? String) ?? "",
                        (info["RestoreBehavior"] as? String) ?? "", (info["Variant"] as? String) ?? ""]
            }
            rep.sections.append(ReportSection(id: "identities", title: L("ビルド構成", "Build Identities"), symbol: "list.bullet.rectangle",
                blocks: [.table(TableData(columns: [L("機種", "Product"), L("ボード", "Board"), "CPID", "BDID", L("動作", "Behavior"), L("種類", "Variant")], rows: rows, total: identities.count))],
                count: identities.count))
        }
        if !comps.isEmpty {
            rep.sections.append(ReportSection(id: "components", title: L("コンポーネント（1 つ目の構成）", "Components (first identity)"), symbol: "cpu",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("パス", "Path"), L("サイズ", "Size")], rows: comps))], count: comps.count))
        }
        rep.sections.append(IPA.largestFiles(zip, strip: "", deep: opts.deep))
        return rep
    }
}
