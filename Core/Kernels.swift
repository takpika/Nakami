import Foundation

/// The operating system kernels themselves: Linux boot images, the Windows NT kernel, and XNU.
enum Kernels {
    // MARK: Linux (x86 bzImage, with or without the EFI stub)

    static func isLinuxBoot(_ r: Reader) -> Bool { r.count > 0x270 && r.fixedStr(0x202, 4) == "HdrS" && r.le16(0x1fe) == 0xaa55 }

    static func linux(url: URL, data: Data) -> Report {
        let r = Reader(data, little: true)
        var rep = Report(kind: .elf, path: url.path, title: url.lastPathComponent)
        let proto = r.u16(0x206)
        // The version string sits in the setup code: "6.8.0-41-generic (buildd@host) #41-Ubuntu SMP … 2024"
        let verOff = Int(r.u16(0x20e)) + 0x200
        let full = r.cstr(verOff, max: 256)
        let version = full.split(separator: " ").first.map(String.init) ?? ""
        let setupSects = Int(r.u8(0x1f1)) == 0 ? 4 : Int(r.u8(0x1f1))
        let payload = (setupSects + 1) * 512 + Int(r.u32(0x248))
        let m = r.bytes(payload, 6)
        var compression = L("不明", "Unknown")
        if m.starts(with: [0x1f, 0x8b]) { compression = "gzip" }
        else if m.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a]) { compression = "xz" }
        else if m.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { compression = "zstd" }
        else if m.starts(with: [0x02, 0x21, 0x4c, 0x18]) { compression = "LZ4" }
        else if m.starts(with: [0x42, 0x5a, 0x68]) { compression = "bzip2" }
        else if m.starts(with: [0x5d, 0x00, 0x00]) { compression = "LZMA" }
        else if m.starts(with: [0x89, 0x4c, 0x5a, 0x4f]) { compression = "LZO" }
        let xload = r.u16(0x236)
        let efi = r.u16(0) == 0x5a4d
        rep.title = version.isEmpty ? url.lastPathComponent : "Linux " + version
        rep.subtitle = L("Linux カーネルの起動イメージ (bzImage)", "Linux kernel boot image (bzImage)") + " · " + (xload & 1 != 0 ? "x86-64" : "x86")
        rep.badges = [Badge(text: "Linux", tone: .info)]
        if efi { rep.badges.append(Badge(text: L("EFI から直接起動可", "EFI stub"), tone: .neutral)) }
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("Linux カーネルの起動イメージ", "Linux kernel boot image"))
        sum.add(L("カーネルのバージョン", "Kernel version"), version)
        sum.add(L("ビルドした環境", "Built by"), firstMatch(full, #"\(([^)]+)\)"#))
        sum.add(L("ビルド情報", "Build"), firstMatch(full, #"(#\d+.*)$"#))
        sum.add(L("アーキテクチャ", "Architecture"), xload & 1 != 0 ? "x86-64" : "x86")
        sum.add(L("カーネル本体の圧縮", "Kernel compression"), compression)
        sum.add(L("本体のサイズ（圧縮後）", "Payload size"), byteSize(Int(r.u32(0x24c))))
        sum.add(L("起動プロトコル", "Boot protocol"), "\(proto >> 8).\(String(format: "%02d", proto & 0xff))")
        sum.add(L("再配置", "Relocatable"), r.u8(0x234) != 0 ? L("可能", "Yes") : L("不可", "No"))
        sum.add(L("EFI スタブ", "EFI stub"), efi ? L("あり（UEFI から直接起動できます）", "Yes (bootable directly from UEFI)") : L("なし", "No"))
        if xload & 0x08 != 0 { sum.add(L("EFI ハンドオーバー (64 ビット)", "64-bit EFI handover"), L("対応", "Supported")) }
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        return rep
    }

    // MARK: Linux on other CPUs, compressed EFI kernels and unified kernel images

    /// "Linux version 6.8.0-41-generic (buildd@host) (gcc …) #41-Ubuntu SMP …", found by reading the (possibly compressed) kernel.
    static func banner(_ data: Data, at start: Int, length: Int, codec: Unpack.Codec, budget: TimeInterval) -> String? {
        let needle = Array("Linux version ".utf8)
        var carry = [UInt8]()
        var found: String?
        Unpack.stream(data, at: start, length: length, codec: codec, budget: budget) { chunk in
            var buf = carry
            buf.append(contentsOf: chunk)
            var i = 0
            let end = buf.count - needle.count
            while i <= end {
                if buf[i] == needle[0], buf[(i + 1)..<(i + needle.count)].elementsEqual(needle.dropFirst()) {
                    var e = i
                    while e < buf.count, e - i < 300, buf[e] != 0, buf[e] != 0x0a { e += 1 }
                    // Need the whole line; if it runs off the end of this piece, wait for the next one.
                    if e < buf.count || e - i >= 300 {
                        let s = String(decoding: buf[i..<e], as: UTF8.self)
                        if s.dropFirst(needle.count).first?.isNumber == true { found = s; return false }
                    } else { break }
                }
                i += 1
            }
            carry = Array(buf.suffix(400))
            return true
        }
        return found
    }

    struct LinuxInfo { var title: String?; var arch: String; var rows: [Row] }

    /// Any Linux kernel image: x86 bzImage, ARM64 / RISC-V `Image`, ARM zImage, or an EFI "zboot" wrapper around a compressed kernel.
    static func linuxInfo(_ data: Data, url: URL, budget: TimeInterval = 1.5) -> LinuxInfo? {
        let r = Reader(data, little: true)
        guard data.count > 0x40 else { return nil }
        if isLinuxBoot(r) {
            let rep = linux(url: url, data: data)
            return LinuxInfo(title: rep.title == url.lastPathComponent ? nil : rep.title, arch: rep.subtitle.components(separatedBy: " · ").last ?? "x86",
                             rows: rep.summary.filter { $0.key != L("種類", "Kind") && $0.key != L("サイズ", "Size") })
        }
        var arch = "", format = "", compression: String?, text: String?
        let pe = r.u16(0) == 0x5a4d ? Int(r.u32(0x3c)) : 0
        let machine = pe > 0 && r.fixedStr(pe, 2) == "PE" ? Int(r.u16(pe + 4)) : 0
        let machineName = [0xaa64: "ARM64", 0x5064: "RISC-V 64", 0x6264: "LoongArch 64", 0x8664: "x86-64", 0x1c2: "ARM", 0x14c: "x86"][machine]
        let magic38 = r.u32(0x38)
        if r.u16(0) == 0x5a4d, r.fixedStr(4, 4) == "zimg" {
            // EFI zboot: a small EFI program that unpacks the real kernel.
            let off = Int(r.u32(8)), size = Int(r.u32(12))
            let name = r.fixedStr(0x18, 32)
            arch = machineName ?? ""
            format = L("圧縮された EFI カーネル (zboot)", "Compressed EFI kernel (zboot)")
            compression = name.isEmpty ? nil : name
            let codec = Unpack.codec(r, off)
            if codec != .none, r.ok(off, size) { text = banner(data, at: off, length: size, codec: codec, budget: budget) }
        } else if magic38 == 0x644d_5241 {   // "ARM\x64"
            arch = "ARM64"
            format = "Image"
            text = banner(data, at: 0, length: data.count, codec: .none, budget: budget)
        } else if magic38 == 0x0543_5352 {   // "RSC\x05"
            arch = "RISC-V"
            format = "Image"
            text = banner(data, at: 0, length: data.count, codec: .none, budget: budget)
        } else if r.u32(0x24) == 0x016f_2818 {
            arch = L("ARM（32 ビット）", "ARM (32-bit)")
            format = "zImage"
            compression = L("あり（自己展開）", "Yes (self-extracting)")
        } else { return nil }
        let version = text.flatMap { firstMatch($0, #"Linux version (\S+)"#) }
        var rows = [Row]()
        rows.add(L("カーネルのバージョン", "Kernel version"), version)
        rows.add(L("ビルドした環境", "Built by"), text.flatMap { firstMatch($0, #"Linux version \S+ \(([^)]+)\)"#) })
        rows.add(L("コンパイラー", "Compiler"), text.flatMap { firstMatch($0, #"\) \((.+?)\) #"#) })
        rows.add(L("ビルド情報", "Build"), text.flatMap { firstMatch($0, #"(#\d+.*)$"#) })
        rows.add(L("アーキテクチャ", "Architecture"), arch)
        rows.add(L("イメージの形式", "Image format"), format)
        rows.add(L("カーネル本体の圧縮", "Kernel compression"), compression)
        if magic38 == 0x644d_5241 {
            let flags = r.u64(24)
            rows.add(L("ページサイズ", "Page size"), [1: "4 KB", 2: "16 KB", 3: "64 KB"][Int((flags >> 1) & 3)])
            rows.add(L("メモリー上のサイズ", "Size in memory"), byteSize(Int(clamping: r.u64(16))))
        }
        rows.add(L("EFI スタブ", "EFI stub"), r.u16(0) == 0x5a4d ? L("あり（UEFI から直接起動できます）", "Yes (bootable directly from UEFI)") : L("なし", "No"))
        return LinuxInfo(title: version.map { "Linux " + $0 }, arch: arch, rows: rows)
    }

    /// A kernel without the EFI stub is not a PE file at all: report it on its own.
    static func linuxPlain(url: URL, data: Data) -> Report? {
        guard Reader(data).le16(0) != 0x5a4d, let info = linuxInfo(data, url: url) else { return nil }
        var rep = Report(kind: .elf, path: url.path, title: info.title ?? url.lastPathComponent)
        rep.subtitle = L("Linux カーネルの起動イメージ", "Linux kernel boot image") + " · " + info.arch
        rep.badges = [Badge(text: "Linux", tone: .info)]
        rep.summary = [Row(L("種類", "Kind"), L("Linux カーネルの起動イメージ", "Linux kernel boot image"))] + info.rows + [Row(L("サイズ", "Size"), byteSizeExact(data.count))]
        return rep
    }

    /// EFI programs that are really Linux kernels: a kernel with the EFI stub, or a unified kernel image
    /// (kernel, initrd, command line and device trees packed into one signed EFI program).
    static func augmentEFI(_ rep: inout Report, data: Data, url: URL, sections: [PESection]) {
        func section(_ n: String) -> Data? {
            guard let s = sections.first(where: { $0.name == n }), s.raw > 0 else { return nil }
            let len = Swift.min(s.rawSize, s.vsize > 0 ? s.vsize : s.rawSize)
            guard len > 0, s.raw + len <= data.count else { return nil }
            return data.subdata(in: (data.startIndex + s.raw)..<(data.startIndex + s.raw + len))
        }
        func text(_ n: String) -> String? { section(n).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
        let inner = section(".linux")
        guard let info = linuxInfo(inner ?? data, url: url) else { return }
        let isUKI = inner != nil
        let kind = isUKI ? L("Linux の統合カーネルイメージ (UKI)", "Linux unified kernel image (UKI)") : L("Linux カーネルの起動イメージ（EFI スタブつき）", "Linux kernel boot image (with EFI stub)")
        var rows = [Row(L("種類", "Kind"), kind)]
        var title = info.title
        if isUKI {
            let pretty = text(".osrel").flatMap { firstMatch($0, #"PRETTY_NAME="?([^"\n]+)"#) }
            rows.add(L("中のシステム", "System"), pretty)
            if let u = text(".uname"), !u.isEmpty { rows.add(L("カーネルのバージョン", "Kernel version"), u); if title == nil { title = "Linux " + u } }
        }
        rows.append(contentsOf: info.rows.filter { r in !rows.contains { $0.key == r.key } })
        if isUKI {
            rows.add(L("起動オプション", "Kernel command line"), text(".cmdline"), mono: true)
            rows.add(L("初期 RAM ディスク", "Initial RAM disk"), sections.first { $0.name == ".initrd" }.map { byteSize($0.rawSize) + L(" を同梱", " included") })
            let dtbs = sections.filter { $0.name == ".dtb" || $0.name == ".dtbauto" }.count
            rows.add(L("デバイスツリー", "Device trees"), dtbs > 0 ? L("\(dtbs) 個を同梱（機種に合うものが起動時に選ばれます）", "\(dtbs) included (the matching one is picked at boot)", "內含 \(dtbs) 個（開機時會選用符合機型的項目）") : nil)
            rows.add(L("起動画面の画像", "Splash image"), sections.contains { $0.name == ".splash" } ? L("あり", "Yes") : nil)
            if let sb = text(".sbat") {
                let stub = sb.components(separatedBy: "\n").dropFirst().compactMap { $0.split(separator: ",").first.map(String.init) }.filter { $0 != "sbat" }
                rows.add(L("起動用の部品", "Boot stub"), stub.joined(separator: ", "))
            }
        }
        if let t = title { rep.title = t }
        rep.subtitle = kind + " · " + info.arch
        rep.badges.insert(Badge(text: "Linux", tone: .info), at: 0)
        if isUKI { rep.badges.insert(Badge(text: "UKI", tone: .neutral), at: 1) }
        let drop: Set<String> = [L("種類", "Kind"), L("アーキテクチャ", "Architecture"), L("必要な Windows", "Requires Windows")]
        rep.summary = rows + rep.summary.filter { !drop.contains($0.key) }
    }

    // MARK: Windows NT kernel and HAL

    /// Recognises ntoskrnl / ntkrnlmp / ntkrnlpa (and ReactOS's) by what they export.
    static func ntKernel(exports: [String], total: Int, strings: [String: String], imports: [String], isDLL: Bool) -> (kind: String, rows: [Row], section: ReportSection)? {
        let set = Set(exports)
        let original = (strings["OriginalFilename"] ?? strings["InternalName"] ?? "").lowercased()
        if !isDLL, set.contains("KeBugCheckEx"), set.contains("IoCreateDevice") || set.contains("ExAllocatePoolWithTag") {
            var rows = [Row]()
            let variant: String? = original.contains("ntkrpamp") ? L("マルチプロセッサー + PAE", "Multiprocessor + PAE") : original.contains("ntkrnlpa") ? L("PAE（36 ビットの物理アドレス）", "PAE")
                : original.contains("ntkrnlmp") ? L("マルチプロセッサー", "Multiprocessor") : original.contains("ntoskrnl") ? L("標準", "Standard") : nil
            let reactos = (strings["CompanyName"] ?? "").contains("ReactOS") || (strings["ProductName"] ?? "").contains("ReactOS")
            rows.add(L("カーネルの系統", "Kernel family"), reactos ? L("ReactOS（Windows NT 互換のカーネル）", "ReactOS (NT-compatible kernel)") : L("Windows NT カーネル", "Windows NT kernel"))
            rows.add(L("カーネルの種別", "Kernel variant"), variant)
            rows.add(L("NT のバージョン", "NT version"), strings["ProductVersion"] ?? strings["FileVersion"], mono: true)
            rows.add(L("ドライバー向けに公開している関数", "Functions exported to drivers"), "\(total)" + L(" 個", ""))
            // Rough breakdown by subsystem prefix: a quick picture of what the kernel offers.
            let prefixes: [(String, String)] = [("Zw", L("システムコール (Zw)", "System calls (Zw)")), ("Nt", L("システムコール (Nt)", "System calls (Nt)")), ("Io", L("I/O マネージャー", "I/O manager")),
                ("Ke", L("カーネルコア", "Kernel core")), ("Ex", L("エグゼクティブ", "Executive")), ("Mm", L("メモリーマネージャー", "Memory manager")), ("Ob", L("オブジェクトマネージャー", "Object manager")),
                ("Ps", L("プロセスとスレッド", "Processes and threads")), ("Se", L("セキュリティ", "Security")), ("Rtl", L("ランタイムライブラリ", "Runtime library")),
                ("FsRtl", L("ファイルシステム支援", "File system runtime")), ("Cc", L("キャッシュマネージャー", "Cache manager")), ("Po", L("電源管理", "Power manager")),
                ("Cm", L("レジストリ", "Registry")), ("Hal", "HAL"), ("Kd", L("カーネルデバッガー", "Kernel debugger")), ("Wmi", "WMI"), ("Etw", "ETW"), ("Lpc", "LPC"), ("Alpc", "ALPC"), ("Pcw", L("パフォーマンスカウンター", "Performance counters"))]
            var counts = [(String, Int)]()
            var used = Set<String>()
            for (p, name) in prefixes.sorted(by: { $0.0.count > $1.0.count }) {
                let n = exports.filter { !used.contains($0) && $0.hasPrefix(p) && ($0.dropFirst(p.count).first?.isUppercase ?? false) }
                n.forEach { used.insert($0) }
                if !n.isEmpty { counts.append((name, n.count)) }
            }
            let table = counts.sorted { $0.1 > $1.1 }.map { [$0.0, "\($0.1)"] }
            rows.add(L("依存する部品", "Depends on"), imports.joined(separator: ", "), mono: true)
            let partial = exports.count < total ? L("（先頭 \(exports.count) 個での集計）", " (from the first \(exports.count))", "（以前 \(exports.count) 個統計）") : ""
            return (reactos ? L("ReactOS のカーネル本体", "ReactOS kernel") : L("Windows のカーネル本体 (NT カーネル)", "Windows kernel (NT kernel)"), rows,
                    ReportSection(id: "kernel", title: L("カーネル", "Kernel"), symbol: "cpu", blocks: [.rows(rows), .heading(L("公開している関数の内訳", "Exported functions by area") + partial),
                                                                                                    .table(TableData(columns: [L("分野", "Area"), L("関数の数", "Functions")], rows: table))]))
        }
        if set.contains("HalInitSystem") || (set.contains("HalMakeBeep") && set.contains("KfRaiseIrql")) || original.hasPrefix("hal") && set.contains(where: { $0.hasPrefix("Hal") }) {
            var rows = [Row]()
            rows.add(L("役割", "Role"), L("ハードウェア抽象化レイヤー（カーネルと実機の間をつなぐ部品）", "Hardware Abstraction Layer (between the kernel and the machine)"))
            rows.add(L("バージョン", "Version"), strings["ProductVersion"] ?? strings["FileVersion"], mono: true)
            rows.add(L("公開している関数", "Exported functions"), "\(total)" + L(" 個", ""))
            rows.add(L("依存する部品", "Depends on"), imports.joined(separator: ", "), mono: true)
            return (L("Windows の HAL（ハードウェア抽象化レイヤー）", "Windows HAL (Hardware Abstraction Layer)"), rows,
                    ReportSection(id: "kernel", title: "HAL", symbol: "cpu", blocks: [.rows(rows)]))
        }
        return nil
    }

    // MARK: XNU

    /// "Darwin Kernel Version 24.1.0: … root:xnu-11215.41.3~2/RELEASE_ARM64_T6000"
    static func xnuVersion(_ data: Data, slice: MachOSlice) -> String? {
        guard slice.segments.contains(where: { ["__KLD", "__HIB", "__PRELINK_TEXT", "__KLDDATA", "__BOOTDATA"].contains($0.name) }) || slice.filetype == 12 else { return nil }
        let needle = Data("Darwin Kernel Version".utf8)
        let end = Swift.min(data.count, slice.offset + slice.size)
        guard slice.offset < end, let hit = data.range(of: needle, in: (data.startIndex + slice.offset)..<(data.startIndex + end)) else { return "" }
        return Reader(data).cstr(hit.lowerBound - data.startIndex, max: 300)
    }
}
