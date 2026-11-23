import Foundation

enum ELF {
    static func isELF(_ r: Reader) -> Bool { r.be32(0) == 0x7f45_4c46 }

    static let machines: [UInt16: String] = [
        2: "SPARC", 3: "x86", 4: "m68k", 8: "MIPS", 15: "PA-RISC", 18: "SPARC32+", 20: "PowerPC", 21: "PowerPC64",
        22: "s390", 40: "ARM", 42: "SuperH", 43: "SPARC V9", 50: "IA-64", 62: "x86-64", 83: "AVR", 88: "M32R",
        92: "OpenRISC", 93: "ARC", 94: "Xtensa", 105: "MSP430", 106: "Blackfin", 113: "Nios II", 164: "Hexagon",
        183: "AArch64", 189: "MicroBlaze", 195: "ARC v2", 224: "WebAssembly", 243: "RISC-V", 247: "eBPF", 252: "C-SKY", 258: "LoongArch",
    ]
    static let osabis: [UInt8: String] = [0: "System V", 1: "HP-UX", 2: "NetBSD", 3: "Linux (GNU)", 6: "Solaris", 7: "AIX", 8: "IRIX",
                                           9: "FreeBSD", 10: "Tru64", 12: "OpenBSD", 13: "OpenVMS", 97: "ARM", 255: "Standalone"]
    static let ptypes: [UInt32: String] = [0: "NULL", 1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 5: "SHLIB", 6: "PHDR", 7: "TLS",
                                           0x6474_e550: "GNU_EH_FRAME", 0x6474_e551: "GNU_STACK", 0x6474_e552: "GNU_RELRO",
                                           0x6474_e553: "GNU_PROPERTY", 0x7000_0001: "ARM_EXIDX / PROC"]
    static let stypes: [UInt32: String] = [0: "NULL", 1: "PROGBITS", 2: "SYMTAB", 3: "STRTAB", 4: "RELA", 5: "HASH", 6: "DYNAMIC", 7: "NOTE",
                                           8: "NOBITS", 9: "REL", 11: "DYNSYM", 14: "INIT_ARRAY", 15: "FINI_ARRAY", 16: "PREINIT_ARRAY",
                                           17: "GROUP", 18: "SYMTAB_SHNDX", 19: "RELR", 0x6fff_fff6: "GNU_HASH", 0x6fff_fffd: "GNU_verdef",
                                           0x6fff_fffe: "GNU_verneed", 0x6fff_ffff: "GNU_versym", 0x7000_0001: "ARM_EXIDX", 0x7000_0003: "ARM_ATTRIBUTES"]

    struct PH { var type: UInt32; var flags: UInt32; var off: Int; var vaddr: UInt64; var filesz: Int; var memsz: UInt64 }
    struct SH { var name: String; var type: UInt32; var flags: UInt64; var addr: UInt64; var off: Int; var size: Int; var link: Int; var entsize: Int }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .elf, path: url.path, title: url.lastPathComponent)
        var r = Reader(data, little: true)
        let is64 = r.u8(4) == 2
        r.little = r.u8(5) != 2
        let osabi = r.u8(7)
        let type = r.u16(16)
        let machine = r.u16(18)
        let entry = is64 ? r.u64(24) : UInt64(r.u32(24))
        let phoff = is64 ? Int(clamping: r.u64(32)) : Int(r.u32(28))
        let shoff = is64 ? Int(clamping: r.u64(40)) : Int(r.u32(32))
        let eflags = r.u32(is64 ? 48 : 36)
        let phentsize = Int(r.u16(is64 ? 54 : 42)), phnum = Int(r.u16(is64 ? 56 : 44))
        let shentsize = Int(r.u16(is64 ? 58 : 46))
        var shnum = Int(r.u16(is64 ? 60 : 48))
        var shstrndx = Int(r.u16(is64 ? 62 : 50))

        func word(_ o: Int) -> UInt64 { is64 ? r.u64(o) : UInt64(r.u32(o)) }

        // Program headers
        var phs = [PH]()
        for i in 0..<Swift.min(phnum, 512) where phentsize >= (is64 ? 56 : 32) {
            let o = phoff + i * phentsize
            guard r.ok(o, phentsize) else { break }
            if is64 {
                phs.append(PH(type: r.u32(o), flags: r.u32(o + 4), off: Int(clamping: r.u64(o + 8)), vaddr: r.u64(o + 16),
                              filesz: Int(clamping: r.u64(o + 32)), memsz: r.u64(o + 40)))
            } else {
                phs.append(PH(type: r.u32(o), flags: r.u32(o + 24), off: Int(r.u32(o + 4)), vaddr: UInt64(r.u32(o + 8)),
                              filesz: Int(r.u32(o + 16)), memsz: UInt64(r.u32(o + 20))))
            }
        }
        func fileOff(_ va: UInt64) -> Int? {
            for p in phs where p.type == 1 && va >= p.vaddr && va < p.vaddr + UInt64(p.filesz) {
                return p.off + Int(va - p.vaddr)
            }
            return nil
        }

        // Section headers
        var shs = [SH]()
        if shoff > 0, shentsize >= (is64 ? 64 : 40), r.ok(shoff, shentsize) {
            if shnum == 0 { shnum = Int(clamping: word(shoff + (is64 ? 32 : 20))) }
            if shstrndx == 0xffff { shstrndx = Int(r.u32(shoff + (is64 ? 40 : 24))) }
            var raw = [(Int, SH)]()
            for i in 0..<Swift.min(shnum, 8192) {
                let o = shoff + i * shentsize
                guard r.ok(o, shentsize) else { break }
                let sh = is64
                    ? SH(name: "", type: r.u32(o + 4), flags: r.u64(o + 8), addr: r.u64(o + 16), off: Int(clamping: r.u64(o + 24)),
                         size: Int(clamping: r.u64(o + 32)), link: Int(r.u32(o + 40)), entsize: Int(clamping: r.u64(o + 56)))
                    : SH(name: "", type: r.u32(o + 4), flags: UInt64(r.u32(o + 8)), addr: UInt64(r.u32(o + 12)), off: Int(r.u32(o + 16)),
                         size: Int(r.u32(o + 20)), link: Int(r.u32(o + 24)), entsize: Int(r.u32(o + 36)))
                raw.append((Int(r.u32(o)), sh))
            }
            let strtab = shstrndx < raw.count ? raw[shstrndx].1 : nil
            shs = raw.map { n, sh in
                var s = sh
                if let st = strtab, n < st.size { s.name = r.cstr(st.off + n, max: 256) }
                return s
            }
        }
        func section(_ name: String) -> SH? { shs.first { $0.name == name } }

        // Dynamic section
        var needed = [String](), soname: String?, rpath: String?, runpath: String?
        var bindNow = false, pieFlag = false, hasDynamic = false
        if let dyn = phs.first(where: { $0.type == 2 }) {
            hasDynamic = true
            let w = is64 ? 16 : 8
            var entries = [(UInt64, UInt64)]()
            var o = dyn.off
            while r.ok(o, w), entries.count < 4096 {
                let tag = word(o), val = word(o + w / 2)
                if tag == 0 { break }
                entries.append((tag, val))
                o += w
            }
            let strOff = entries.first { $0.0 == 5 }.flatMap { fileOff($0.1) }
            func s(_ v: UInt64) -> String { strOff.map { r.cstr($0 + Int(clamping: v), max: 1024) } ?? "" }
            for (tag, val) in entries {
                switch tag {
                case 1: needed.append(s(val))
                case 14: soname = s(val)
                case 15: rpath = s(val)
                case 29: runpath = s(val)
                case 24: bindNow = true
                case 30: if val & 0x8 != 0 { bindNow = true }
                case 0x6fff_fffb:
                    if val & 0x1 != 0 { bindNow = true }
                    if val & 0x0800_0000 != 0 { pieFlag = true }
                default: break
                }
            }
        }

        let interp = phs.first { $0.type == 3 }.map { r.cstr($0.off, max: Swift.min($0.filesz, 512)) }

        // Notes
        var buildID: String?, abiTag: String?, androidAPI: String?, goBuildID: String?, noteOS: String?
        func parseNotes(_ off: Int, _ size: Int) {
            var o = off
            let end = off + size
            var n = 0
            while o + 12 <= end, r.ok(o, 12), n < 64 {
                let namesz = Int(r.u32(o)), descsz = Int(r.u32(o + 4)), ntype = r.u32(o + 8)
                let name = r.fixedStr(o + 12, Swift.min(namesz, 32))
                let d = o + 12 + ((namesz + 3) & ~3)
                guard r.ok(d, descsz) else { break }
                switch (name, ntype) {
                case ("GNU", 3): buildID = hexString(r.bytes(d, Swift.min(descsz, 64)))
                case ("GNU", 1) where descsz >= 16:
                    let os = ["Linux", "GNU Hurd", "Solaris", "FreeBSD"]
                    let k = Int(r.u32(d))
                    abiTag = (k < os.count ? os[k] : "OS \(k)") + " \(r.u32(d + 4)).\(r.u32(d + 8)).\(r.u32(d + 12))"
                case ("Android", 1) where descsz >= 4:
                    androidAPI = "API \(r.u32(d))"
                    if descsz >= 68 {
                        let ndk = r.fixedStr(d + 4, 64)
                        if !ndk.isEmpty { androidAPI! += " (NDK \(ndk))" }
                    }
                case ("Go", 4): goBuildID = r.fixedStr(d, Swift.min(descsz, 128))
                case ("FreeBSD", 1) where descsz >= 4: noteOS = "FreeBSD \(r.u32(d) / 100_000).\(r.u32(d) / 1000 % 100)"
                case ("NetBSD", 1) where descsz >= 4: noteOS = "NetBSD \(r.u32(d) / 100_000_000).\(r.u32(d) / 1_000_000 % 100)"
                case ("OpenBSD", 1): noteOS = "OpenBSD"
                default: break
                }
                o = d + ((descsz + 3) & ~3)
                n += 1
            }
        }
        for p in phs where p.type == 4 { parseNotes(p.off, p.filesz) }
        if buildID == nil { for s in shs where s.type == 7 { parseNotes(s.off, s.size) } }

        // Symbols
        let cap = opts.deep ? 20000 : 1500
        var imports = [String](), exports = [String]()
        var importTotal = 0, exportTotal = 0
        var canary = false, fortify = false
        func readSyms(_ tab: SH, collect: Bool) -> Int {
            let ent = is64 ? 24 : 16
            guard tab.link < shs.count else { return 0 }
            let str = shs[tab.link]
            let n = tab.size / ent
            guard collect else { return n }
            for i in 1..<Swift.max(1, Swift.min(n, 400_000)) {
                let o = tab.off + i * ent
                guard r.ok(o, ent) else { break }
                let nameIdx = Int(r.u32(o))
                let info = r.u8(o + (is64 ? 4 : 12)), shndx = r.u16(o + (is64 ? 6 : 14))
                let bind = info >> 4, stype = info & 0xf
                guard nameIdx != 0, nameIdx < str.size, stype != 3, stype != 4 else { continue }
                if shndx == 0 {
                    importTotal += 1
                    if imports.count < cap || !canary || !fortify {
                        let nm = r.cstr(str.off + nameIdx, max: 512)
                        if nm == "__stack_chk_fail" || nm == "__stack_chk_guard" { canary = true }
                        if nm.hasSuffix("_chk") && nm.hasPrefix("__") && nm != "__stack_chk_fail" { fortify = true }
                        if imports.count < cap { imports.append(nm) }
                    }
                } else if bind == 1 || bind == 2 {
                    exportTotal += 1
                    if exports.count < cap { exports.append(r.cstr(str.off + nameIdx, max: 512)) }
                }
            }
            return n
        }
        var dynsymCount = 0, symtabCount = 0
        if let ds = shs.first(where: { $0.type == 11 }) { dynsymCount = readSyms(ds, collect: true) }
        if let st = shs.first(where: { $0.type == 2 }) { symtabCount = readSyms(st, collect: type == 1 && dynsymCount == 0) }

        // Derived facts
        let stripped = symtabCount == 0
        let hasDebug = shs.contains { $0.name == ".debug_info" || $0.name == ".zdebug_info" }
        let gnuStack = phs.first { $0.type == 0x6474_e551 }
        let relro = phs.contains { $0.type == 0x6474_e552 }
        let modinfo = section(".modinfo")
        let isKernelModule = type == 1 && modinfo != nil
        let isPIE = type == 3 && (pieFlag || (interp != nil && soname == nil))

        var comments = [String]()
        if let c = section(".comment"), c.size < 1 << 16 {
            for part in r.bytes(c.off, c.size).split(separator: 0) {
                let s = Reader.decode(Data(part))
                if !s.isEmpty, !comments.contains(s) { comments.append(s) }
            }
        }
        var langs = [String]()
        if section(".go.buildinfo") != nil || section(".gopclntab") != nil || goBuildID != nil { langs.append("Go") }
        if section(".rustc") != nil || comments.contains(where: { $0.contains("rustc") }) { langs.append("Rust") }
        if needed.contains(where: { $0.hasPrefix("libstdc++") || $0.hasPrefix("libc++") }) { langs.append("C++") }

        var os: String?
        if let i = interp {
            if i.contains("/system/bin/linker") { os = "Android" }
            else if i.contains("ld-musl") { os = "Linux (musl)" }
            else if i.contains("ld-linux") || i.contains("ld.so") || i.contains("ld64.so") { os = "Linux (glibc)" }
            else if i.contains("ld-elf.so") { os = "FreeBSD" }
            else if i.contains("ld-uClibc") { os = "Linux (uClibc)" }
        }
        if os == nil, androidAPI != nil { os = "Android" }
        if os == nil, isKernelModule { os = "Linux" }
        if os == nil { os = noteOS }
        if os == nil, let a = abiTag { os = a.components(separatedBy: " ").first }
        if os == nil, osabi != 0 { os = osabis[osabi] }
        if os == nil, needed.contains(where: { $0.hasPrefix("libc.so.6") || $0.hasPrefix("ld-linux") }) { os = "Linux (glibc)" }
        if os == nil, needed.contains(where: { $0.hasPrefix("libc.musl") }) { os = "Linux (musl)" }

        var kind: String
        switch type {
        case 1: kind = isKernelModule ? L("カーネルモジュール", "Kernel module") : L("オブジェクトファイル", "Object file")
        case 2: kind = L("実行ファイル", "Executable")
        case 3: kind = isPIE ? L("実行ファイル (PIE)", "Executable (PIE)") : L("共有ライブラリ", "Shared library")
        case 4: kind = L("コアダンプ", "Core dump")
        default: kind = "ELF type \(type)"
        }
        var mach = machines[machine] ?? "machine \(machine)"
        var abiNotes = [String]()
        if machine == 40 {
            let eabi = eflags >> 24
            if eabi != 0 { abiNotes.append("EABI\(eabi)") }
            if eflags & 0x400 != 0 { abiNotes.append(L("ハードフロート", "hard-float")) }
            if eflags & 0x200 != 0 { abiNotes.append(L("ソフトフロート", "soft-float")) }
            if entry & 1 != 0 { abiNotes.append("Thumb") }
        } else if machine == 243 {
            mach = is64 ? "RISC-V 64" : "RISC-V 32"
            abiNotes.append(["soft-float", "single-float (F)", "double-float (D)", "quad-float (Q)"][Int((eflags >> 1) & 3)])
            if eflags & 1 != 0 { abiNotes.append("RVC") }
        } else if machine == 8 {
            mach = is64 ? "MIPS64" : "MIPS"
        }
        let linkage = hasDynamic ? L("動的リンク", "Dynamically linked") : (type == 2 || type == 3 ? L("静的リンク", "Statically linked") : nil)

        rep.subtitle = [(os.map { "\($0) " } ?? "ELF ") + kind, mach, (is64 ? "64" : "32") + L(" ビット ", "-bit ") + (r.little ? "LE" : "BE")].joined(separator: " · ")
        if stripped { rep.badges.append(Badge(text: L("シンボル削除済み", "Stripped"))) }
        if hasDebug { rep.badges.append(Badge(text: L("デバッグ情報あり", "Debug info"), tone: .info)) }
        if !hasDynamic, type == 2 || type == 3 { rep.badges.append(Badge(text: L("静的リンク", "Static"), tone: .info)) }
        for l in langs { rep.badges.append(Badge(text: l, tone: .info)) }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), kind)
        sum.add(L("アーキテクチャ", "Architecture"), mach + (abiNotes.isEmpty ? "" : " (" + abiNotes.joined(separator: ", ") + ")"))
        sum.add(L("形式", "Format"), "ELF" + (is64 ? "64" : "32") + (r.little ? L("、リトルエンディアン", ", little-endian") : L("、ビッグエンディアン", ", big-endian")))
        sum.add(L("対象 OS", "Target OS"), os)
        sum.add(L("最低カーネル", "Minimum kernel"), abiTag)
        sum.add("Android", androidAPI)
        sum.add(L("リンク", "Linkage"), linkage)
        sum.add(L("インタープリター", "Interpreter"), interp, mono: true)
        sum.add("SONAME", soname, mono: true)
        sum.add(L("ライブラリ", "Libraries"), needed.isEmpty ? nil : needed.joined(separator: ", "))
        sum.add("Build ID", buildID, mono: true)
        sum.add(L("コンパイラー", "Compiler"), comments.joined(separator: "\n"))
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum

        // Header
        var hdr = [Row]()
        hdr.add(L("種別", "Type"), ["NONE", "REL", "EXEC", "DYN", "CORE"][safe: Int(type)] ?? "\(type)", mono: true)
        hdr.add(L("マシン", "Machine"), "\(mach) (\(machine))")
        hdr.add("OS ABI", (osabis[osabi] ?? "\(osabi)") + " v\(r.u8(8))")
        hdr.add(L("エントリーポイント", "Entry point"), hex(entry), mono: true)
        hdr.add(L("フラグ", "Flags"), hex(eflags, pad: 8) + (abiNotes.isEmpty ? "" : " (" + abiNotes.joined(separator: ", ") + ")"), mono: true)
        hdr.add(L("プログラムヘッダー", "Program headers"), "\(phnum)")
        hdr.add(L("セクションヘッダー", "Section headers"), "\(shnum)")
        hdr.add("RPATH", rpath, mono: true)
        hdr.add("RUNPATH", runpath, mono: true)
        hdr.add("Go Build ID", goBuildID, mono: true)
        if let dl = section(".gnu_debuglink") { hdr.add(L("分離デバッグ情報", "Separate debug file"), r.cstr(dl.off, max: 256), mono: true) }
        var hblocks: [Block] = [.rows(hdr)]

        if type == 2 || type == 3 {
            var sec = [Row]()
            if type == 2 { sec.add("PIE", L("無効（固定アドレス）", "Disabled (fixed address)"), tone: .warn) }
            else if isPIE { sec.add("PIE", L("有効", "Enabled"), tone: .good) }
            if let gs = gnuStack {
                sec.add(L("スタック実行防止 (NX)", "Non-executable stack (NX)"), gs.flags & 1 == 0 ? L("有効", "Enabled") : L("無効（スタックが実行可能）", "Disabled (executable stack)"), tone: gs.flags & 1 == 0 ? .good : .bad)
            } else {
                sec.add(L("スタック実行防止 (NX)", "Non-executable stack (NX)"), L("指定なし", "Not specified"), tone: .warn)
            }
            if hasDynamic {
                sec.add("RELRO", relro ? (bindNow ? L("完全 (Full)", "Full") : L("部分的 (Partial)", "Partial")) : L("なし", "None"), tone: relro ? (bindNow ? .good : .neutral) : .warn)
                if dynsymCount > 0 {
                    sec.add(L("スタック保護 (canary)", "Stack canary"), canary ? L("あり", "Present") : L("見つかりません", "Not found"), tone: canary ? .good : .neutral)
                    sec.add("FORTIFY_SOURCE", fortify ? L("あり", "Present") : L("見つかりません", "Not found"), tone: fortify ? .good : .neutral)
                }
            }
            if rpath != nil || runpath != nil, (rpath ?? runpath)!.split(separator: ":").contains(where: { !$0.hasPrefix("/") && !$0.hasPrefix("$ORIGIN") }) {
                sec.add("RPATH", L("相対パスを含みます", "Contains a relative path"), tone: .warn)
            }
            hblocks.append(.heading(L("保護機能", "Mitigations")))
            hblocks.append(.rows(sec))
        }
        rep.sections.append(ReportSection(id: "header", title: L("ヘッダー", "Header"), symbol: "doc.badge.gearshape", blocks: hblocks))

        if isKernelModule, let m = modinfo, m.size < 4 << 20 {
            var pairs = [(String, String)]()
            for part in r.bytes(m.off, m.size).split(separator: 0) {
                let str = Reader.decode(Data(part))
                if let eq = str.firstIndex(of: "=") { pairs.append((String(str[..<eq]), String(str[str.index(after: eq)...]))) }
            }
            let mod = Drivers.linuxModule(modinfo: pairs, undefined: Set(imports), signature: Drivers.moduleSignature(Reader(data)))
            // Put the module's own facts right after the kind line.
            rep.summary.insert(contentsOf: mod.summary, at: Swift.min(1, rep.summary.count))
            rep.badges.insert(contentsOf: mod.badges, at: 0)
            rep.sections.append(contentsOf: mod.sections)
            if let d = pairs.first(where: { $0.0 == "description" })?.1, !d.isEmpty { rep.title = d }
        }

        if !needed.isEmpty {
            rep.sections.append(ReportSection(id: "libs", title: L("必要なライブラリ", "Needed Libraries"), symbol: "books.vertical",
                blocks: [.table(TableData(columns: [L("ライブラリ", "Library")], rows: needed.map { [$0] }))], count: needed.count))
        }

        if !phs.isEmpty {
            let rows: [[String]] = phs.map { p in
                let f = (p.flags & 4 != 0 ? "r" : "-") + (p.flags & 2 != 0 ? "w" : "-") + (p.flags & 1 != 0 ? "x" : "-")
                return [ptypes[p.type] ?? hex(p.type), hex(p.off), hex(p.vaddr), byteSize(p.filesz), byteSize(Int(clamping: p.memsz)), f]
            }
            rep.sections.append(ReportSection(id: "segments", title: L("セグメント", "Segments"), symbol: "rectangle.split.3x1",
                blocks: [.table(TableData(columns: [L("種類", "Type"), L("オフセット", "Offset"), L("アドレス", "Address"), L("ファイル上", "In file"), L("メモリ上", "In memory"), L("保護", "Prot")], rows: rows))],
                count: phs.count))
        }

        if !shs.isEmpty {
            let rows: [[String]] = shs.dropFirst().map { s in
                var f = ""
                if s.flags & 2 != 0 { f += "A" }
                if s.flags & 1 != 0 { f += "W" }
                if s.flags & 4 != 0 { f += "X" }
                if s.flags & 0x400 != 0 { f += "T" }
                return [s.name, stypes[s.type] ?? hex(s.type), hex(s.addr), byteSize(s.size), f]
            }
            rep.sections.append(ReportSection(id: "sections", title: L("セクション", "Sections"), symbol: "square.stack.3d.up",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("種類", "Type"), L("アドレス", "Address"), L("サイズ", "Size"), L("フラグ", "Flags")], rows: rows))],
                count: rows.count))
        }

        if importTotal > 0 {
            rep.sections.append(ReportSection(id: "imports", title: L("インポート", "Imports"), symbol: "arrow.down.to.line",
                blocks: [.table(TableData(columns: [L("シンボル", "Symbol")], rows: imports.map { [$0] }, total: importTotal))], count: importTotal))
        }
        if exportTotal > 0 {
            rep.sections.append(ReportSection(id: "exports", title: L("エクスポート", "Exports"), symbol: "arrow.up.to.line",
                blocks: [.table(TableData(columns: [L("シンボル", "Symbol")], rows: exports.map { [$0] }, total: exportTotal))], count: exportTotal))
        }

        if opts.deep, let s = section(".rodata") {
            let strs = asciiStrings(r, s.off, s.size)
            if !strs.isEmpty {
                rep.sections.append(ReportSection(id: "strings", title: L("文字列", "Strings"), symbol: "text.quote",
                    blocks: [.table(TableData(columns: [L("文字列 (.rodata)", "String (.rodata)")], rows: strs.map { [$0] }))], count: strs.count))
            }
        }
        return rep
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
