import Foundation

/// Stand-alone Windows imaging files, virtual machine disks and cabinet archives.
enum VirtualDisk {
    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        let r = Reader(data, little: true)
        let n = data.count
        guard n >= 512 else { return nil }
        if r.fixedStr(0, 5) == "MSWIM" { return wim(url, r) }
        if r.fixedStr(0, 4) == "MSCF" { return cab(url, r) }
        if r.be32(0) == 0x5146_49fb { return qcow2(url, r) }
        if r.fixedStr(0, 4) == "KDMV" { return vmdk(url, r) }
        if n < 1 << 20, r.fixedStr(0, 21) == "# Disk DescriptorFile" { return vmdkDescriptor(url, String(decoding: data.prefix(65536), as: UTF8.self), size: n) }
        if r.fixedStr(0, 8) == "vhdxfile" { return simple(url, L("Hyper-V の仮想ディスク (VHDX)", "Hyper-V virtual disk (VHDX)"), n, [Row(L("作成ソフト", "Creator"), r.utf16(8, units: 256).components(separatedBy: "\0").first ?? "")]) }
        if r.fixedStr(0, 39).hasPrefix("<<< Oracle VM VirtualBox Disk Image >>>") || r.u32(64) == 0xbeda_107f {
            return simple(url, L("VirtualBox の仮想ディスク (VDI)", "VirtualBox virtual disk (VDI)"), n,
                          [Row(L("種別", "Type"), r.u32(76) == 2 ? L("固定サイズ", "Fixed size") : L("可変サイズ", "Dynamically allocated")), Row(L("仮想ディスクの容量", "Virtual size"), byteSize(Int(clamping: r.u64(368))))])
        }
        if r.fixedStr(n - 512, 8) == "conectix" { return vhd(url, r, footer: n - 512, data: data, opts: opts) }
        if r.fixedStr(0, 8) == "conectix" { return vhd(url, r, footer: 0, data: data, opts: opts) }
        return nil
    }

    static func simple(_ url: URL, _ kind: String, _ size: Int, _ rows: [Row]) -> Report {
        var rep = Report(kind: .disk, path: url.path, title: url.lastPathComponent)
        rep.subtitle = kind
        var sum = [Row(L("種類", "Kind"), kind)]
        sum.append(contentsOf: rows.filter { !$0.value.isEmpty })
        sum.add(L("ファイルのサイズ", "File size"), byteSizeExact(size))
        rep.summary = sum
        return rep
    }

    // MARK: WIM / ESD

    static func wim(_ url: URL, _ r: Reader) -> Report {
        var res = OSInstaller.Result(kind: L("Windows のイメージファイル (WIM / ESD)", "Windows imaging file (WIM / ESD)"))
        let w = OSInstaller.wim { off, len in r.ok(off, len) ? r.bytes(off, len) : nil }
        if let w {
            res.rows.add(L("圧縮", "Compression"), w.compression)
            OSInstaller.describe(w.images.filter { !($0["NAME"] ?? "").isEmpty || $0["VERSION"] != nil }, into: &res)
            // ESD downloads also carry setup media and Windows PE images in front of the editions.
            let all = w.images
            if all.count > 0, res.sections.isEmpty || all.contains(where: { $0["VERSION"] == nil }) {
                res.sections.append(ReportSection(id: "images", title: L("含まれるイメージ", "Images"), symbol: "square.stack.3d.up",
                    blocks: [.table(TableData(columns: ["#", L("名前", "Name"), L("説明", "Description"), L("展開後のサイズ", "Installed size")],
                        rows: all.map { [$0["INDEX"] ?? "", $0["NAME"] ?? "", $0["DESCRIPTION"] ?? "", Int($0["TOTALBYTES"] ?? "").map { byteSize($0) } ?? ""] }))], count: all.count))
            }
        }
        // Component packages have no product of their own: keep the file name for those.
        let named = res.title.flatMap { $0 == "Windows" ? nil : $0 }
        var rep = Report(kind: .disk, path: url.path, title: named ?? url.lastPathComponent)
        rep.subtitle = res.kind
        rep.badges = [Badge(text: "Windows", tone: .info)]
        var sum = [Row(L("種類", "Kind"), res.kind)]
        sum.add(L("分割", "Part"), r.u16(42) > 1 ? "\(r.u16(40)) / \(r.u16(42))" : nil)
        sum.add(L("イメージ数", "Images"), "\(r.u32(44))")
        sum.append(contentsOf: res.rows)
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        rep.sections = res.sections
        return rep
    }

    // MARK: CAB / MSU

    static func cab(_ url: URL, _ r: Reader) -> Report {
        let filesOff = Int(r.u32(16)), nFolders = Int(r.u16(26)), nFiles = Int(r.u16(28)), flags = r.u16(30)
        var p = 36
        var folderReserve = 0
        if flags & 4 != 0 { folderReserve = Int(r.u8(p + 2)); p += 4 + Int(r.u16(p)) }
        if flags & 1 != 0 { p += r.cstr(p).utf8.count + 1; p += r.cstr(p).utf8.count + 1 }
        if flags & 2 != 0 { p += r.cstr(p).utf8.count + 1; p += r.cstr(p).utf8.count + 1 }
        var methods = Set<String>()
        for i in 0..<Swift.min(nFolders, 64) {
            let t = r.u16(p + i * (8 + folderReserve) + 6) & 0x0f
            methods.insert(["none", "MSZIP", "Quantum", "LZX"][Int(Swift.min(t, 3))])
        }
        var files = [[String]]()
        var total = 0
        var o = filesOff
        for _ in 0..<Swift.min(nFiles, 20_000) {
            guard r.ok(o, 17) else { break }
            let size = Int(r.u32(o))
            let name = r.cstr(o + 16, max: 512)
            total += size
            files.append([name, byteSize(size)])
            o += 16 + name.utf8.count + 1
        }
        let isUpdate = url.pathExtension.lowercased() == "msu" || files.contains { $0[0].lowercased().hasSuffix("-pkgproperties.txt") || $0[0].lowercased() == "wsusscan.cab" }
        let all = files.map { $0[0] }.joined(separator: " ") + " " + url.lastPathComponent
        let kb = firstMatch(all, #"(KB\d{5,8})"#)
        let kind = isUpdate ? L("Windows の更新プログラム (MSU)", "Windows update package (MSU)") : L("キャビネットファイル (CAB)", "Cabinet archive (CAB)")
        var rep = Report(kind: .disk, path: url.path, title: isUpdate ? (kb.map { L("Windows 更新プログラム ", "Windows Update ") + $0 } ?? url.lastPathComponent) : url.lastPathComponent)
        rep.subtitle = kind
        if isUpdate { rep.badges.append(Badge(text: "Windows", tone: .info)) }
        var sum = [Row(L("種類", "Kind"), kind)]
        sum.add(L("更新プログラムの番号", "Update number"), isUpdate ? kb : nil, mono: true)
        sum.add(L("対象", "Target"), isUpdate ? firstMatch(all, #"(Windows\d+\.\d+)"#).map { $0.replacingOccurrences(of: "Windows", with: "Windows NT ") } : nil)
        sum.add(L("アーキテクチャ", "Architecture"), isUpdate ? firstMatch(all.lowercased(), #"[-_](x64|x86|arm64|ia64)\b"#) : nil)
        sum.add(L("ファイル数", "Files"), "\(nFiles)" + L(" 個、展開後 ", " files, ") + byteSize(total))
        sum.add(L("圧縮", "Compression"), methods.sorted().joined(separator: ", "))
        if flags & 3 != 0 { sum.add(L("分割", "Spanned"), L("複数の CAB に分かれています", "Part of a multi-cabinet set")) }
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        rep.sections = [ReportSection(id: "files", title: L("ファイル", "Files"), symbol: "doc.on.doc",
                                      blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: Array(files.prefix(5000)), total: nFiles))], count: nFiles)]
        return rep
    }

    // MARK: Virtual machine disks

    static func qcow2(_ url: URL, _ r: Reader) -> Report {
        let backingOff = Int(clamping: r.be64(8)), backingLen = Int(r.be32(16))
        var rows = [Row]()
        rows.add(L("形式のバージョン", "Format version"), "\(r.be32(4))")
        rows.add(L("仮想ディスクの容量", "Virtual size"), byteSize(Int(clamping: r.be64(24))))
        rows.add(L("クラスターサイズ", "Cluster size"), byteSize(1 << Int(Swift.min(r.be32(20), 30))))
        rows.add(L("暗号化", "Encryption"), [0: "", 1: "AES", 2: "LUKS"][r.be32(32)] ?? "?")
        rows.add(L("元になるイメージ", "Backing file"), backingLen > 0 && backingLen < 1024 ? r.fixedStr(backingOff, backingLen) : "", mono: true)
        return simple(url, L("QEMU の仮想ディスク (qcow2)", "QEMU virtual disk (qcow2)"), r.count, rows)
    }

    static func vmdkRows(_ text: String) -> [Row] {
        var rows = [Row]()
        rows.add(L("作成方式", "Create type"), firstMatch(text, #"createType\s*=\s*"([^"]+)""#), mono: true)
        rows.add(L("仮想ハードウェア", "Virtual hardware"), firstMatch(text, #"ddb\.virtualHWVersion\s*=\s*"([^"]+)""#))
        rows.add(L("アダプター", "Adapter"), firstMatch(text, #"ddb\.adapterType\s*=\s*"([^"]+)""#))
        rows.add(L("元になるディスク", "Parent disk"), firstMatch(text, #"parentFileNameHint\s*=\s*"([^"]+)""#), mono: true)
        let extents = text.components(separatedBy: "\n").filter { $0.hasPrefix("RW ") || $0.hasPrefix("RDONLY ") || $0.hasPrefix("NOACCESS ") }
        if !extents.isEmpty {
            let sectors = extents.compactMap { Int($0.split(separator: " ").dropFirst().first ?? "") }.reduce(0, +)
            rows.add(L("仮想ディスクの容量", "Virtual size"), byteSize(sectors * 512))
            rows.add(L("構成ファイル数", "Extents"), "\(extents.count)")
        }
        return rows
    }

    static func vmdk(_ url: URL, _ r: Reader) -> Report {
        var rows = [Row(L("仮想ディスクの容量", "Virtual size"), byteSize(Int(clamping: r.u64(12)) * 512))]
        let dOff = Int(clamping: r.u64(28)) * 512, dLen = Swift.min(Int(clamping: r.u64(36)) * 512, 1 << 20)
        if dOff > 0, r.ok(dOff, dLen) { rows.append(contentsOf: vmdkRows(r.fixedStr(dOff, dLen)).filter { $0.key != L("仮想ディスクの容量", "Virtual size") }) }
        return simple(url, L("VMware の仮想ディスク (VMDK)", "VMware virtual disk (VMDK)"), r.count, rows)
    }

    static func vmdkDescriptor(_ url: URL, _ text: String, size: Int) -> Report {
        simple(url, L("VMware の仮想ディスク定義 (VMDK)", "VMware virtual disk descriptor (VMDK)"), size, vmdkRows(text))
    }

    static func vhd(_ url: URL, _ r: Reader, footer f: Int, data: Data, opts: AnalyzeOptions) -> Report {
        let type = r.be32(f + 60)
        var rows = [Row]()
        rows.add(L("種別", "Type"), [2: L("固定サイズ", "Fixed size"), 3: L("可変サイズ", "Dynamically expanding"), 4: L("差分", "Differencing")][type] ?? "\(type)")
        rows.add(L("仮想ディスクの容量", "Virtual size"), byteSize(Int(clamping: r.be64(f + 48))))
        rows.add(L("作成ソフト", "Creator"), r.fixedStr(f + 28, 4).trimmingCharacters(in: .whitespaces) + " \(r.be16(f + 32)).\(r.be16(f + 34))")
        rows.add(L("作成した OS", "Creator OS"), ["Wi2k": "Windows", "Mac ": "Mac"][r.fixedStr(f + 36, 4)] ?? r.fixedStr(f + 36, 4))
        rows.add(L("作成日時", "Created"), dateString(Date(timeIntervalSince1970: 946_684_800 + Double(r.be32(f + 24)))))
        var rep = simple(url, L("仮想ディスク (VHD)", "Virtual hard disk (VHD)"), r.count, rows)
        // A fixed-size VHD is the raw disk followed by the footer: its partitions can be read directly.
        if type == 2, f > 0 {
            let dev = SubDevice(parent: DataDevice(data), base: 0, size: f)
            let vols = DiskImage.volumes(dev)
            if PartitionMap.detect(dev) != nil || vols.contains(where: { !$0.fsName.isEmpty }) {
                rep.sections.append(ReportSection(id: "partitions", title: L("パーティション", "Partitions"), symbol: "square.split.2x1",
                    blocks: [.table(TableData(columns: [L("名前", "Name"), L("種類", "Type"), L("ファイルシステム", "File system"), L("ボリューム名", "Label"), L("サイズ", "Size")],
                                              rows: vols.map { [$0.part.name, $0.part.type, $0.fsName, $0.label ?? "", byteSize($0.part.size)] }))], count: vols.count))
            }
        }
        return rep
    }
}
