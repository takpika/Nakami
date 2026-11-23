import Foundation

/// Recognises operating-system installation discs and reads what they say about themselves.
enum OSInstaller {
    struct Result {
        var title: String?
        var kind: String
        var badges: [Badge] = []
        var rows: [Row] = []
        var sections: [ReportSection] = []
    }

    /// Windows imaging file (install.wim / install.esd / boot.wim): the XML catalogue of the images inside.
    static func wim(_ fs: DiscFS, _ path: String) -> (images: [[String: String]], compression: String)? {
        wim { fs.read(path, offset: $0, length: $1) }
    }

    static func wim(read: (Int, Int) -> Data?) -> (images: [[String: String]], compression: String)? {
        guard let h = read(0, 208), h.count == 208 else { return nil }
        let r = Reader(h, little: true)
        guard r.fixedStr(0, 5) == "MSWIM" else { return nil }
        let flags = r.u32(16)
        let compression = flags & 0x20000 != 0 ? "XPRESS" : flags & 0x40000 != 0 ? "LZX" : flags & 0x80000 != 0 ? "LZMS" : flags & 2 != 0 ? L("圧縮あり", "compressed") : L("無圧縮", "uncompressed")
        let xmlSize = Int(r.u64(72) & 0x00ff_ffff_ffff_ffff), xmlOff = Int(clamping: r.u64(80))
        guard xmlSize > 0, xmlSize < 32 << 20, let xml = read(xmlOff, xmlSize), let root = XMLNode.parse(xml) else { return ([], compression) }
        var images = [[String: String]]()
        for img in root.all("IMAGE") {
            var d = ["INDEX": img.attrs["INDEX"] ?? ""]
            func t(_ n: XMLNode?, _ k: String) -> String? { n?.first(k)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            for k in ["NAME", "DESCRIPTION", "DISPLAYNAME", "DISPLAYDESCRIPTION", "TOTALBYTES", "FLAGS"] { if let v = t(img, k), !v.isEmpty { d[k] = v } }
            if let w = img.first("WINDOWS") {
                for k in ["ARCH", "PRODUCTNAME", "EDITIONID", "INSTALLATIONTYPE", "PRODUCTTYPE"] { if let v = t(w, k), !v.isEmpty { d[k] = v } }
                if let v = w.first("VERSION") {
                    d["VERSION"] = [t(v, "MAJOR"), t(v, "MINOR"), t(v, "BUILD"), t(v, "SPBUILD")].compactMap { $0 }.joined(separator: ".")
                    d["BUILD"] = t(v, "BUILD")
                }
                d["LANGUAGES"] = (w.first("LANGUAGES")?.all("LANGUAGE") ?? []).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
            }
            if let c = img.first("CREATIONTIME"), let hi = t(c, "HIGHPART"), let lo = t(c, "LOWPART"),
               let h = UInt64(hi.replacingOccurrences(of: "0x", with: ""), radix: 16), let l = UInt64(lo.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                let ft = h << 32 | l
                d["CREATED"] = dateString(Date(timeIntervalSince1970: Double(ft) / 1e7 - 11_644_473_600))
            }
            images.append(d)
        }
        return (images, compression)
    }

    /// Title, product rows and the edition table for the images of a Windows imaging file.
    static func describe(_ images: [[String: String]], into res: inout Result) {
    let first = images.first { ($0["INSTALLATIONTYPE"] ?? "") != "WindowsPE" } ?? images.first
    if let f = first {
        let build = Int(f["BUILD"] ?? "") ?? 0
        let server = (f["INSTALLATIONTYPE"] ?? "").lowercased().contains("server") || (f["PRODUCTTYPE"] ?? "") == "ServerNT"
        let servicing = Int((f["VERSION"] ?? "").split(separator: ".").last ?? "") ?? 0
        var product = windowsName(build, server: server) ?? f["PRODUCTNAME"] ?? "Windows"
        // Products that share a Windows build but are sold under their own name.
        let imageName = f["DISPLAYNAME"] ?? f["NAME"] ?? ""
        for special in ["Home Server", "Embedded", "Thin PC", "MultiPoint", "Essentials", "Storage Server", "Hyper-V Server", "IoT"] where imageName.contains(special) {
            product = imageName
        }
        // Server products that are identified only by their edition ID.
        let editionProducts = ["ServerHomePremium": "Windows Home Server 2011", "ServerSBSStandard": "Windows Small Business Server 2011 Standard",
                               "ServerSolution": "Windows Small Business Server 2011 Essentials", "ServerWinFoundation": "Windows Server Foundation",
                               "ServerStorageStandard": "Windows Storage Server", "ServerHyper": "Hyper-V Server"]
        if build < 9200, let named = editionProducts[f["EDITIONID"] ?? ""] { product = named }
        let release = server ? nil : windowsRelease(build, servicing: servicing)
        res.title = product + (release.map { " \($0)" } ?? "")
        res.rows.add(L("製品", "Product"), product)
        res.rows.add(L("リリース", "Release"), release)
        res.rows.add(L("バージョン", "Version"), f["VERSION"], mono: true)
        res.rows.add(L("アーキテクチャ", "Architecture"), Array(Set(images.compactMap { arch($0["ARCH"]) })).sorted().joined(separator: ", "))
        res.rows.add(L("言語", "Languages"), Array(Set(images.flatMap { ($0["LANGUAGES"] ?? "").components(separatedBy: ", ") }.filter { !$0.isEmpty })).sorted().joined(separator: ", "))
        res.rows.add(L("エディション", "Editions"), "\(images.count)" + L(" 種類", ""))
        res.rows.add(L("イメージの作成日時", "Image created"), f["CREATED"])
        res.sections.append(ReportSection(id: "editions", title: L("エディション", "Editions"), symbol: "square.stack.3d.up",
            blocks: [.table(TableData(columns: ["#", L("名前", "Name"), L("エディション ID", "Edition ID"), L("アーキテクチャ", "Arch"), L("バージョン", "Version"), L("言語", "Languages"), L("展開後のサイズ", "Installed size")],
                rows: images.map { [$0["INDEX"] ?? "", $0["DISPLAYNAME"] ?? $0["NAME"] ?? "", $0["EDITIONID"] ?? "", arch($0["ARCH"]) ?? "", $0["VERSION"] ?? "", $0["LANGUAGES"] ?? "",
                                    Int($0["TOTALBYTES"] ?? "").map { byteSize($0) } ?? ""] }))], count: images.count))
    }
    }

    static func arch(_ code: String?) -> String? {
        ["0": "x86", "9": "x64", "5": "ARM32", "12": "ARM64", "6": "Itanium"][code ?? ""]
    }

    static func windowsName(_ build: Int, server: Bool) -> String? {
        if server {
            switch build {
            case 26100...: return "Windows Server 2025"
            case 20348...: return "Windows Server 2022"
            case 17763...: return "Windows Server 2019"
            case 14393...: return "Windows Server 2016"
            case 9600...: return "Windows Server 2012 R2"
            case 9200...: return "Windows Server 2012"
            case 7600...: return "Windows Server 2008 R2"
            case 6001...: return "Windows Server 2008"
            default: return nil
            }
        }
        switch build {
        case 21996...: return "Windows 11"
        case 10240...: return "Windows 10"
        case 9600...: return "Windows 8.1"
        case 9200...: return "Windows 8"
        case 7600...: return "Windows 7"
        case 6000...: return "Windows Vista"
        default: return nil
        }
    }

    /// Feature-update name. Several Windows 10 / 11 releases share one base build and differ only in the
    /// servicing number, so that number decides between them.
    static func windowsRelease(_ build: Int, servicing: Int) -> String? {
        if build == 19041 || (19042...19045).contains(build) {
            if build == 19045 || servicing >= 2006 { return "22H2" }
            if build == 19044 || servicing >= 1288 { return "21H2" }
            if build == 19043 || servicing >= 928 { return "21H1" }
            if build == 19042 || servicing >= 508 { return "20H2" }
            return "2004"
        }
        if build == 22621 || build == 22631 { return build == 22631 || servicing >= 2428 ? "23H2" : "22H2" }
        if build == 26100 || build == 26200 { return build == 26200 ? "25H2" : "24H2" }
        return [10240: "1507", 10586: "1511", 14393: "1607", 15063: "1703", 16299: "1709", 17134: "1803", 17763: "1809", 18362: "1903", 18363: "1909", 22000: "21H2"][build]
    }

    /// File version of a Windows program on the disc (read from its version resource).
    static func peVersion(_ fs: DiscFS, _ path: String) -> String? {
        guard let size = fs.size(path), size < 24 << 20, let d = fs.read(path, offset: 0, length: size), let pe = PEFile(d) else { return nil }
        let v = pe.versionInfo(pe.resources())
        return Dictionary(v.strings, uniquingKeysWith: { a, _ in a })["ProductVersion"] ?? v.file
    }

    static func detect(_ fs: DiscFS, volume: String) -> Result? {
        let root = fs.list()
        let names = Set(root.map { $0.name.lowercased() })
        func has(_ n: String) -> Bool { names.contains(n.lowercased()) }

        // ---- Windows (Vista and later): sources/install.wim | .esd | .swm
        if has("sources"), has("bootmgr") || has("setup.exe") {
            let install = ["sources/install.wim", "sources/install.esd", "sources/install.swm"].first { fs.exists($0) }
            var res = Result(kind: L("Windows のインストールディスク", "Windows installation disc"))
            res.badges.append(Badge(text: "Windows", tone: .info))
            var images = [[String: String]]()
            if let install, let w = wim(fs, install) {
                images = w.images
                res.rows.add(L("インストールイメージ", "Install image"), (install as NSString).lastPathComponent + "（" + byteSize(fs.size(install) ?? 0) + "、" + w.compression + "）", mono: true)
            } else if install == nil {
                res.rows.add(L("インストールイメージ", "Install image"), L("見つかりません（起動用メディアのみの可能性）", "Not found (may be boot media only)"), tone: .warn)
            }
            describe(images, into: &res)
            if let b = wim(fs, "sources/boot.wim"), let pe = b.images.first {
                res.rows.add(L("セットアップ環境 (Windows PE)", "Setup environment (Windows PE)"), [pe["VERSION"], arch(pe["ARCH"])].compactMap { $0 }.joined(separator: " · "), mono: true)
            }
            var efi = [String]()
            for (f, a) in [("efi/boot/bootx64.efi", "x64"), ("efi/boot/bootaa64.efi", "ARM64"), ("efi/boot/bootia32.efi", "x86"), ("efi/boot/bootarm.efi", "ARM32")] where fs.exists(f) { efi.append(a) }
            res.rows.add(L("UEFI 起動", "UEFI boot"), efi.isEmpty ? nil : efi.joined(separator: ", "))
            if fs.exists("autounattend.xml") { res.rows.add(L("無人インストール", "Unattended setup"), L("autounattend.xml あり", "autounattend.xml present"), tone: .warn) }
            if let cfg = fs.text("sources/ei.cfg") {
                res.rows.add(L("配布チャネル", "Channel"), firstMatch(cfg, #"\[Channel\]\s*([^\r\n\[]+)"#))
            }
            return res
        }

        // ---- Windows NT family before Vista: marker files in the root say which product this is.
        if has("i386") || has("amd64") || has("ia64") || has("alpha") {
            var product: String?
            var edition: String?
            if has("cdrom_nt.5") {
                product = "Windows 2000"
                edition = has("cdrom_ip.5") ? "Professional" : has("cdrom_is.5") ? "Server" : has("cdrom_ia.5") ? "Advanced Server" : has("cdrom_id.5") ? "Datacenter Server" : nil
            } else if let m = names.first(where: { $0.hasPrefix("cdrom_") && $0.hasSuffix(".40") }) {
                product = "Windows NT 4.0"
                edition = m.contains("_s.") ? "Server" : m.contains("_w.") ? "Workstation" : m.contains("_e.") ? "Enterprise Server" : m.contains("_t.") ? "Terminal Server" : nil
            } else if has("cdrom.w") || has("cdrom.s") {
                product = "Windows NT 3.x"
                edition = has("cdrom.s") ? "Server" : "Workstation"
            } else if names.contains(where: { $0.hasPrefix("win51") || $0.hasPrefix("win52") }) {
                let xp: [(String, String, String)] = [("win51ip", "Windows XP", "Professional"), ("win51ic", "Windows XP", "Home Edition"), ("win51ap", "Windows XP", "Professional x64 Edition"),
                    ("win51mp", "Windows XP", "Media Center Edition"), ("win51is", "Windows Server 2003", "Standard"), ("win51ia", "Windows Server 2003", "Enterprise"),
                    ("win51id", "Windows Server 2003", "Datacenter"), ("win51ib", "Windows Server 2003", "Web"), ("win52ia", "Windows Server 2003 R2", "Enterprise"), ("win52is", "Windows Server 2003 R2", "Standard")]
                if let hit = xp.first(where: { has($0.0) }) { product = hit.1; edition = hit.2 } else { product = "Windows XP / Server 2003" }
            }
            if let product {
                var res = Result(kind: L("Windows のインストールディスク（NT 系）", "Windows installation disc (NT family)"))
                res.badges.append(Badge(text: "Windows", tone: .info))
                res.title = product + (edition.map { " " + $0 } ?? "")
                res.rows.add(L("製品", "Product"), product)
                res.rows.add(L("エディション", "Edition"), edition)
                let sp = names.compactMap { n -> String? in
                    guard n.hasPrefix("win5"), let r = n.range(of: ".sp") else { return nil }
                    return "SP" + n[r.upperBound...]
                }.max()
                res.rows.add(L("サービスパック", "Service pack"), sp)
                let archs = [("i386", "x86"), ("amd64", "x64"), ("ia64", "Itanium"), ("alpha", "Alpha"), ("mips", "MIPS"), ("ppc", "PowerPC"), ("pc98", "PC-98"), ("nec98", "PC-98")].filter { has($0.0) }.map { $0.1 }
                res.rows.add(L("アーキテクチャ", "Architectures"), archs.joined(separator: ", "))
                for d in ["i386", "amd64"] where has(d) {
                    if let v = peVersion(fs, "\(d)/ntoskrnl.exe") ?? peVersion(fs, "\(d)/winnt32.exe") ?? peVersion(fs, "\(d)/winnt.exe") { res.rows.add(L("バージョン", "Version"), v, mono: true); break }
                }
                return res
            }
        }

        // ---- Windows 95 / 98 / Me
        for (dir, name) in [("win95", "Windows 95"), ("win98", "Windows 98"), ("win9x", "Windows Me")] where has(dir) {
            var res = Result(kind: L("Windows のインストールディスク（9x 世代）", "Windows installation disc (9x era)"))
            res.badges.append(Badge(text: "Windows", tone: .info))
            res.title = name
            res.rows.add(L("製品", "Product"), name)
            res.rows.add(L("セットアップのファイル", "Setup files"), "\(fs.list(dir).count)" + L(" 個", ""))
            return res
        }

        // ---- ReactOS
        if has("reactos"), has("freeldr.ini") || has("loader") {
            var res = Result(kind: L("ReactOS のインストール / ライブディスク", "ReactOS installation / live disc"))
            res.badges.append(Badge(text: "ReactOS", tone: .info))
            let v = peVersion(fs, "reactos/system32/ntoskrnl.exe") ?? peVersion(fs, "reactos/ntoskrnl.exe") ?? peVersion(fs, "reactos/reactos.exe") ?? peVersion(fs, "loader/setupldr.sys")
            res.title = "ReactOS"
            res.rows.add(L("製品", "Product"), "ReactOS")
            res.rows.add(L("互換とする Windows のバージョン", "Windows version it reports"), v, mono: true)
            return res
        }
        // ---- VMware ESXi: boot.cfg names the product and the build.
        if has("boot.cfg"), let cfg = fs.text("boot.cfg"), cfg.lowercased().contains("esx") || has("b.b00") {
            var res = Result(kind: L("VMware ESXi のインストールディスク", "VMware ESXi installation disc"))
            res.badges.append(Badge(text: "ESXi", tone: .info))
            let build = firstMatch(cfg, #"(?m)^build\s*=\s*(\S+)"#)
            res.title = "VMware ESXi" + (build.map { " " + $0 } ?? "")
            res.rows.add(L("製品", "Product"), "VMware ESXi")
            res.rows.add(L("ビルド", "Build"), build, mono: true)
            res.rows.add(L("起動時の表示", "Boot title"), firstMatch(cfg, #"(?m)^title\s*=\s*(.+)$"#))
            res.rows.add(L("モジュール数", "Modules"), "\(root.filter { $0.name.lowercased().hasSuffix(".v00") || $0.name.lowercased().hasSuffix(".b00") }.count)")
            return res
        }
        // ---- VirtIO drivers for Windows guests
        if has("netkvm"), has("viostor") || has("vioscsi") {
            var res = Result(kind: L("VirtIO ドライバーディスク（Windows 用）", "VirtIO driver disc (for Windows)"))
            res.title = volume.isEmpty ? "virtio-win" : volume
            res.rows.add(L("バージョン", "Version"), firstMatch(volume, #"(\d+\.\d+\.\d+)"#))
            res.rows.add(L("ドライバー", "Drivers"), root.filter { $0.isDir && !["amd64", "i386", "data", "guest-agent", "arm64"].contains($0.name.lowercased()) }.map { $0.name }.joined(separator: ", "))
            res.rows.add(L("対象の Windows", "Windows versions"), Array(Set(fs.list("NetKVM").map { $0.name })).sorted().joined(separator: ", "))
            return res
        }

        // ---- Linux and other Unix-like systems
        var res = Result(kind: L("Linux のインストール / ライブディスク", "Linux installation / live disc"))
        var found = false
        func efiArch() -> String? {
            var a = [String]()
            for (f, n) in [("efi/boot/bootx64.efi", "x86_64"), ("efi/boot/bootaa64.efi", "ARM64"), ("efi/boot/bootia32.efi", "x86"), ("efi/boot/bootriscv64.efi", "RISC-V 64")] where fs.exists(f) { a.append(n) }
            return a.isEmpty ? nil : a.joined(separator: ", ")
        }
        if let info = fs.text(".disk/info"), !info.isEmpty {   // Debian family: Ubuntu, Debian, Mint, Kali, Pop!_OS …
            found = true
            res.title = firstMatch(info, #"^(.*?)\s+-\s"#) ?? info
            res.rows.add(L("ディスクの説明", "Disc description"), info)
            res.rows.add(L("アーキテクチャ", "Architecture"), firstMatch(info, #"\b(amd64|arm64|i386|armhf|ppc64el|riscv64|s390x)\b"#))
            res.rows.add(L("ビルド日", "Build date"), firstMatch(info, #"\((\d{8}(?:\.\d+)?)\)"#))
            if fs.exists("casper") || fs.exists("live") { res.rows.add(L("形態", "Type"), L("ライブ起動できます", "Live system")); res.badges.append(Badge(text: "Live", tone: .info)) }
            res.badges.append(Badge(text: info.lowercased().contains("ubuntu") ? "Ubuntu" : info.lowercased().contains("debian") ? "Debian" : "Linux", tone: .info))
        } else if let t = fs.text(".treeinfo") {   // Red Hat family: Fedora, RHEL, CentOS, Alma, Rocky
            found = true
            let name = firstMatch(t, #"(?m)^name\s*=\s*(.+)$"#), ver = firstMatch(t, #"(?m)^version\s*=\s*(.+)$"#)
            res.title = name ?? [firstMatch(t, #"(?m)^family\s*=\s*(.+)$"#), ver].compactMap { $0 }.joined(separator: " ")
            res.rows.add(L("ディストリビューション", "Distribution"), res.title)
            res.rows.add(L("バージョン", "Version"), ver)
            res.rows.add(L("アーキテクチャ", "Architecture"), firstMatch(t, #"(?m)^arch\s*=\s*(.+)$"#))
            res.badges.append(Badge(text: "Linux", tone: .info))
        } else if let v = fs.text("arch/version") {
            found = true
            res.title = "Arch Linux " + v
            res.rows.add(L("ディストリビューション", "Distribution"), "Arch Linux")
            res.rows.add(L("バージョン", "Version"), v)
            res.badges.append(Badge(text: "Arch Linux", tone: .info))
        } else if let a = fs.text(".alpine-release") {
            found = true
            res.title = "Alpine Linux " + (firstMatch(a, #"-(\d+\.\d+(?:\.\d+)?)-"#) ?? "")
            res.rows.add(L("リリース", "Release"), a)
            res.badges.append(Badge(text: "Alpine", tone: .info))
        } else if has(".pve-cd-id.txt") || has("pve-installer.squashfs") || volume.uppercased() == "PVE" {
            found = true
            res.kind = L("Proxmox VE のインストールディスク", "Proxmox VE installation disc")
            res.title = "Proxmox VE"
            if let cd = fs.text(".cd-info") {
                res.rows.add(L("リリース", "Release"), firstMatch(cd, #"(?m)^RELEASE\s*=\s*'?([^'\r\n]+)"#))
                res.rows.add(L("ビルド", "Build"), firstMatch(cd, #"(?m)^ISORELEASE\s*=\s*'?([^'\r\n]+)"#))
                if let rel = firstMatch(cd, #"(?m)^RELEASE\s*=\s*'?([^'\r\n]+)"#) { res.title = "Proxmox VE " + rel }
            }
            res.badges.append(Badge(text: "Proxmox", tone: .info))
        } else if has("alteriso-info"), let info = fs.text("alteriso-info") {
            found = true
            res.title = "Alter Linux " + (firstMatch(info, #"(?mi)^(?:Version|Developer version|Os_Version)\s*[:=]\s*(.+)$"#) ?? volume)
            res.rows.add(L("ディストリビューション", "Distribution"), L("Alter Linux（Arch Linux 派生）", "Alter Linux (Arch-based)"))
            res.sections.append(ReportSection(id: "alter", title: "alteriso-info", symbol: "doc.text", blocks: [.text(info)]))
            res.badges.append(Badge(text: "Linux", tone: .info))
        } else if fs.exists("boot/corepure64.gz") || fs.exists("boot/core.gz") {
            found = true
            res.title = "Tiny Core Linux"
            res.rows.add(L("ディストリビューション", "Distribution"), fs.exists("boot/corepure64.gz") ? "Tiny Core Linux (CorePure64)" : "Tiny Core Linux")
            res.badges.append(Badge(text: "Linux", tone: .info))
        } else if let p = fs.text("media.1/products") {
            found = true
            res.title = firstMatch(p, #"^\S+\s+(.+)$"#) ?? "openSUSE / SUSE"
            res.rows.add(L("製品", "Product"), p)
            res.badges.append(Badge(text: "SUSE", tone: .info))
        } else if fs.exists("boot/kernel/kernel") || volume.uppercased().contains("FREEBSD") || volume.uppercased().contains("_RELEASE_") {
            found = true
            res.kind = L("FreeBSD のインストールディスク", "FreeBSD installation disc")
            res.title = "FreeBSD " + (firstMatch(volume, #"(\d+)_(\d+)_RELEASE"#) != nil ? volume.replacingOccurrences(of: "_", with: ".").replacingOccurrences(of: ".RELEASE", with: "-RELEASE") : "")
            res.badges.append(Badge(text: "FreeBSD", tone: .info))
        } else if has("images"), has("isolinux") || has("efi"), let m = firstMatch(volume, #"^((?:CentOS|Fedora|RHEL|Rocky|Alma|Red.?Hat|Oracle|Scientific)[A-Za-z]*[-_ ].*)$"#) {
            // Red Hat family boot / network-install media: no .treeinfo, the volume name is all there is.
            found = true
            // "CentOS-8-2-2004-x86_64-dvd" → "CentOS 8.2.2004 (x86_64)"
            let parts = m.components(separatedBy: CharacterSet(charactersIn: "- "))
            let nums = parts.dropFirst().prefix { Int($0) != nil }
            let archName = parts.first { ["x86_64", "aarch64", "i386", "ppc64le", "s390x"].contains($0) }
            res.title = (parts.first ?? m) + (nums.isEmpty ? "" : " " + nums.joined(separator: ".")) + (archName.map { " (\($0))" } ?? "")
            res.rows.add(L("ディストリビューション", "Distribution"), res.title)
            res.rows.add(L("形態", "Type"), L("ネットワークインストール用（パッケージは含みません）", "Network install (no packages on the disc)"))
            res.badges.append(Badge(text: "Linux", tone: .info))
        } else if has("isolinux") || has("syslinux") || fs.exists("boot/grub") || fs.exists("boot/isolinux") || has("casper") || has("live") || fs.exists("nix-store.squashfs") {
            found = true
            res.kind = L("起動可能な Linux 系ディスク", "Bootable Linux-style disc")
            if fs.exists("nix-store.squashfs") { res.title = "NixOS" }
            res.badges.append(Badge(text: "Linux", tone: .info))
        }
        guard found else { return nil }
        if fs.exists("system.sfs") || fs.exists("system.img") || fs.exists("system.efs") {
            res.kind = L("Android-x86 のインストール / ライブディスク", "Android-x86 installation / live disc")
            res.badges = [Badge(text: "Android", tone: .info)]
            for f in ["system.sfs", "system.img", "system.efs"] { if let sz = fs.size(f) { res.rows.add(L("システム本体", "System image"), f + "（" + byteSize(sz) + "）", mono: true); break } }
        }
        if !res.rows.contains(where: { $0.key == L("アーキテクチャ", "Architecture") }) { res.rows.add(L("UEFI 起動の対象", "UEFI boot targets"), efiArch()) }
        // The compressed root file system, when it is a single well-known file.
        for f in ["casper/filesystem.squashfs", "casper/minimal.squashfs", "live/filesystem.squashfs", "LiveOS/squashfs.img", "arch/x86_64/airootfs.sfs", "pve-base.squashfs", "images/install.img"] {
            if let s = fs.size(f) { res.rows.add(L("システム本体", "System image"), f + "（" + byteSize(s) + "）", mono: true); break }
        }
        return res
    }
}
