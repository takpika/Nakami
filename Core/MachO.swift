import Foundation

struct MachOSection { var seg: String; var name: String; var addr: UInt64; var size: UInt64; var offset: Int }
struct MachOSegment { var name: String; var vmaddr: UInt64; var vmsize: UInt64; var fileoff: UInt64; var filesize: UInt64; var maxprot: UInt32; var initprot: UInt32; var sections: [MachOSection] }
struct MachODylib { var kind: String; var name: String; var current: String; var compat: String }

struct MachOSlice {
    var offset = 0
    var size = 0
    var is64 = true
    var little = true
    var cputype: UInt32 = 0
    var cpusubtype: UInt32 = 0
    var filetype: UInt32 = 0
    var flags: UInt32 = 0
    var commands: [(name: String, size: Int)] = []
    var dylibs: [MachODylib] = []
    var idDylib: MachODylib?
    var rpaths: [String] = []
    var uuid: String?
    var platform: String?
    var minOS: String?
    var sdk: String?
    var tools: [String] = []
    var sourceVersion: String?
    var segments: [MachOSegment] = []
    var encrypted: Bool?
    var nsyms = 0
    var symoff = 0, stroff = 0, strsize = 0
    var dysym: (iext: Int, next: Int, iundef: Int, nundef: Int, nlocal: Int)?
    var codeSig: CodeSignature?
    var dylinker: String?
    var chainedFixups = false
    var entryOff: UInt64?
    var dyldEnv: [String] = []
    var exports: [String] = []
    var imports: [(name: String, lib: String)] = []
    var exportTotal = 0, importTotal = 0
    var infoPlist: [String: Any]?
    var languages: [String] = []

    var arch: String { MachO.archName(cputype, cpusubtype) }

    var fileTypeName: String {
        switch filetype {
        case 1: return L("オブジェクトファイル", "Object file")
        case 2: return L("実行ファイル", "Executable")
        case 4: return L("コアダンプ", "Core dump")
        case 5: return L("プリロード実行ファイル", "Preloaded executable")
        case 6: return L("ダイナミックライブラリ", "Dynamic library")
        case 7: return L("ダイナミックリンカー", "Dynamic linker")
        case 8: return L("バンドル（プラグイン）", "Bundle (plug-in)")
        case 9: return L("ライブラリスタブ", "Library stub")
        case 10: return L("デバッグシンボル (dSYM)", "Debug symbols (dSYM)")
        case 11: return L("カーネル拡張", "Kernel extension")
        case 12: return L("ファイルセット", "Fileset")
        default: return "Mach-O type \(filetype)"
        }
    }

    static let flagNames: [(UInt32, String)] = [
        (0x1, "NOUNDEFS"), (0x4, "DYLDLINK"), (0x80, "TWOLEVEL"), (0x2000, "SUBSECTIONS_VIA_SYMBOLS"),
        (0x8000, "WEAK_DEFINES"), (0x10000, "BINDS_TO_WEAK"), (0x20000, "ALLOW_STACK_EXECUTION"),
        (0x200000, "PIE"), (0x800000, "HAS_TLV_DESCRIPTORS"), (0x1000000, "NO_HEAP_EXECUTION"),
        (0x2000000, "APP_EXTENSION_SAFE"), (0x80000000, "DYLIB_IN_CACHE"),
    ]
}

enum MachO {
    static func archName(_ t: UInt32, _ s: UInt32) -> String {
        let sub = s & 0x00ff_ffff
        switch t {
        case 7: return "i386"
        case 0x0100_0007: return sub == 8 ? "x86_64h" : "x86_64"
        case 12:
            switch sub { case 6: return "armv6"; case 9: return "armv7"; case 11: return "armv7s"; case 12: return "armv7k"; default: return "arm" }
        case 0x0100_000c: return sub == 2 ? "arm64e" : "arm64"
        case 0x0200_000c: return "arm64_32"
        case 18: return "ppc"
        case 0x0100_0012: return "ppc64"
        default: return "cpu \(hex(t))"
        }
    }

    static func ver(_ v: UInt32) -> String {
        let p = v & 0xff
        return "\(v >> 16).\((v >> 8) & 0xff)" + (p != 0 ? ".\(p)" : "")
    }

    static let platforms: [UInt32: String] = [
        1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS", 6: "Mac Catalyst",
        7: "iOS Simulator", 8: "tvOS Simulator", 9: "watchOS Simulator", 10: "DriverKit",
        11: "visionOS", 12: "visionOS Simulator",
    ]

    static let cmdNames: [UInt32: String] = [
        0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0x4: "LC_THREAD", 0x5: "LC_UNIXTHREAD", 0xb: "LC_DYSYMTAB",
        0xc: "LC_LOAD_DYLIB", 0xd: "LC_ID_DYLIB", 0xe: "LC_LOAD_DYLINKER", 0xf: "LC_ID_DYLINKER",
        0x11: "LC_ROUTINES", 0x12: "LC_SUB_FRAMEWORK", 0x14: "LC_SUB_CLIENT", 0x18: "LC_LOAD_WEAK_DYLIB",
        0x19: "LC_SEGMENT_64", 0x1a: "LC_ROUTINES_64", 0x1b: "LC_UUID", 0x1c: "LC_RPATH",
        0x1d: "LC_CODE_SIGNATURE", 0x1e: "LC_SEGMENT_SPLIT_INFO", 0x1f: "LC_REEXPORT_DYLIB",
        0x20: "LC_LAZY_LOAD_DYLIB", 0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO",
        0x23: "LC_LOAD_UPWARD_DYLIB", 0x24: "LC_VERSION_MIN_MACOSX", 0x25: "LC_VERSION_MIN_IPHONEOS",
        0x26: "LC_FUNCTION_STARTS", 0x27: "LC_DYLD_ENVIRONMENT", 0x28: "LC_MAIN", 0x29: "LC_DATA_IN_CODE",
        0x2a: "LC_SOURCE_VERSION", 0x2b: "LC_DYLIB_CODE_SIGN_DRS", 0x2c: "LC_ENCRYPTION_INFO_64",
        0x2d: "LC_LINKER_OPTION", 0x2e: "LC_LINKER_OPTIMIZATION_HINT", 0x2f: "LC_VERSION_MIN_TVOS",
        0x30: "LC_VERSION_MIN_WATCHOS", 0x31: "LC_NOTE", 0x32: "LC_BUILD_VERSION",
        0x33: "LC_DYLD_EXPORTS_TRIE", 0x34: "LC_DYLD_CHAINED_FIXUPS", 0x35: "LC_FILESET_ENTRY",
        0x36: "LC_ATOM_INFO",
    ]

    static func isMachO(_ r: Reader) -> Bool {
        let m = r.be32(0)
        if [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe].contains(m) { return true }
        if m == 0xcafe_babe || m == 0xcafe_babf { return r.be32(4) > 0 && r.be32(4) < 40 }  // not a Java class
        return false
    }

    /// All slices of a thin or universal file.
    static func parse(_ data: Data, opts: AnalyzeOptions) -> [MachOSlice] {
        let r = Reader(data, little: false)
        let m = r.be32(0)
        var ranges = [(Int, Int)]()
        if m == 0xcafe_babe || m == 0xcafe_babf {
            let n = Int(r.be32(4))
            guard n > 0, n < 40 else { return [] }
            for i in 0..<n {
                if m == 0xcafe_babe {
                    ranges.append((Int(r.be32(8 + i * 20 + 8)), Int(r.be32(8 + i * 20 + 12))))
                } else {
                    ranges.append((Int(clamping: r.be64(8 + i * 32 + 8)), Int(clamping: r.be64(8 + i * 32 + 16))))
                }
            }
        } else {
            ranges.append((0, data.count))
        }
        return ranges.compactMap { parseSlice(data, $0.0, $0.1, opts: opts) }
    }

    static func parseSlice(_ data: Data, _ base: Int, _ size: Int, opts: AnalyzeOptions) -> MachOSlice? {
        var r = Reader(data, little: true)
        guard r.ok(base, 28) else { return nil }
        var s = MachOSlice()
        s.offset = base
        s.size = size
        switch r.be32(base) {
        case 0xfeed_face: s.is64 = false; s.little = false
        case 0xfeed_facf: s.is64 = true; s.little = false
        case 0xcefa_edfe: s.is64 = false; s.little = true
        case 0xcffa_edfe: s.is64 = true; s.little = true
        default: return nil
        }
        r.little = s.little
        s.cputype = r.u32(base + 4)
        s.cpusubtype = r.u32(base + 8)
        s.filetype = r.u32(base + 12)
        let ncmds = Int(r.u32(base + 16))
        s.flags = r.u32(base + 24)
        var p = base + (s.is64 ? 32 : 28)
        var sigOff = 0, sigSize = 0

        func lcStr(_ p: Int, _ size: Int, _ field: Int) -> String {
            let o = Int(r.u32(p + field))
            guard o < size else { return "" }
            return r.cstr(p + o, max: size - o)
        }

        for _ in 0..<Swift.min(ncmds, 4096) {
            guard r.ok(p, 8) else { break }
            let cmd = r.u32(p)
            let csize = Int(r.u32(p + 4))
            guard csize >= 8, r.ok(p, csize) else { break }
            let base0 = cmd & 0x7fff_ffff
            s.commands.append((cmdNames[base0] ?? hex(cmd), csize))
            switch base0 {
            case 0x1, 0x19:
                let is64 = base0 == 0x19
                var seg = MachOSegment(
                    name: r.fixedStr(p + 8, 16),
                    vmaddr: is64 ? r.u64(p + 24) : UInt64(r.u32(p + 24)),
                    vmsize: is64 ? r.u64(p + 32) : UInt64(r.u32(p + 28)),
                    fileoff: is64 ? r.u64(p + 40) : UInt64(r.u32(p + 32)),
                    filesize: is64 ? r.u64(p + 48) : UInt64(r.u32(p + 36)),
                    maxprot: r.u32(p + (is64 ? 56 : 40)), initprot: r.u32(p + (is64 ? 60 : 44)), sections: [])
                let nsects = Int(r.u32(p + (is64 ? 64 : 48)))
                var q = p + (is64 ? 72 : 56)
                for _ in 0..<Swift.min(nsects, 1024) {
                    guard r.ok(q, is64 ? 80 : 68) else { break }
                    seg.sections.append(MachOSection(
                        seg: r.fixedStr(q + 16, 16), name: r.fixedStr(q, 16),
                        addr: is64 ? r.u64(q + 32) : UInt64(r.u32(q + 32)),
                        size: is64 ? r.u64(q + 40) : UInt64(r.u32(q + 36)),
                        offset: Int(r.u32(q + (is64 ? 48 : 40)))))
                    q += is64 ? 80 : 68
                }
                s.segments.append(seg)
            case 0x2:
                s.symoff = Int(r.u32(p + 8)); s.nsyms = Int(r.u32(p + 12))
                s.stroff = Int(r.u32(p + 16)); s.strsize = Int(r.u32(p + 20))
            case 0xb:
                s.dysym = (Int(r.u32(p + 16)), Int(r.u32(p + 20)), Int(r.u32(p + 24)), Int(r.u32(p + 28)), Int(r.u32(p + 12)))
            case 0xc, 0xd, 0x18, 0x1f, 0x20, 0x23:
                let kinds: [UInt32: String] = [0xc: "", 0x18: "weak", 0x1f: "reexport", 0x20: "lazy", 0x23: "upward"]
                let d = MachODylib(kind: kinds[base0] ?? "", name: lcStr(p, csize, 8),
                                   current: ver3(r.u32(p + 16)), compat: ver3(r.u32(p + 20)))
                if base0 == 0xd { s.idDylib = d } else { s.dylibs.append(d) }
            case 0xe: s.dylinker = lcStr(p, csize, 8)
            case 0x1b:
                let u = r.bytes(p + 8, 16)
                if u.count == 16 { s.uuid = NSUUID(uuidBytes: [UInt8](u)).uuidString }
            case 0x1c: s.rpaths.append(lcStr(p, csize, 8))
            case 0x1d: sigOff = Int(r.u32(p + 8)); sigSize = Int(r.u32(p + 12))
            case 0x21, 0x2c: s.encrypted = r.u32(p + 16) != 0
            case 0x24, 0x25, 0x2f, 0x30:
                s.platform = [0x24: "macOS", 0x25: "iOS", 0x2f: "tvOS", 0x30: "watchOS"][base0]
                s.minOS = ver(r.u32(p + 8)); s.sdk = ver(r.u32(p + 12))
            case 0x27: s.dyldEnv.append(lcStr(p, csize, 8))
            case 0x28: s.entryOff = r.u64(p + 8)
            case 0x2a:
                let v = r.u64(p + 8)
                let parts = [v >> 40, (v >> 30) & 0x3ff, (v >> 20) & 0x3ff, (v >> 10) & 0x3ff, v & 0x3ff]
                var a = parts.map { String($0) }
                while a.count > 2, a.last == "0" { a.removeLast() }
                if v != 0 { s.sourceVersion = a.joined(separator: ".") }
            case 0x32:
                let plat = platforms[r.u32(p + 8)] ?? "platform \(r.u32(p + 8))"
                if s.platform == nil {
                    s.platform = plat; s.minOS = ver(r.u32(p + 12)); s.sdk = ver(r.u32(p + 16))
                } else {
                    // Second LC_BUILD_VERSION (e.g. zippered macOS + Catalyst).
                    s.platform! += " / " + plat
                }
                let nt = Int(r.u32(p + 20))
                for i in 0..<Swift.min(nt, 8) {
                    let tool = [1: "clang", 2: "swift", 3: "ld", 4: "lld"][r.u32(p + 24 + i * 8)] ?? "tool \(r.u32(p + 24 + i * 8))"
                    s.tools.append("\(tool) \(ver(r.u32(p + 28 + i * 8)))")
                }
            case 0x34: s.chainedFixups = true
            default: break
            }
            p += csize
        }

        if sigOff > 0 {
            s.codeSig = CodeSignature.parse(Reader(data), at: base + sigOff, size: sigSize, trust: false)
        }

        // Language / runtime hints from section names.
        let names = Set(s.segments.flatMap { $0.sections.map { $0.name } })
        if names.contains(where: { $0.hasPrefix("__swift5") }) { s.languages.append("Swift") }
        if names.contains("__objc_classlist") || names.contains("__objc_selrefs") { s.languages.append("Objective-C") }
        if names.contains("__go_buildinfo") || names.contains("__gopclntab") { s.languages.append("Go") }

        if let sec = s.segments.flatMap({ $0.sections }).first(where: { $0.name == "__info_plist" }) {
            let d = r.bytes(base + sec.offset, Int(clamping: sec.size))
            s.infoPlist = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any]
        }

        // Symbols.
        if let dy = s.dysym, s.nsyms > 0, !opts.light {
            let entry = s.is64 ? 16 : 12
            let cap = opts.deep ? 20000 : 1500
            func name(_ i: Int) -> (String, UInt16) {
                let e = base + s.symoff + i * entry
                let strx = Int(r.u32(e))
                guard strx < s.strsize else { return ("", 0) }
                return (r.cstr(base + s.stroff + strx, max: 1024), r.u16(e + 6))
            }
            s.exportTotal = dy.next
            s.importTotal = dy.nundef
            for i in dy.iext..<(dy.iext + Swift.min(dy.next, cap)) where i < s.nsyms {
                s.exports.append(name(i).0)
            }
            var rust = false
            for i in dy.iundef..<(dy.iundef + Swift.min(dy.nundef, cap)) where i < s.nsyms {
                let (n, desc) = name(i)
                let ord = Int(desc >> 8) & 0xff
                var lib = ""
                if s.flags & 0x80 != 0, ord >= 1, ord <= s.dylibs.count {
                    lib = (s.dylibs[ord - 1].name as NSString).lastPathComponent
                }
                s.imports.append((n, lib))
            }
            if s.nsyms < 400_000 {
                let probe = Data("rust_eh_personality".utf8)
                let st = base + s.stroff
                if r.ok(st, s.strsize), s.strsize < 64 << 20 {
                    rust = data.range(of: probe, in: (data.startIndex + st)..<(data.startIndex + st + s.strsize)) != nil
                }
            }
            if rust { s.languages.append("Rust") }
        }
        return s
    }

    static func ver3(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)" }

    /// The slice that would run here (arm64 first), else the first one.
    static func preferred(_ slices: [MachOSlice]) -> MachOSlice? {
        slices.first { $0.cputype == 0x0100_000c } ?? slices.first { $0.cputype == 0x0100_0007 } ?? slices.first
    }

    static func prot(_ p: UInt32) -> String {
        (p & 1 != 0 ? "r" : "-") + (p & 2 != 0 ? "w" : "-") + (p & 4 != 0 ? "x" : "-")
    }

    // MARK: Report

    static func archSummary(_ slices: [MachOSlice]) -> String {
        slices.map { $0.arch }.joined(separator: ", ") + (slices.count > 1 ? L("（ユニバーサル）", " (universal)") : "")
    }

    static func osText(_ s: MachOSlice) -> String? {
        guard let p = s.platform else { return nil }
        return p + (s.minOS.map { " \($0) " + L("以降", "or later") } ?? "")
    }

    /// Sections describing the executable itself (shared with bundle reports).
    static func sections(_ slices: [MachOSlice], data: Data, opts: AnalyzeOptions, includeSignature: Bool) -> [ReportSection] {
        guard let s = preferred(slices) else { return [] }
        var out = [ReportSection]()
        let multi = slices.count > 1
        let which = multi ? L("（\(s.arch) スライス）", " (\(s.arch) slice)") : ""

        // Executable overview.
        var rows = [Row]()
        rows.add(L("種類", "Type"), s.fileTypeName + (s.is64 ? L("、64 ビット", ", 64-bit") : L("、32 ビット", ", 32-bit")))
        rows.add(L("対応 OS", "Platform"), osText(s))
        rows.add("SDK", s.sdk)
        rows.add(L("ビルドツール", "Build tools"), s.tools.joined(separator: ", "))
        rows.add(L("言語", "Languages"), s.languages.joined(separator: ", "))
        rows.add("UUID", s.uuid, mono: true)
        rows.add(L("ソースバージョン", "Source version"), s.sourceVersion)
        if let id = s.idDylib {
            rows.add(L("インストール名", "Install name"), id.name, mono: true)
            rows.add(L("ライブラリのバージョン", "Library version"), "\(id.current) (" + L("互換 ", "compat ") + "\(id.compat))")
        }
        rows.add(L("ダイナミックリンカー", "Dynamic linker"), s.dylinker, mono: true)
        if let e = s.encrypted {
            rows.add(L("暗号化 (FairPlay)", "Encrypted (FairPlay)"), e ? L("はい", "Yes") : L("いいえ（復号済み）", "No (decrypted)"), tone: e ? .warn : .neutral)
        }
        let fl = MachOSlice.flagNames.filter { s.flags & $0.0 != 0 }.map { $0.1 }
        rows.add(L("フラグ", "Flags"), fl.joined(separator: ", "), mono: true)
        if s.flags & 0x20000 != 0 { rows.add(L("スタック実行", "Stack execution"), L("許可されている", "Allowed"), tone: .warn) }
        rows.add(L("シンボル", "Symbols"), "\(s.nsyms)" + L(" 個", "") + ((s.dysym?.nlocal ?? 1) == 0 ? L("（ローカルシンボル削除済み）", " (stripped)") : ""))
        rows.add(L("再配置", "Fixups"), s.chainedFixups ? "chained fixups" : nil)
        rows.add(L("dyld 環境変数", "dyld environment"), s.dyldEnv.joined(separator: "\n"), mono: true)
        var blocks: [Block] = [.rows(rows)]
        if multi {
            blocks.append(.heading(L("アーキテクチャ", "Architectures")))
            blocks.append(.table(TableData(
                columns: [L("アーキテクチャ", "Arch"), L("サイズ", "Size"), L("オフセット", "Offset"), L("対応 OS", "Platform"), "UUID"],
                rows: slices.map { [$0.arch, byteSize($0.size), hex($0.offset), osText($0) ?? "", $0.uuid ?? ""] })))
        }
        out.append(ReportSection(id: "macho", title: L("実行ファイル", "Executable") + which, symbol: "cpu", blocks: blocks))

        if includeSignature, let sig = s.codeSig {
            out.append(ReportSection(id: "signature", title: L("コード署名", "Code Signature"), symbol: "checkmark.seal", blocks: [.rows(signatureRows(sig))]))
            if let e = sig.entitlements, !e.isEmpty { out.append(entitlementsSection(e)) }
        }

        if !s.dylibs.isEmpty || !s.rpaths.isEmpty {
            var b: [Block] = [.table(TableData(
                columns: [L("ライブラリ", "Library"), L("バージョン", "Version"), L("種別", "Kind")],
                rows: s.dylibs.map { [$0.name, $0.current, $0.kind] }))]
            if !s.rpaths.isEmpty {
                b.append(.heading("RPATH"))
                b.append(.table(TableData(columns: [L("検索パス", "Search path")], rows: s.rpaths.map { [$0] })))
            }
            out.append(ReportSection(id: "libs", title: L("リンクしているライブラリ", "Linked Libraries"), symbol: "books.vertical", blocks: b, count: s.dylibs.count))
        }

        if !s.segments.isEmpty {
            var trows = [[String]]()
            for seg in s.segments {
                trows.append([seg.name, "", hex(seg.vmaddr), byteSize(Int(clamping: seg.vmsize)), byteSize(Int(clamping: seg.filesize)), prot(seg.initprot)])
                for sec in seg.sections {
                    trows.append(["", sec.name, hex(sec.addr), byteSize(Int(clamping: sec.size)), "", ""])
                }
            }
            out.append(ReportSection(id: "segments", title: L("セグメントとセクション", "Segments & Sections"), symbol: "square.stack.3d.up",
                blocks: [.table(TableData(columns: [L("セグメント", "Segment"), L("セクション", "Section"), L("アドレス", "Address"), L("サイズ", "Size"), L("ファイル上", "In file"), L("保護", "Prot")], rows: trows))],
                count: s.segments.count))
        }

        if s.importTotal > 0 {
            out.append(ReportSection(id: "imports", title: L("インポート", "Imports"), symbol: "arrow.down.to.line",
                blocks: [.table(TableData(columns: [L("シンボル", "Symbol"), L("ライブラリ", "Library")], rows: s.imports.map { [$0.name, $0.lib] }, total: s.importTotal))],
                count: s.importTotal))
        }
        if s.exportTotal > 0 {
            out.append(ReportSection(id: "exports", title: L("エクスポート", "Exports"), symbol: "arrow.up.to.line",
                blocks: [.table(TableData(columns: [L("シンボル", "Symbol")], rows: s.exports.map { [$0] }, total: s.exportTotal))],
                count: s.exportTotal))
        }

        out.append(ReportSection(id: "loadcmds", title: L("ロードコマンド", "Load Commands"), symbol: "list.number",
            blocks: [.table(TableData(columns: ["#", L("コマンド", "Command"), L("サイズ", "Size")],
                                      rows: s.commands.enumerated().map { ["\($0.offset)", $0.element.name, "\($0.element.size)"] }))],
            count: s.commands.count))

        if let p = s.infoPlist, !p.isEmpty {
            out.append(ReportSection(id: "embedded-plist", title: L("埋め込み Info.plist", "Embedded Info.plist"), symbol: "doc.text",
                blocks: [.table(TableData(columns: [L("キー", "Key"), L("値", "Value")], rows: p.keys.sorted().map { [$0, describePlistValue(p[$0]!)] }))]))
        }

        if opts.deep, let sec = s.segments.flatMap({ $0.sections }).first(where: { $0.name == "__cstring" }) {
            let strs = asciiStrings(Reader(data), s.offset + sec.offset, Int(clamping: sec.size))
            if !strs.isEmpty {
                out.append(ReportSection(id: "strings", title: L("文字列", "Strings"), symbol: "text.quote",
                    blocks: [.table(TableData(columns: [L("文字列 (__cstring)", "String (__cstring)")], rows: strs.map { [$0] }))], count: strs.count))
            }
        }
        return out
    }

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report {
        var rep = Report(kind: .macho, path: url.path, title: url.lastPathComponent)
        let slices = parse(data, opts: opts)
        guard let s = preferred(slices) else {
            rep.subtitle = L("Mach-O（解析できませんでした）", "Mach-O (could not be parsed)")
            return rep
        }
        rep.subtitle = "Mach-O " + s.fileTypeName + " · " + slices.map { $0.arch }.joined(separator: " / ")
        if let sig = s.codeSig {
            rep.badges.append(Badge(text: sig.cms?.names.first != nil ? L("署名済み", "Signed") : L("アドホック署名", "Ad hoc"),
                                    tone: sig.hasCMS ? .good : .neutral))
            if sig.hardenedRuntime { rep.badges.append(Badge(text: "Hardened Runtime", tone: .good)) }
            if sig.sandboxed { rep.badges.append(Badge(text: "App Sandbox", tone: .good)) }
        } else {
            rep.badges.append(Badge(text: L("署名なし", "Unsigned"), tone: .warn))
        }
        if s.encrypted == true { rep.badges.append(Badge(text: L("暗号化", "Encrypted"), tone: .warn)) }

        var sum = [Row]()
        sum.add(L("種類", "Kind"), s.fileTypeName)
        sum.add(L("アーキテクチャ", "Architectures"), archSummary(slices))
        sum.add(L("対応 OS", "Platform"), osText(s))
        sum.add(L("署名", "Signature"), s.codeSig?.signerText ?? L("なし", "None"))
        sum.add("Team ID", s.codeSig?.teamID, mono: true)
        sum.add(L("言語", "Languages"), s.languages.joined(separator: ", "))
        sum.add(L("ライブラリ", "Libraries"), s.dylibs.isEmpty ? nil : "\(s.dylibs.count)" + L(" 個にリンク", " linked"))
        sum.add(L("サイズ", "Size"), byteSizeExact(data.count))
        rep.summary = sum
        rep.sections = sections(slices, data: data, opts: opts, includeSignature: true)
        // The macOS kernel itself.
        if let v = Kernels.xnuVersion(data, slice: s) {
            let kind = L("macOS のカーネル (XNU)", "macOS kernel (XNU)")
            rep.subtitle = kind + " · " + slices.map { $0.arch }.joined(separator: " / ")
            rep.badges.insert(Badge(text: L("カーネル", "Kernel"), tone: .info), at: 0)
            if let i = rep.summary.firstIndex(where: { $0.key == L("種類", "Kind") }) { rep.summary[i] = Row(L("種類", "Kind"), kind) }
            if !v.isEmpty {
                rep.title = firstMatch(v, #"(Darwin Kernel Version [\d.]+)"#) ?? rep.title
                rep.summary.insert(Row(L("カーネルのバージョン", "Kernel version"), v), at: 1)
                if let x = firstMatch(v, #"(xnu-[\d.~]+)"#) { rep.summary.insert(Row("XNU", x, mono: true), at: 2) }
                if let c = firstMatch(v, #"/([A-Z]+_[A-Z0-9_]+)\s*$"#) { rep.summary.insert(Row(L("ビルド構成", "Configuration"), c, mono: true), at: 3) }
            }
        }
        return rep
    }
}
