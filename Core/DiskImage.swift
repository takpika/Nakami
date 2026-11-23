import Foundation
import CoreGraphics

/// Disk images: Apple .dmg files and raw images with a partition table (macOS install media, OpenCore, SD cards …).
enum DiskImage {
    static let macNames: [(prefix: String, name: String)] = [
        ("10.0", "Cheetah"), ("10.1", "Puma"), ("10.2", "Jaguar"), ("10.3", "Panther"), ("10.4", "Tiger"), ("10.5", "Leopard"), ("10.6", "Snow Leopard"),
        ("10.7", "Lion"), ("10.8", "Mountain Lion"), ("10.9", "Mavericks"), ("10.10", "Yosemite"), ("10.11", "El Capitan"), ("10.12", "Sierra"),
        ("10.13", "High Sierra"), ("10.14", "Mojave"), ("10.15", "Catalina"), ("11", "Big Sur"), ("12", "Monterey"), ("13", "Ventura"), ("14", "Sonoma"),
        ("15", "Sequoia"), ("26", "Tahoe"),
    ]

    static func macOSName(_ version: String) -> String {
        let parts = version.split(separator: ".")
        let key = parts.first == "10" ? parts.prefix(2).joined(separator: ".") : String(parts.first ?? "")
        let code = macNames.first { $0.prefix == key }?.name
        let product = parts.first == "10" ? (Int(parts.count > 1 ? parts[1] : "0") ?? 0 >= 12 ? "macOS" : (Int(parts.count > 1 ? parts[1] : "0") ?? 0 >= 8 ? "OS X" : "Mac OS X")) : "macOS"
        return product + (code.map { " " + $0 } ?? "") + " " + version
    }

    struct Found {
        var title: String?
        var kind: String?
        var badges: [Badge] = []
        var rows: [Row] = []
        var sections: [ReportSection] = []
        var icon: CGImage?
    }

    /// What a mounted HFS+ volume contains: a macOS installer, a system, or apps to drag out.
    static func inspect(_ fs: MacVolume, depth: Int = 0) -> Found {
        if let c = fs as? ClassicVolume { return inspectClassic(c) }
        var f = Found()
        let root = fs.entries("")
        let apps = root.filter { $0.isDir && $0.name.hasSuffix(".app") }

        // ---- "Install macOS Xxx.app" (createinstallmedia-style media, or the installer app on a disk image)
        if let inst = apps.first(where: { n in ["Install macOS", "Install OS X", "Install Mac OS X"].contains { n.name.hasPrefix($0) } }) {
            let base = inst.name
            let info = fs.plist("\(base)/Contents/Info.plist") ?? [:]
            var version: String?, build: String?
            // macOS 11 and later: the real OS version is recorded inside SharedSupport.dmg.
            if depth == 0, let ss = fs.device("\(base)/Contents/SharedSupport/SharedSupport.dmg"), let dmg = DMGDevice(ss),
               let vol = volumes(dmg).first(where: { $0.vol != nil })?.vol,
               let xml = vol.plist("com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml"),
               let asset = (xml["Assets"] as? [[String: Any]])?.first {
                version = asset["OSVersion"] as? String
                build = asset["Build"] as? String
            }
            // 10.7 – 10.15: InstallInfo.plist names the system image.
            if version == nil, let ii = fs.plist("\(base)/Contents/SharedSupport/InstallInfo.plist"), let sys = ii["System Image Info"] as? [String: Any] {
                version = sys["version"] as? String
                build = sys["build"] as? String
            }
            // Recovery-style media and the old install DVDs: the volume itself is a small system, which says its version.
            if version == nil, let sv = fs.plist("System/Library/CoreServices/SystemVersion.plist") {
                version = sv["ProductVersion"] as? String
                build = sv["ProductBuildVersion"] as? String
            }
            let display = (info["CFBundleDisplayName"] as? String) ?? String(base.dropLast(4))
            f.kind = L("macOS のインストールメディア", "macOS installation media")
            f.title = version.map { macOSName($0) + (build.map { " (\($0))" } ?? "") } ?? display
            f.badges.append(Badge(text: "macOS", tone: .info))
            f.rows.add(L("インストーラー", "Installer"), base, mono: true)
            f.rows.add(L("macOS のバージョン", "macOS version"), version.map { $0 + (build.map { " (\($0))" } ?? "") })
            f.rows.add(L("インストーラーのバージョン", "Installer version"), info["CFBundleShortVersionString"] as? String)
            f.rows.add(L("動作に必要な OS", "Runs on"), (info["LSMinimumSystemVersion"] as? String).map { "macOS \($0) " + L("以降", "or later") })
            if let icns = (info["CFBundleIconFile"] as? String).map({ $0.hasSuffix(".icns") ? $0 : $0 + ".icns" }), let d = fs.data("\(base)/Contents/Resources/\(icns)", max: 16 << 20) {
                f.icon = ImageKit.decode(d)
            }
            return f
        }

        // ---- An installed or bootable system: SystemVersion.plist says what it is.
        if let sv = fs.plist("System/Library/CoreServices/SystemVersion.plist"), let ver = sv["ProductVersion"] as? String,
           let product = sv["ProductName"] as? String, product.contains("Mac") || product.contains("macOS") || product.contains("OS X") {
            let build = sv["ProductBuildVersion"] as? String
            let installer = root.contains { $0.name.hasPrefix("Install Mac OS X") || $0.name == "Install OS X.app" } || fs.exists("System/Installation")
            f.kind = installer ? L("Mac OS X のインストールディスク", "Mac OS X installation disc") : L("macOS のシステムが入ったボリューム", "Volume with a macOS system")
            f.title = macOSName(ver) + (build.map { " (\($0))" } ?? "")
            f.badges.append(Badge(text: (sv["ProductName"] as? String) ?? "macOS", tone: .info))
            f.rows.add(L("製品", "Product"), sv["ProductName"] as? String)
            f.rows.add(L("バージョン", "Version"), ver + (build.map { " (\($0))" } ?? ""))
            return f
        }

        // ---- Ordinary app disk image: the app(s) to drag out.
        if let app = apps.first {
            let info = fs.plist("\(app.name)/Contents/Info.plist") ?? [:]
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? String(app.name.dropLast(4))
            let short = info["CFBundleShortVersionString"] as? String, build = info["CFBundleVersion"] as? String
            f.kind = L("アプリのディスクイメージ", "App disk image")
            f.title = name
            f.rows.add(L("アプリ", "App"), apps.map { $0.name }.joined(separator: "\n"), mono: true)
            f.rows.add(L("バージョン", "Version"), short.map { $0 + (build != nil && build != $0 ? " (\(build!))" : "") } ?? build)
            f.rows.add(L("識別子", "Identifier"), info["CFBundleIdentifier"] as? String, mono: true)
            f.rows.add(L("対応 OS", "Requires"), (info["LSMinimumSystemVersion"] as? String).map { "macOS \($0) " + L("以降", "or later") })
            f.rows.add(L("著作権", "Copyright"), info["NSHumanReadableCopyright"] as? String)
            if root.contains(where: { $0.name == "Applications" || $0.name == " " }) { f.rows.add(L("インストール方法", "Install by"), L("アプリケーションフォルダーへドラッグ", "Dragging to Applications")) }
            if let icns = (info["CFBundleIconFile"] as? String).map({ $0.hasSuffix(".icns") ? $0 : $0 + ".icns" }), let d = fs.data("\(app.name)/Contents/Resources/\(icns)", max: 16 << 20) {
                f.icon = ImageKit.decode(d)
            }
            return f
        }
        // ---- Simulator runtime for Xcode (iOS / tvOS / watchOS / visionOS)
        let runtimes = "Library/Developer/CoreSimulator/Profiles/Runtimes"
        if let rt = fs.entries(runtimes).first(where: { $0.name.hasSuffix(".simruntime") }) {
            let base = "\(runtimes)/\(rt.name)/Contents"
            let info = fs.plist("\(base)/Info.plist") ?? [:]
            let sv = fs.plist("\(base)/Resources/RuntimeRoot/System/Library/CoreServices/SystemVersion.plist") ?? [:]
            let product = (sv["ProductName"] as? String) ?? String(rt.name.dropLast(11))
            let version = sv["ProductVersion"] as? String, build = sv["ProductBuildVersion"] as? String
            f.kind = L("Xcode 用のシミュレーターランタイム", "Simulator runtime for Xcode")
            f.title = (info["CFBundleName"] as? String) ?? String(rt.name.dropLast(11))
            f.badges.append(Badge(text: L("シミュレーター", "Simulator"), tone: .info))
            f.rows.add(L("OS", "OS"), ["iPhone OS": "iOS", "Apple TVOS": "tvOS", "xrOS": "visionOS", "Watch OS": "watchOS"][product] ?? product)
            f.rows.add(L("バージョン", "Version"), version.map { $0 + (build.map { " (\($0))" } ?? "") })
            f.rows.add(L("識別子", "Identifier"), info["CFBundleIdentifier"] as? String, mono: true)
            let archs = (fs.plist("\(base)/Resources/profile.plist")?["supportedArchs"] as? [String]) ?? []
            f.rows.add(L("対応する Mac の CPU", "Host architectures"), archs.joined(separator: ", "))
            f.rows.add(L("動作に必要な macOS", "Requires"), (fs.plist("\(base)/Resources/profile.plist")?["minHostVersion"] as? String).map { "macOS \($0) " + L("以降", "or later") })
            return f
        }
        let pkgs = root.filter { $0.name.hasSuffix(".pkg") || $0.name.hasSuffix(".mpkg") }
        if !pkgs.isEmpty {
            f.kind = L("インストーラーの入ったディスクイメージ", "Disk image with an installer")
            f.rows.add(L("インストーラー", "Installer"), pkgs.map { $0.name }.joined(separator: "\n"), mono: true)
        }
        return f
    }

    /// What a FAT volume holds: DOS / early Windows floppies, EFI boot files.
    static func inspect(_ fat: FAT) -> Found {
        var f = Found()
        let root = fat.list()
        let names = Set(root.map { $0.name.uppercased() })
        func version(_ file: String) -> String? {
            guard let i = fat.item(file), let d = fat.read(i, max: 512 << 10) else { return nil }
            let text = String(decoding: d, as: Unicode.ASCII.self)
            return firstMatch(text, #"(?:MS-DOS|PC[- ]DOS|DOS)\s+[Vv]ersion\s+(\d+\.\d+)"#) ?? firstMatch(text, #"[Vv]ersion\s+(\d+\.\d\d)"#)
        }
        let nec = fat.oem.uppercased().hasPrefix("NEC") || fat.bytesPerSector == 1024
        if nec { f.badges.append(Badge(text: "PC-98", tone: .info)) }
        if names.contains("IO.SYS") && names.contains("MSDOS.SYS") {
            let v = version("COMMAND.COM")
            f.kind = L("MS-DOS の起動ディスク", "MS-DOS boot disk")
            f.title = "MS-DOS" + (v.map { " " + $0 } ?? "")
            f.badges.append(Badge(text: "MS-DOS", tone: .info))
            f.rows.add(L("バージョン", "Version"), v)
        } else if names.contains("IBMBIO.COM") && names.contains("IBMDOS.COM") {
            let v = version("COMMAND.COM")
            f.kind = L("PC DOS の起動ディスク", "PC DOS boot disk")
            f.title = "IBM PC DOS" + (v.map { " " + $0 } ?? "")
            f.badges.append(Badge(text: "PC DOS", tone: .info))
            f.rows.add(L("バージョン", "Version"), v)
        } else if names.contains("KERNEL.SYS") {
            f.kind = L("FreeDOS の起動ディスク", "FreeDOS boot disk")
            f.title = "FreeDOS"
        } else if names.contains("WIN.COM") || names.contains("WIN.CNF") || names.contains("WINVER.EXE") || (names.contains("SETUP.EXE") && names.contains(where: { $0.hasPrefix("WIN") })) {
            f.kind = L("Windows のセットアップディスク（フロッピー）", "Windows setup floppy")
            f.badges.append(Badge(text: "Windows", tone: .info))
        } else if fat.item("EFI/OC/OpenCore.efi") != nil {
            f.kind = L("OpenCore ブートローダーのディスク", "OpenCore boot loader disk")
            f.title = "OpenCore"
            f.rows.add(L("ドライバー", "Drivers"), fat.list(fat.item("EFI/OC/Drivers")).map { $0.name }.joined(separator: ", "))
            f.rows.add("Kexts", fat.list(fat.item("EFI/OC/Kexts")).map { $0.name }.joined(separator: ", "))
        } else if let boot = fat.item("EFI/BOOT") {
            f.kind = L("EFI 起動用のディスク", "EFI boot disk")
            f.rows.add(L("起動ファイル", "Boot files"), fat.list(boot).filter { !$0.isDir }.map { $0.name }.joined(separator: ", "), mono: true)
        }
        f.sections.append(ReportSection(id: "root", title: L("最上位のファイル", "Top-level Files"), symbol: "folder",
            blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: root.map { [$0.name + ($0.isDir ? "/" : ""), $0.isDir ? "" : byteSize($0.size)] }))], count: root.count))
        if nec { f.rows.insert(Row(L("対応機種", "Machine"), L("NEC PC-9800 シリーズ", "NEC PC-9800 series")), at: 0) }
        f.rows.add(L("ボリューム名", "Volume name"), fat.label)
        f.rows.add(L("フォーマットした OS", "Formatted by"), fat.oem.isEmpty ? nil : fat.oem, mono: true)
        // What the disk starts when booted.
        for n in ["AUTOEXEC.BAT", "CONFIG.SYS"] {
            guard let i = fat.item(n), i.size > 0, i.size < 16 << 10, let d = fat.read(i) else { continue }
            let text = (String(data: d, encoding: .shiftJIS) ?? String(decoding: d, as: Unicode.ASCII.self)).replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n\u{1a} "))
            if !text.isEmpty { f.sections.append(ReportSection(id: n.lowercased(), title: n, symbol: "doc.text", blocks: [.text(text)])) }
        }
        return f
    }

    /// `apfs` keeps the container alive for as long as its volume is in use.
    static func volumes(_ dev: BlockDevice, parts given: [Partition]? = nil) -> [(part: Partition, fsName: String, label: String?, vol: MacVolume?, apfs: APFS?)] {
        var parts = given ?? PartitionMap.detect(dev)?.parts ?? []
        if parts.isEmpty { parts = [Partition(name: "", type: L("（パーティション表なし）", "(no partition table)"), start: 0, size: dev.size)] }
        return parts.map { p in
            let sub = SubDevice(parent: dev, base: p.start, size: Swift.min(p.size, Swift.max(0, dev.size - p.start)))
            let fs = PartitionMap.fileSystem(sub)
            if fs?.name == "APFS", let c = APFS(sub) {
                let v = c.mainVolume
                return (p, "APFS", v?.volumeName ?? c.volumes.first?.volumeName, v, c)
            }
            if fs?.name == "HFS", let c = HFSClassic(sub) { return (p, "HFS", c.volumeName, c, nil) }
            if fs?.name == "MFS", let c = MFSVolume(sub) { return (p, "MFS", c.volumeName, c, nil) }
            let hfs = (fs?.name.hasPrefix("HFS") == true) ? HFSPlus(sub) : nil
            return (p, fs?.name ?? "", hfs?.volumeName.isEmpty == false ? hfs!.volumeName : fs?.label, hfs, nil)
        }
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions, requireApple: Bool = false) -> Report? {
        let file = DataDevice(data)
        let encrypted = file.string(0, 8) == "encrcdsa" || file.string(data.count - 8 > 0 ? data.count - 8 : 0, 8) == "cdsaencr"
        var dev: BlockDevice = file
        var dmg: DMGDevice?
        var diskCopy: (name: String, format: String)?
        if let d = DMGDevice(file) { dmg = d; dev = d }
        else if let dc = diskCopy42(file) { dev = dc.device; diskCopy = (dc.name, dc.format) }
        // PC-98 emulator images: a header (or per-sector records) around the disk, and the PC-98's own partition table.
        var pc98: PC98.Image?
        var pc98Parts: [Partition]?
        if dmg == nil, diskCopy == nil, let p = PC98.open(data, ext: url.pathExtension.lowercased()) {
            pc98 = p
            dev = p.device
            if let g = p.geometry { pc98Parts = PC98.partitions(dev, geometry: g) }
        } else if dmg == nil, diskCopy == nil, file.string(4, 4) == "IPL1" {
            // A raw PC-98 hard disk dump: try the common geometries.
            for g in [(0, 8, 17, 512), (0, 8, 33, 256), (0, 16, 63, 512), (0, 8, 32, 512)] {
                if let ps = PC98.partitions(dev, geometry: (g.0, g.1, g.2, g.3)), ps.allSatisfy({ PartitionMap.fileSystem(SubDevice(parent: dev, base: $0.start, size: Swift.min($0.size, dev.size - $0.start))) != nil }) { pc98Parts = ps; break }
            }
        }
        let scheme = pc98Parts != nil ? L("PC-98 のパーティション表", "PC-98 partition table") : PartitionMap.detect(dev)?.scheme
        let vols = volumes(dev, parts: pc98Parts)
        let isDMG = dmg != nil || encrypted || url.pathExtension.lowercased() == "dmg"
        if !isDMG {
            guard scheme != nil || pc98 != nil || vols.contains(where: { !$0.fsName.isEmpty }) else { return nil }
            if requireApple {
                // Only take over from the ISO 9660 view when the Apple side really is a Mac system or installer
                // (Linux hybrid discs also carry a small HFS+ part just so Macs can boot them).
                guard let h = vols.compactMap({ $0.vol }).max(by: { $0.totalBytes < $1.totalBytes }), inspect(h, depth: 1).badges.isEmpty == false else { return nil }
            }
        }

        var rep = Report(kind: .disk, path: url.path, title: url.lastPathComponent)
        var kind = isDMG ? L("ディスクイメージ (dmg)", "Disk image (dmg)") : L("ディスクイメージ", "Disk image")
        var found = Found()
        var appReport: Report?
        let main = vols.compactMap({ $0.vol }).max(by: { $0.totalBytes < $1.totalBytes })
        if let hfs = main {
            found = inspect(hfs)
            // An app to drag out: analyse it in full, exactly like an app on disk (signature, entitlements,
            // extensions, privacy, libraries …), reading its files straight out of the image.
            if found.kind == L("アプリのディスクイメージ", "App disk image"),
               let app = hfs.entries("").first(where: { $0.isDir && $0.name.hasSuffix(".app") }) {
                let files = hfs.tree(under: app.name, limit: 30_000)
                let entries: [Zip.Entry] = files.enumerated().map { i, f in Zip.Entry(name: f.path, method: 0, compSize: f.size, size: f.size, headerOffset: i) }
                let zip = Zip(entries: entries, label: "dmg") { e in files[e.headerOffset].read() }
                if let dir = IPA.appDir(zip) { appReport = IPA.report(url: url, zip: zip, dir: dir, fileSize: data.count, opts: opts) }
            }
        }
        else if let v = vols.filter({ $0.fsName.hasPrefix("FAT") }).max(by: { $0.part.size < $1.part.size }),
                let fat = FAT(SubDevice(parent: dev, base: v.part.start, size: Swift.min(v.part.size, Swift.max(0, dev.size - v.part.start)))) {
            found = inspect(fat)
            if found.kind == nil, dev.size <= 3 << 20 { found.kind = L("フロッピーディスクのイメージ", "Floppy disk image") }
        }
        if let k = found.kind { kind = k }
        if let t = found.title, !t.isEmpty { rep.title = t }
        else if let label = vols.compactMap({ $0.label }).first(where: { !$0.isEmpty }) { rep.title = label }
        rep.icon = found.icon
        rep.badges = found.badges
        if encrypted { rep.badges.append(Badge(text: L("暗号化", "Encrypted"), tone: .warn)) }
        if vols.contains(where: { $0.fsName == "APFS" }) && found.kind == nil { rep.badges.append(Badge(text: "APFS", tone: .neutral)) }
        let apfsVolumes = vols.compactMap { $0.apfs }.flatMap { $0.volumes }
        rep.subtitle = kind

        var sum = [Row(L("種類", "Kind"), kind)]
        if let a = appReport {
            // The app's own facts first (minus its "kind" and size lines, which describe the image here).
            rep.badges = a.badges
            if rep.icon == nil { rep.icon = a.icon }
            sum.append(contentsOf: a.summary.filter { $0.key != L("種類", "Kind") && $0.key != L("サイズ", "Size") })
            if let more = found.rows.first(where: { $0.key == L("インストール方法", "Install by") }) { sum.append(more) }
        } else {
            sum.append(contentsOf: found.rows)
        }
        if let dmg {
            let c = dmg.compressions
            sum.add(L("圧縮", "Compression"), c.isEmpty ? L("なし", "None") : c.joined(separator: ", "))
            if dmg.hasUnreadableChunks { sum.add(L("中身の読み取り", "Reading the contents"), L("ADC 圧縮（とても古い形式）の部分は展開できないため、中のファイルは読めていない可能性があります", "ADC-compressed chunks (a very old method) cannot be expanded here, so files inside may be unreadable"), tone: .warn) }
            sum.add(L("使用許諾の表示", "License agreement"), dmg.hasLicense ? L("あり", "Yes") : nil)
            sum.add(L("展開後のサイズ", "Expanded size"), byteSize(dmg.size))
        }
        if let p = pc98 {
            sum.add(L("イメージの形式", "Image format"), p.format)
            sum.append(contentsOf: p.rows)
            if let g = p.geometry { sum.add(L("ディスクの形", "Geometry"), L("\(g.cylinders) シリンダー × \(g.heads) ヘッド × \(g.sectors) セクター、1 セクター \(g.sectorSize) バイト（\(byteSize(dev.size))）", "\(g.cylinders) cylinders × \(g.heads) heads × \(g.sectors) sectors of \(g.sectorSize) bytes (\(byteSize(dev.size)))", "\(g.cylinders) 磁柱 × \(g.heads) 磁頭 × \(g.sectors) 磁區，每磁區 \(g.sectorSize) 位元組（\(byteSize(dev.size))）")) }
            if found.kind == nil, vols.allSatisfy({ $0.fsName.isEmpty }) {
                // No file system DOS would read: games and BASIC disks boot their own loader.
                let boots = dev.read(0, 16).map { $0.contains { $0 != 0 && $0 != 0xe5 } } ?? false
                sum.add(L("中身", "Contents"), boots ? L("DOS のファイルシステムではありません（独自の形式で、起動用のプログラムが書かれています）", "Not a DOS file system (its own format, with a boot program)") : L("DOS のファイルシステムではありません", "Not a DOS file system"))
            }
        }
        if let dc = diskCopy { sum.add(L("イメージの形式", "Image format"), "Disk Copy 4.2" + (dc.format.isEmpty ? "" : L("（\(dc.format) フロッピー）", " (\(dc.format) floppy)", "（\(dc.format) 軟碟）"))) }
        if encrypted { sum.add(L("暗号化", "Encryption"), L("パスワードで保護されているため、中身は読めません", "Password-protected: the contents cannot be read"), tone: .warn) }
        sum.add(L("パーティション方式", "Partition scheme"), scheme)
        if let h = main {
            sum.add(L("ボリューム名", "Volume name"), h.volumeName)
            if !(h is ClassicVolume) { sum.add(L("ファイルシステム", "File system"), vols.first(where: { $0.vol === h })?.fsName) }
            sum.add(L("ファイル数", "Files"), "\(h.fileCount)" + L(" 個（フォルダー \(h.folderCount) 個）", " (\(h.folderCount) folders)", " 個（檔案夾 \(h.folderCount) 個）"))
            if let c = h.created { sum.add(L("作成日時", "Created"), dateString(c)) }
        } else if !apfsVolumes.isEmpty, apfsVolumes.allSatisfy({ $0.encrypted }) {
            sum.add(L("中身の読み取り", "Reading the contents"), L("APFS のボリュームが暗号化されているため、中のファイルは読めません", "The APFS volume is encrypted, so files inside cannot be read"), tone: .warn)
        }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        rep.sections = found.sections + (appReport?.sections.filter { $0.id != "files" } ?? [])

        if scheme != nil || vols.count > 1 || vols.first?.fsName.isEmpty == false {
            rep.sections.append(ReportSection(id: "partitions", title: L("パーティション", "Partitions"), symbol: "square.split.2x1",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("種類", "Type"), L("ファイルシステム", "File system"), L("ボリューム名", "Label"), L("サイズ", "Size")],
                                          rows: vols.map { [$0.part.name, $0.part.type, $0.fsName, $0.label ?? "", byteSize($0.part.size)] }))], count: vols.count))
        }
        if apfsVolumes.count > 1 || apfsVolumes.contains(where: { $0.encrypted || $0.role != 0 }) {
            rep.sections.append(ReportSection(id: "apfs", title: L("APFS のボリューム", "APFS Volumes"), symbol: "externaldrive",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("役割", "Role"), L("ファイル数", "Files"), L("使用量", "Used"), L("状態", "State")],
                                          rows: apfsVolumes.map { [$0.volumeName, $0.roleName, "\($0.fileCount)", byteSize($0.totalBytes),
                                                                   $0.encrypted ? L("暗号化", "Encrypted") : $0.sealed ? L("封印済み（改変検知つき）", "Sealed") : ""] }))], count: apfsVolumes.count))
        }
        if let hfs = main, !(hfs is ClassicVolume) {
            let root = hfs.entries("").filter { !$0.name.hasPrefix(".") || opts.deep }
            if !root.isEmpty {
                rep.sections.append(ReportSection(id: "root", title: L("最上位のファイル", "Top-level Files"), symbol: "folder",
                    blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: root.map { [$0.name + ($0.isDir ? "/" : ""), $0.isDir ? "" : byteSize($0.size)] }))], count: root.count))
            }
        }
        return rep
    }

    /// The icon of the app (or installer) inside a disk image, for Finder / Files thumbnails.
    static func icon(_ data: Data) -> CGImage? {
        let file = DataDevice(data)
        var dev: BlockDevice = file
        if let d = DMGDevice(file) { dev = d } else if let dc = diskCopy42(file) { dev = dc.device }
        else if PartitionMap.detect(file) == nil, PartitionMap.fileSystem(file)?.name.hasSuffix("FS") != true { return nil }
        let vols = volumes(dev)
        guard let hfs = vols.compactMap({ $0.vol }).max(by: { $0.totalBytes < $1.totalBytes }) else { return nil }
        return inspect(hfs, depth: 1).icon
    }
}
