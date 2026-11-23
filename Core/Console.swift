import Foundation
import CoreGraphics

/// Game console ROMs and disc images. Only what the files say in the clear is read: no decryption, no keys.
enum Console {
    // MARK: Shared helpers

    static let makers: [String: String] = [
        "01": "Nintendo", "08": "Capcom", "0A": "Jaleco", "13": "Electronic Arts", "18": "Hudson Soft", "20": "Destination Software", "28": "Kemco",
        "34": "Konami", "36": "Codemasters", "41": "Ubisoft", "4F": "Eidos", "4Q": "Disney", "51": "Acclaim", "52": "Activision", "54": "Take-Two",
        "5D": "Midway", "5G": "Majesco", "64": "LucasArts", "69": "Electronic Arts", "6S": "TDK", "70": "Atari", "78": "THQ", "7D": "Vivendi",
        "8P": "Sega", "99": "Marvelous", "9B": "Tecmo", "A4": "Konami", "AF": "Bandai Namco", "B1": "ASCII / Enterbrain", "B2": "Bandai",
        "B4": "Enix", "BB": "Sunsoft", "C0": "Taito", "C8": "Koei", "E7": "Athena", "E9": "Natsume", "EB": "Atlus", "G9": "D3 Publisher",
        "GD": "Square Enix", "GT": "505 Games", "H4": "SNK", "JF": "Kemco", "MH": "MHS", "NK": "Neko Entertainment", "WR": "Warner Bros.", "C0J": "Taito",
    ]
    static func maker(_ code: String) -> String { makers[code].map { "\($0) (\(code))" } ?? code }

    static func region(_ c: Character) -> String? {
        switch c {
        case "J": return L("日本", "Japan")
        case "E": return L("北米", "North America")
        case "P": return L("欧州", "Europe")
        case "K": return L("韓国", "Korea")
        case "U": return L("オーストラリア", "Australia")
        case "D": return L("ドイツ", "Germany")
        case "F": return L("フランス", "France")
        case "I": return L("イタリア", "Italy")
        case "S": return L("スペイン", "Spain")
        case "C": return L("中国", "China")
        case "W": return L("台湾 / 香港", "Taiwan / Hong Kong")
        case "A", "O": return L("全地域", "All regions")
        default: return nil
        }
    }

    static func text(_ d: Data) -> String {
        let cut = d.firstIndex(of: 0).map { d.prefix(upTo: $0) } ?? d
        if let s = String(data: cut, encoding: .utf8), !s.contains("\u{fffd}") { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (String(data: cut, encoding: .shiftJIS) ?? String(decoding: cut, as: Unicode.ASCII.self)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small pixel icons are enlarged with hard edges so they stay crisp at any display size.
    static func image(width: Int, height: Int, scale: Int = 8, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage? {
        let W = width * scale, H = height * scale
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let pr = UInt8(Int(r) * Int(a) / 255), pg = UInt8(Int(g) * Int(a) / 255), pb = UInt8(Int(b) * Int(a) / 255)
                for sy in 0..<scale {
                    var o = ((y * scale + sy) * W + x * scale) * 4
                    for _ in 0..<scale { buf[o] = pr; buf[o + 1] = pg; buf[o + 2] = pb; buf[o + 3] = a; o += 4 }
                }
            }
        }
        guard let p = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func crc16(_ r: Reader, _ off: Int, _ len: Int) -> UInt16 {
        var crc: UInt16 = 0xffff
        for i in 0..<len {
            crc ^= UInt16(r.u8(off + i))
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return crc
    }

    static func base(_ url: URL, _ title: String, _ subtitle: String, kind: ReportKind = .rom) -> Report {
        var rep = Report(kind: kind, path: url.path, title: title.isEmpty ? url.lastPathComponent : title)
        rep.subtitle = subtitle
        return rep
    }

    // MARK: Dispatch

    static func report(url: URL, data: Data, opts: AnalyzeOptions) -> Report? {
        let r = Reader(data, little: true)
        let n = data.count
        if n >= 16, r.be32(0) == 0x4e45_531a { return nes(url, r) }
        if n >= 0x150, r.be32(0x104) == 0xceed_6666, r.be32(0x108) == 0xcc0d_000b { return gameBoy(url, r) }
        if n >= 0xc0, r.be32(4) == 0x24ff_ae51, r.u8(0xb2) == 0x96 { return gba(url, r) }
        if n >= 0x200, r.u16(0x15c) == 0xcf56, crc16(r, 0, 0x15e) == r.u16(0x15e) { return nds(url, r, opts) }
        if n >= 0x40, [0x8037_1240, 0x3780_4012, 0x4012_3780].contains(r.be32(0)) { return n64(url, r) }
        if n >= 0x440, r.be32(0x18) == 0x5d1c_9ea3 || r.be32(0x1c) == 0xc233_9f3d { return disc(url, size: n, opts: opts) { off, len in r.bytes(off, len) } }
        if n >= 0x400, r.fixedStr(0, 4) == "WBFS" { return wbfs(url, r, opts) }
        if n >= 0x2040, r.u32(0) == 0x2020, r.u16(4) <= 1, Int(r.u32(8)) < 0x4000, Int(r.u32(12)) < 0x4000 { return cia(url, r) }
        if n >= 0x20, r.fixedStr(0, 4) == "3DSX" { return threeDSX(url, r) }
        if n >= 0x28, r.be32(0) == 0x0050_4250 { return pbp(url, r) }
        if n >= 0x200, r.fixedStr(0x100, 4) == "SEGA" { return megaDrive(url, r) }
        if let s = snes(url, r) { return s }
        if let iso = ISO9660(data) {
            let rep = isoReport(url, iso, data: data, size: n, opts: opts)
            // Recognised from the ISO 9660 side (an OS installer, a game): done.
            if !rep.badges.isEmpty { return rep }
            // Mac hybrid discs keep the real contents in an Apple partition next to a small ISO 9660 part.
            return DiskImage.report(url: url, data: data, opts: opts, requireApple: true) ?? rep
        }
        return DiskImage.report(url: url, data: data, opts: opts)
    }

    /// Embedded game icon, for Finder / Files thumbnails.
    static func icon(_ data: Data) -> CGImage? {
        let r = Reader(data, little: true)
        let n = data.count
        if n >= 0x200, r.u16(0x15c) == 0xcf56 { return ndsBanner(r)?.icon }
        if n >= 0x2040, r.u32(0) == 0x2020 {
            let inner = ciaInner(r)
            return (ciaSMDH(r) ?? inner.smdh).flatMap { smdhIcon(r, $0) } ?? inner.nds.flatMap { ndsBanner($0)?.icon }
        }
        if n >= 0x28, r.fixedStr(0, 4) == "3DSX", Int(r.u16(4)) > 32 { return smdhIcon(r, Int(r.u32(32))) }
        if n >= 0x28, r.be32(0) == 0x0050_4250 { return pbpParts(r).icon.flatMap { ImageKit.decode($0) } }
        if n >= 0x440, r.be32(0x1c) == 0xc233_9f3d { return gcBanner { off, len in r.bytes(off, len) }?.icon }
        if let iso = ISO9660(data), let e = iso.find("PSP_GAME/ICON0.PNG"), let d = iso.read(e) { return ImageKit.decode(d) }
        return nil
    }

    // MARK: NES

    static func nes(_ url: URL, _ r: Reader) -> Report {
        let nes2 = r.u8(7) & 0x0c == 0x08
        var mapper = Int(r.u8(6) >> 4) | Int(r.u8(7) & 0xf0)
        if nes2 { mapper |= Int(r.u8(8) & 0x0f) << 8 }
        let prg = Int(r.u8(4)) * 16384, chr = Int(r.u8(5)) * 8192
        var rep = base(url, "", L("ファミコン / NES の ROM", "Famicom / NES ROM") + " · " + (nes2 ? "NES 2.0" : "iNES"))
        let mapperNames = [0: "NROM", 1: "MMC1", 2: "UxROM", 3: "CNROM", 4: "MMC3", 5: "MMC5", 7: "AxROM", 9: "MMC2", 10: "MMC4", 16: "Bandai FCG", 19: "Namco 163",
                           21: "VRC4", 23: "VRC2/4", 24: "VRC6", 25: "VRC4", 26: "VRC6", 69: "Sunsoft FME-7", 85: "VRC7"]
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("ファミコン / NES の ROM", "Famicom / NES ROM"))
        sum.add(L("形式", "Format"), nes2 ? "NES 2.0" : "iNES")
        sum.add(L("マッパー", "Mapper"), "\(mapper)" + (mapperNames[mapper].map { " (\($0))" } ?? ""))
        sum.add(L("プログラム ROM", "PRG ROM"), byteSize(prg))
        sum.add(L("キャラクター ROM", "CHR ROM"), chr == 0 ? L("なし（CHR RAM を使用）", "None (uses CHR RAM)") : byteSize(chr))
        sum.add(L("画面の向き", "Mirroring"), r.u8(6) & 8 != 0 ? L("4 画面", "Four-screen") : r.u8(6) & 1 != 0 ? L("縦ミラー（横スクロール向き）", "Vertical") : L("横ミラー（縦スクロール向き）", "Horizontal"))
        sum.add(L("バッテリーバックアップ", "Battery save"), r.u8(6) & 2 != 0 ? L("あり", "Yes") : L("なし", "No"))
        if r.u8(6) & 4 != 0 { sum.add(L("トレーナー", "Trainer"), L("あり（512 バイト）", "Present (512 bytes)")) }
        if nes2 { sum.add(L("映像方式", "TV system"), ["NTSC", "PAL", L("両対応", "Multi-region"), "Dendy"][Int(r.u8(12) & 3)]) }
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        return rep
    }

    // MARK: Game Boy

    static func gameBoy(_ url: URL, _ r: Reader) -> Report {
        let cgb = r.u8(0x143)
        let title = text(r.bytes(0x134, cgb & 0x80 != 0 ? 11 : 16))
        let sys = cgb == 0xc0 ? L("ゲームボーイカラー専用", "Game Boy Color only") : cgb == 0x80 ? L("ゲームボーイ / カラー共通", "Game Boy / Color") : L("ゲームボーイ", "Game Boy")
        var rep = base(url, title, sys + L(" の ROM", " ROM"))
        let types: [UInt8: String] = [0: "ROM", 1: "MBC1", 2: "MBC1+RAM", 3: "MBC1+RAM+BATTERY", 5: "MBC2", 6: "MBC2+BATTERY", 0x0f: "MBC3+TIMER+BATTERY", 0x10: "MBC3+TIMER+RAM+BATTERY",
                                      0x11: "MBC3", 0x12: "MBC3+RAM", 0x13: "MBC3+RAM+BATTERY", 0x19: "MBC5", 0x1a: "MBC5+RAM", 0x1b: "MBC5+RAM+BATTERY", 0x1c: "MBC5+RUMBLE",
                                      0x1e: "MBC5+RUMBLE+RAM+BATTERY", 0x20: "MBC6", 0x22: "MBC7", 0xfc: "Pocket Camera", 0xfd: "TAMA5", 0xfe: "HuC3", 0xff: "HuC1+RAM+BATTERY"]
        let ramSizes: [UInt8: Int] = [0: 0, 1: 2, 2: 8, 3: 32, 4: 128, 5: 64]
        var sum8: UInt8 = 0
        for i in 0x134...0x14c { sum8 = sum8 &- r.u8(i) &- 1 }
        let old = r.u8(0x14b)
        let licensee = old == 0x33 ? maker(r.fixedStr(0x144, 2)) : (old == 0x01 || old == 0x31 ? "Nintendo" : hex(old, pad: 2))
        var sum = [Row]()
        sum.add(L("種類", "Kind"), sys)
        sum.add(L("タイトル", "Title"), title, mono: true)
        sum.add(L("カートリッジ", "Cartridge"), types[r.u8(0x147)] ?? hex(r.u8(0x147), pad: 2))
        sum.add(L("ROM サイズ", "ROM size"), byteSize(32768 << Int(r.u8(0x148) & 0x0f)))
        sum.add(L("セーブ用 RAM", "Save RAM"), (ramSizes[r.u8(0x149)]).map { $0 == 0 ? L("なし", "None") : "\($0) KB" })
        sum.add(L("スーパーゲームボーイ", "Super Game Boy"), r.u8(0x146) == 3 ? L("対応", "Supported") : nil)
        sum.add(L("販売地域", "Region"), r.u8(0x14a) == 0 ? L("日本", "Japan") : L("海外", "Overseas"))
        sum.add(L("メーカー", "Licensee"), licensee)
        sum.add(L("バージョン", "Version"), "1.\(r.u8(0x14c))")
        sum.add(L("ヘッダーのチェックサム", "Header checksum"), sum8 == r.u8(0x14d) ? L("正しい", "Valid") : L("不一致", "Mismatch"), tone: sum8 == r.u8(0x14d) ? .good : .bad)
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        if r.u8(0x146) == 3 { rep.badges.append(Badge(text: "SGB", tone: .info)) }
        return rep
    }

    // MARK: Game Boy Advance

    static func gba(_ url: URL, _ r: Reader) -> Report {
        let title = text(r.bytes(0xa0, 12)), code = r.fixedStr(0xac, 4)
        var rep = base(url, title, L("ゲームボーイアドバンスの ROM", "Game Boy Advance ROM"))
        var chk: UInt8 = 0
        for i in 0xa0...0xbc { chk = chk &- r.u8(i) }
        chk = chk &- 0x19
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("ゲームボーイアドバンスの ROM", "Game Boy Advance ROM"))
        sum.add(L("タイトル", "Title"), title, mono: true)
        sum.add(L("ゲームコード", "Game code"), "AGB-" + code, mono: true)
        sum.add(L("販売地域", "Region"), code.last.flatMap { region($0) })
        sum.add(L("メーカー", "Maker"), maker(r.fixedStr(0xb0, 2)))
        sum.add(L("バージョン", "Version"), "1.\(r.u8(0xbc))")
        sum.add(L("ヘッダーのチェックサム", "Header checksum"), chk == r.u8(0xbd) ? L("正しい", "Valid") : L("不一致", "Mismatch"), tone: chk == r.u8(0xbd) ? .good : .bad)
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        return rep
    }

    // MARK: Nintendo DS

    /// One 32×32 icon: 4 bits per pixel in 8×8 tiles, 16-colour palette, colour 0 transparent.
    static func ndsIcon(_ r: Reader, bitmap: Int, palette: Int, flipH: Bool = false, flipV: Bool = false) -> CGImage? {
        var pal = [(UInt8, UInt8, UInt8)]()
        for i in 0..<16 {
            let c = r.u16(palette + i * 2)
            pal.append((UInt8((c & 31) * 255 / 31), UInt8(((c >> 5) & 31) * 255 / 31), UInt8(((c >> 10) & 31) * 255 / 31)))
        }
        return image(width: 32, height: 32) { px, py in
            let x = flipH ? 31 - px : px, y = flipV ? 31 - py : py
            let tile = (y / 8) * 4 + x / 8
            let byte = r.u8(bitmap + tile * 32 + (y % 8) * 4 + (x % 8) / 2)
            let idx = Int(x % 2 == 0 ? byte & 0x0f : byte >> 4)
            return idx == 0 ? (0, 0, 0, 0) : (pal[idx].0, pal[idx].1, pal[idx].2, 255)
        }
    }

    static func ndsBanner(_ r: Reader) -> (icon: CGImage?, titles: [(String, String)], frames: [IconFrame])? {
        let b = Int(r.u32(0x68))
        guard b > 0, r.ok(b, 0x840) else { return nil }
        let version = r.u16(b)
        let icon = ndsIcon(r, bitmap: b + 0x20, palette: b + 0x220)
        // DSi banners (version 0x0103) add an animated icon: 8 bitmaps, 8 palettes and a play list of up to
        // 64 steps (duration in 1/60 s, which bitmap, which palette, flips).
        var frames = [IconFrame]()
        if version & 0x100 != 0, r.ok(b + 0x1240, 0x1180) {
            var cache = [UInt16: CGImage]()
            for i in 0..<64 {
                let t = r.u16(b + 0x2340 + i * 2)
                if t == 0 { break }
                let key = t & 0xff00
                if cache[key] == nil {
                    cache[key] = ndsIcon(r, bitmap: b + 0x1240 + Int((t >> 8) & 7) * 0x200, palette: b + 0x2240 + Int((t >> 11) & 7) * 0x20,
                                         flipH: t & 0x4000 != 0, flipV: t & 0x8000 != 0)
                }
                if let img = cache[key] { frames.append(IconFrame(image: img, duration: Double(Swift.max(1, Int(t & 0xff))) / 60)) }
            }
            if Set(frames.map { ObjectIdentifier($0.image) }).count < 2 { frames = [] }   // a single repeated picture is not an animation
        }
        var langs = [L("日本語", "Japanese"), L("英語", "English"), L("フランス語", "French"), L("ドイツ語", "German"), L("イタリア語", "Italian"), L("スペイン語", "Spanish")]
        if version >= 2 { langs.append(L("中国語", "Chinese")) }
        if version >= 3 { langs.append(L("韓国語", "Korean")) }
        var titles = [(String, String)]()
        for (i, lang) in langs.enumerated() where r.ok(b + 0x240 + i * 0x100, 0x100) {
            var s = r.utf16(b + 0x240 + i * 0x100, units: 128)
            if let z = s.firstIndex(of: "\0") { s = String(s[..<z]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { titles.append((lang, s)) }
        }
        return (icon, titles, frames)
    }

    static func nds(_ url: URL, _ r: Reader, _ opts: AnalyzeOptions) -> Report {
        let short = text(r.bytes(0, 12)), code = r.fixedStr(0x0c, 4)
        let unit = r.u8(0x12)
        let banner = ndsBanner(r)
        let pick = banner?.titles.first { $0.0 == L("日本語", "Japanese") } ?? banner?.titles.first
        let lines = (pick?.1 ?? short).components(separatedBy: "\n")
        let sys = unit == 3 ? L("ニンテンドー DSi 専用", "Nintendo DSi only") : unit == 2 ? L("ニンテンドー DS（DSi 対応）", "Nintendo DS (DSi enhanced)") : L("ニンテンドー DS", "Nintendo DS")
        var rep = base(url, lines.dropLast(lines.count > 1 ? 1 : 0).joined(separator: " "), sys + L(" の ROM", " ROM"))
        rep.icon = banner?.icon
        rep.iconFrames = banner?.frames ?? []
        if !rep.iconFrames.isEmpty { rep.badges.append(Badge(text: L("アニメーションアイコン", "Animated icon"), tone: .neutral)) }
        if unit >= 2 { rep.badges.append(Badge(text: unit == 3 ? "DSi" : L("DSi 対応", "DSi enhanced"), tone: .info)) }
        var sum = [Row]()
        sum.add(L("種類", "Kind"), sys)
        sum.add(L("タイトル", "Title"), pick?.1)
        sum.add(L("内部名", "Internal name"), short, mono: true)
        sum.add(L("ゲームコード", "Game code"), (unit == 3 ? "TWL-" : "NTR-") + code, mono: true)
        sum.add(L("販売地域", "Region"), code.last.flatMap { region($0) })
        sum.add(L("メーカー", "Maker"), maker(r.fixedStr(0x10, 2)))
        sum.add(L("バージョン", "Version"), "1.\(r.u8(0x1e))")
        sum.add(L("カード容量", "Card capacity"), byteSize(131072 << Int(r.u8(0x14) & 0x0f)))
        sum.add(L("使用サイズ", "Used size"), byteSize(Int(r.u32(0x80))))
        sum.add(L("ヘッダーの検査", "Header check"), L("正しい (CRC16)", "Valid (CRC16)"), tone: .good)
        if unit >= 2, r.ok(0x230, 8) { sum.add(L("タイトル ID (DSi)", "Title ID (DSi)"), String(format: "%08X%08X", r.u32(0x234), r.u32(0x230)), mono: true) }
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        if let t = banner?.titles, t.count > 1 {
            rep.sections.append(ReportSection(id: "titles", title: L("各言語のタイトル", "Titles by Language"), symbol: "globe",
                blocks: [.table(TableData(columns: [L("言語", "Language"), L("タイトル", "Title")], rows: t.map { [$0.0, $0.1.replacingOccurrences(of: "\n", with: " / ")] }))], count: t.count))
        }
        var rows = [Row]()
        rows.add("ARM9", L("オフセット ", "offset ") + hex(r.u32(0x20)) + L("、サイズ ", ", size ") + byteSize(Int(r.u32(0x2c))), mono: true)
        rows.add("ARM7", L("オフセット ", "offset ") + hex(r.u32(0x30)) + L("、サイズ ", ", size ") + byteSize(Int(r.u32(0x3c))), mono: true)
        rows.add(L("ファイル名表", "File name table"), byteSize(Int(r.u32(0x44))))
        rows.add(L("ファイル数", "Files"), "\(Int(r.u32(0x4c)) / 8)")
        rep.sections.append(ReportSection(id: "layout", title: L("ROM の構成", "ROM Layout"), symbol: "square.stack.3d.up", blocks: [.rows(rows)]))
        return rep
    }

    // MARK: Nintendo 64

    static func n64(_ url: URL, _ r: Reader) -> Report {
        let magic = r.be32(0)
        // Normalise the first 64 bytes to big-endian (.z64) order.
        var h = [UInt8](r.bytes(0, 0x40))
        if magic == 0x3780_4012 { for i in stride(from: 0, to: 0x40, by: 2) { h.swapAt(i, i + 1) } }
        if magic == 0x4012_3780 { for i in stride(from: 0, to: 0x40, by: 4) { h.swapAt(i, i + 3); h.swapAt(i + 1, i + 2) } }
        let hr = Reader(Data(h), little: false)
        let title = text(hr.bytes(0x20, 20)), code = hr.fixedStr(0x3b, 4)
        var rep = base(url, title, L("NINTENDO 64 の ROM", "Nintendo 64 ROM"))
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("NINTENDO 64 の ROM", "Nintendo 64 ROM"))
        sum.add(L("タイトル", "Title"), title, mono: true)
        sum.add(L("ゲームコード", "Game code"), "NUS-" + code, mono: true)
        sum.add(L("販売地域", "Region"), code.last.flatMap { region($0) })
        sum.add(L("バージョン", "Version"), "1.\(hr.u8(0x3f))")
        sum.add(L("バイト順", "Byte order"), magic == 0x8037_1240 ? L("ビッグエンディアン (.z64)", "Big-endian (.z64)") : magic == 0x3780_4012 ? L("バイトスワップ (.v64)", "Byte-swapped (.v64)") : L("リトルエンディアン (.n64)", "Little-endian (.n64)"))
        sum.add("CRC", String(format: "%08X %08X", hr.u32(0x10), hr.u32(0x14)), mono: true)
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        return rep
    }

    // MARK: Super Famicom / SNES

    static func snes(_ url: URL, _ r: Reader) -> Report? {
        let n = r.count
        guard n >= 0x8000, n <= 16 << 20 else { return nil }
        let copier = n % 1024 == 512 ? 512 : 0
        for (off, name) in [(0x7fc0, "LoROM"), (0xffc0, "HiROM"), (0x40ffc0, "ExHiROM")] {
            let h = off + copier
            guard r.ok(h, 0x20) else { continue }
            let chk = r.u16(h + 0x1e), comp = r.u16(h + 0x1c)
            let titleBytes = r.bytes(h, 21)
            guard chk ^ comp == 0xffff, chk != 0, titleBytes.allSatisfy({ $0 >= 0x20 || $0 == 0 }) else { continue }
            let title = text(titleBytes)
            var rep = base(url, title, L("スーパーファミコン / SNES の ROM", "Super Famicom / SNES ROM") + " · " + name)
            let regions = [0: L("日本", "Japan"), 1: L("北米", "North America"), 2: L("欧州", "Europe"), 3: "Sweden", 6: "France", 8: "Spain", 9: "Germany", 10: "Italy", 13: "Korea"]
            var sum = [Row]()
            sum.add(L("種類", "Kind"), L("スーパーファミコン / SNES の ROM", "Super Famicom / SNES ROM"))
            sum.add(L("タイトル", "Title"), title, mono: true)
            sum.add(L("マッピング", "Mapping"), name + (r.u8(h + 0x15) & 0x10 != 0 ? L("（高速）", " (FastROM)") : ""))
            sum.add(L("ROM サイズ", "ROM size"), byteSize(1024 << Int(r.u8(h + 0x17) & 0x1f)))
            sum.add(L("セーブ用 RAM", "Save RAM"), r.u8(h + 0x18) == 0 ? L("なし", "None") : byteSize(1024 << Int(r.u8(h + 0x18) & 0x0f)))
            sum.add(L("販売地域", "Region"), regions[Int(r.u8(h + 0x19))])
            sum.add(L("バージョン", "Version"), "1.\(r.u8(h + 0x1b))")
            sum.add(L("チェックサム", "Checksum"), hex(chk, pad: 4), mono: true)
            if copier != 0 { sum.add(L("コピー機のヘッダー", "Copier header"), L("あり（512 バイト）", "Present (512 bytes)")) }
            sum.add(L("サイズ", "Size"), byteSizeExact(n))
            rep.summary = sum
            return rep
        }
        return nil
    }

    // MARK: Mega Drive

    static func megaDrive(_ url: URL, _ r: Reader) -> Report {
        let domestic = text(r.bytes(0x120, 48)), overseas = text(r.bytes(0x150, 48))
        func squeeze(_ s: String) -> String { s.split(separator: " ").joined(separator: " ") }
        var rep = base(url, squeeze(prefersJapanese && !domestic.isEmpty ? domestic : (overseas.isEmpty ? domestic : overseas)), L("メガドライブ / Genesis の ROM", "Mega Drive / Genesis ROM"))
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("メガドライブ / Genesis の ROM", "Mega Drive / Genesis ROM"))
        sum.add(L("システム", "System"), squeeze(r.fixedStr(0x100, 16)))
        sum.add(L("国内タイトル", "Domestic title"), squeeze(domestic))
        sum.add(L("海外タイトル", "Overseas title"), squeeze(overseas))
        sum.add(L("著作権表示", "Copyright"), squeeze(r.fixedStr(0x110, 16)))
        sum.add(L("シリアル", "Serial"), squeeze(r.fixedStr(0x180, 14)), mono: true)
        sum.add(L("販売地域", "Regions"), squeeze(r.fixedStr(0x1f0, 3)), mono: true)
        sum.add(L("対応デバイス", "Devices"), squeeze(r.fixedStr(0x190, 16)), mono: true)
        sum.add(L("チェックサム", "Checksum"), hex(r.be16(0x18e), pad: 4), mono: true)
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        return rep
    }

    // MARK: GameCube / Wii discs

    typealias DiscRead = (Int, Int) -> Data

    /// GameCube banner (opening.bnr in the root of the disc): 96×32 image and the game's own titles.
    static func gcBanner(_ read: DiscRead) -> (icon: CGImage?, rows: [Row])? {
        let hd = Reader(read(0x420, 16), little: false)
        let fst = Int(hd.u32(4)), fstSize = Int(hd.u32(8))
        guard fst > 0, fstSize > 12, fstSize < 8 << 20 else { return nil }
        let f = Reader(read(fst, fstSize), little: false)
        let count = Int(f.u32(8))
        guard count > 1, count * 12 < fstSize else { return nil }
        for i in 1..<Swift.min(count, 4096) {
            let e = i * 12
            guard f.u8(e) == 0, f.cstr(count * 12 + Int(f.u32(e) & 0xff_ffff), max: 32).lowercased() == "opening.bnr" else { continue }
            let b = Reader(read(Int(f.u32(e + 4)), Swift.min(Int(f.u32(e + 8)), 0x1960)), little: false)
            guard b.count >= 0x1960, b.fixedStr(0, 3) == "BNR" else { return nil }
            // RGB5A3, 4×4 tiles.
            let icon = image(width: 96, height: 32, scale: 4) { x, y in
                let tile = (y / 4) * 24 + x / 4
                let c = b.u16(0x20 + (tile * 16 + (y % 4) * 4 + x % 4) * 2)
                if c & 0x8000 != 0 { return (UInt8(((c >> 10) & 31) * 255 / 31), UInt8(((c >> 5) & 31) * 255 / 31), UInt8((c & 31) * 255 / 31), 255) }
                return (UInt8(((c >> 8) & 15) * 17), UInt8(((c >> 4) & 15) * 17), UInt8((c & 15) * 17), UInt8(((c >> 12) & 7) * 255 / 7))
            }
            var rows = [Row]()
            rows.add(L("バナーのタイトル", "Banner title"), text(b.bytes(0x1860, 0x40)))
            rows.add(L("バナーのメーカー", "Banner maker"), text(b.bytes(0x18a0, 0x40)))
            rows.add(L("説明", "Description"), text(b.bytes(0x18e0, 0x80)))
            return (icon, rows)
        }
        return nil
    }

    static func disc(_ url: URL, size: Int, container: String? = nil, opts: AnalyzeOptions, _ read: DiscRead) -> Report {
        let h = Reader(read(0, 0x100), little: false)
        let isWii = h.u32(0x18) == 0x5d1c_9ea3
        let id = h.fixedStr(0, 6)
        let title = text(h.bytes(0x20, 64))
        let name = isWii ? "Wii" : L("ゲームキューブ", "GameCube")
        var rep = base(url, title, name + L(" のディスクイメージ", " disc image") + (container.map { " (\($0))" } ?? ""), kind: .disc)
        var sum = [Row]()
        sum.add(L("種類", "Kind"), name + L(" のディスクイメージ", " disc image"))
        sum.add(L("タイトル", "Title"), title)
        sum.add(L("ゲーム ID", "Game ID"), id, mono: true)
        sum.add(L("販売地域", "Region"), id.count >= 4 ? region(Array(id)[3]) : nil)
        sum.add(L("メーカー", "Maker"), id.count >= 6 ? maker(String(id.suffix(2))) : nil)
        sum.add(L("ディスク番号", "Disc"), "\(h.u8(6) + 1)")
        sum.add(L("リビジョン", "Revision"), "\(h.u8(7))")
        sum.add(L("入れ物", "Container"), container)
        var sections = [ReportSection]()
        if isWii {
            // Partition table: four groups of (count, offset >> 2) at 0x40000.
            let pt = Reader(read(0x40000, 0x20), little: false)
            var prows = [[String]]()
            var ios: String?, titleID: String?, titleVersion: Int?
            for g in 0..<4 {
                let count = Int(pt.u32(g * 8)), tbl = Int(pt.u32(g * 8 + 4)) << 2
                guard count > 0, count < 32 else { continue }
                let t = Reader(read(tbl, count * 8), little: false)
                for i in 0..<count {
                    let off = Int(t.u32(i * 8)) << 2, type = t.u32(i * 8 + 4)
                    let kind = [0: L("ゲーム本体", "Game data"), 1: L("本体更新", "System update"), 2: L("チャンネル", "Channel")][type] ?? String(decoding: withUnsafeBytes(of: type.bigEndian) { Array($0) }, as: Unicode.ASCII.self)
                    let ph = Reader(read(off, 0x2c0), little: false)
                    let tid = String(format: "%08X%08X", ph.u32(0x1dc), ph.u32(0x1e0))
                    prows.append([kind, hex(off), tid])
                    if type == 0 {
                        titleID = tid
                        let tmdOff = Int(ph.u32(0x2a8)) << 2
                        let tmd = Reader(read(off + tmdOff, 0x1e4), little: false)
                        if tmd.count >= 0x1e0 {
                            let sys = tmd.u32(0x188)
                            if tmd.u32(0x184) == 1, sys > 0, sys < 256 { ios = "IOS\(sys)" }
                            titleVersion = Int(tmd.u16(0x1dc))
                        }
                    }
                }
            }
            let reg = Reader(read(0x4e000, 4), little: false).u32(0)
            sum.add(L("地域設定", "Region setting"), [0: L("日本", "Japan"), 1: L("北米", "North America"), 2: L("欧州", "Europe"), 4: L("韓国", "Korea")][reg])
            sum.add(L("必要な IOS", "Required IOS"), ios)
            sum.add(L("タイトル ID", "Title ID"), titleID, mono: true)
            sum.add(L("タイトルのバージョン", "Title version"), titleVersion.map { "\($0)" })
            if prows.contains(where: { $0[0] == L("本体更新", "System update") }) { rep.badges.append(Badge(text: L("本体更新を含む", "Includes system update"), tone: .info)) }
            if !prows.isEmpty {
                sections.append(ReportSection(id: "partitions", title: L("パーティション", "Partitions"), symbol: "square.split.2x1",
                    blocks: [.table(TableData(columns: [L("種類", "Kind"), L("位置", "Offset"), L("タイトル ID", "Title ID")], rows: prows)),
                             .note(L("Wii のゲーム本体は暗号化されているので、中のファイルやバナー画像は読んでいません。", "Wii game data is encrypted, so the files and the banner image inside are not read."))],
                    count: prows.count))
            }
        } else if let b = gcBanner(read) {
            rep.icon = b.icon
            sum.append(contentsOf: b.rows)
        }
        sum.add(L("サイズ", "Size"), byteSizeExact(size))
        rep.summary = sum
        rep.sections = sections
        rep.badges.insert(Badge(text: name, tone: .info), at: 0)
        return rep
    }

    static func wbfs(_ url: URL, _ r: Reader, _ opts: AnalyzeOptions) -> Report? {
        let hdShift = Int(r.u8(8)), wbfsShift = Int(r.u8(9))
        guard hdShift >= 9, hdShift <= 12, wbfsShift >= 15, wbfsShift <= 30 else { return nil }
        let discHeader = 1 << hdShift     // the first disc's header follows the WBFS header sector
        let table = discHeader + 0x100    // big-endian u16 per WBFS block: where that block of the disc is stored
        let read: DiscRead = { off, len in
            var out = Data()
            var o = off
            while out.count < len {
                let block = o >> wbfsShift, inBlock = o & ((1 << wbfsShift) - 1)
                let n = Swift.min(len - out.count, (1 << wbfsShift) - inBlock)
                let phys = Int(r.be16(table + block * 2))
                if phys == 0 { out.append(Data(count: n)) } else { out.append(r.bytes(phys << wbfsShift + inBlock, n)) }
                o += n
            }
            return out
        }
        guard Reader(read(0, 0x20), little: false).u32(0x18) == 0x5d1c_9ea3 else { return nil }
        return disc(url, size: r.count, container: "WBFS", opts: opts, read)
    }

    // MARK: Nintendo 3DS

    static func ciaSMDH(_ r: Reader) -> Int? {
        func align(_ x: Int) -> Int { (x + 63) & ~63 }
        let meta = Int(r.u32(0x14))
        guard meta >= 0x3ac0 else { return nil }
        let content = Int(clamping: r.u64(0x18))
        let o = align(align(align(align(0x2020) + Int(r.u32(8))) + Int(r.u32(12))) + Int(r.u32(16))) + align(content) + 0x400
        return r.ok(o, 0x36c0) && r.fixedStr(o, 4) == "SMDH" ? o : nil
    }

    /// 48×48 RGB565 icon, stored as 8×8 tiles in Z-order.
    static func smdhIcon(_ r: Reader, _ o: Int) -> CGImage? {
        guard r.ok(o, 0x36c0), r.fixedStr(o, 4) == "SMDH" else { return nil }
        func morton(_ x: Int, _ y: Int) -> Int {
            var m = 0
            for i in 0..<3 { m |= ((x >> i) & 1) << (2 * i) | ((y >> i) & 1) << (2 * i + 1) }
            return m
        }
        return image(width: 48, height: 48, scale: 6) { x, y in
            let tile = (y / 8) * 6 + x / 8
            let c = r.u16(o + 0x24c0 + (tile * 64 + morton(x % 8, y % 8)) * 2)
            return (UInt8((c >> 11) * 255 / 31), UInt8(((c >> 5) & 63) * 255 / 63), UInt8((c & 31) * 255 / 31), 255)
        }
    }

    static func smdhTitles(_ r: Reader, _ o: Int) -> [(String, String, String)] {
        let langs = [L("日本語", "Japanese"), L("英語", "English"), L("フランス語", "French"), L("ドイツ語", "German"), L("イタリア語", "Italian"), L("スペイン語", "Spanish"),
                     L("中国語（簡体）", "Chinese (Simplified)"), L("韓国語", "Korean"), L("オランダ語", "Dutch"), L("ポルトガル語", "Portuguese"), L("ロシア語", "Russian"), L("中国語（繁体）", "Chinese (Traditional)")]
        var out = [(String, String, String)]()
        for (i, lang) in langs.enumerated() {
            let b = o + 8 + i * 0x200
            func s(_ off: Int, _ units: Int) -> String {
                var t = r.utf16(b + off, units: units)
                if let z = t.firstIndex(of: "\0") { t = String(t[..<z]) }
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let long = s(0x80, 0x80)
            if !long.isEmpty || !s(0, 0x40).isEmpty { out.append((lang, long.isEmpty ? s(0, 0x40) : long, s(0x180, 0x40))) }
        }
        return out
    }

    /// Where the sections of a CIA sit, and how the first content is stored.
    static func ciaLayout(_ r: Reader) -> (tmdBody: Int, content: Int, encrypted: Bool, size: Int) {
        func align(_ x: Int) -> Int { (x + 63) & ~63 }
        let tmd = align(0x2020) + align(Int(r.u32(8))) + align(Int(r.u32(12)))
        let content = tmd + align(Int(r.u32(16)))
        var body = tmd + 0x140
        switch r.be32(tmd) { case 0x10000, 0x10003: body = tmd + 0x240; case 0x10002, 0x10005: body = tmd + 0x80; default: break }
        let rec = body + 0x9c4   // content chunk records: after the header (0xC4) and the 64 info records (0x900)
        return (body, content, r.be16(rec + 6) & 1 != 0, Int(clamping: r.be64(rec + 8)))
    }

    /// The first content, when it is stored unencrypted: a DS / DSi ROM (DSiWare) or a 3DS program whose
    /// icon data (SMDH) can be read directly.
    static func ciaInner(_ r: Reader) -> (nds: Reader?, smdh: Int?) {
        let l = ciaLayout(r)
        guard !l.encrypted, r.ok(l.content, 0x200) else { return (nil, nil) }
        if r.u16(l.content + 0x15c) == 0xcf56 {
            return (Reader(r.data[(r.data.startIndex + l.content)...], little: true), nil)
        }
        // 3DS program (NCCH) without encryption: ExeFS → "icon".
        if r.fixedStr(l.content + 0x100, 4) == "NCCH", r.u8(l.content + 0x18f) & 0x04 != 0 {
            let exefs = l.content + Int(r.u32(l.content + 0x1a0)) * 0x200
            for i in 0..<10 where r.fixedStr(exefs + i * 16, 8) == "icon" {
                let o = exefs + 0x200 + Int(r.u32(exefs + i * 16 + 8))
                if r.ok(o, 0x36c0), r.fixedStr(o, 4) == "SMDH" { return (nil, o) }
            }
        }
        return (nil, nil)
    }

    static func titleKind(_ hi: UInt32) -> String {
        switch hi {
        case 0x0004_0000: return L("アプリ / ゲーム", "Application / game")
        case 0x0004_0002: return L("体験版", "Demo")
        case 0x0004_000e: return L("更新データ", "Update")
        case 0x0004_008c: return L("追加コンテンツ (DLC)", "DLC")
        case 0x0004_0010: return L("システムアプリ", "System application")
        case 0x0004_0030: return L("システムアプレット", "System applet")
        case 0x0004_8004: return L("DSiWare", "DSiWare")
        case 0x0004_8005, 0x0004_800f, 0x0004_8015: return L("DSi システムタイトル", "DSi system title")
        default: return String(format: "%08X", hi)
        }
    }

    static func cia(_ url: URL, _ r: Reader) -> Report {
        let l = ciaLayout(r)
        let tb = l.tmdBody
        let metaSize = Int(r.u32(0x14))
        let hi = r.be32(tb + 0x4c), lo = r.be32(tb + 0x50)
        let version = Int(r.be16(tb + 0x9c)), contents = Int(r.be16(tb + 0x9e))
        // Icon and titles: the CIA's own meta section if present, else whatever the unencrypted content carries.
        let inner = ciaInner(r)
        let smdh = ciaSMDH(r) ?? inner.smdh
        let nds = inner.nds.flatMap { ndsBanner($0) }
        var titles = smdh.map { smdhTitles(r, $0) } ?? []
        if titles.isEmpty, let nds { titles = nds.titles.map { ($0.0, $0.1, "") } }
        let pick = titles.first { $0.0 == L("日本語", "Japanese") } ?? titles.first
        let titleLines = (pick?.1 ?? "").components(separatedBy: "\n")
        var rep = base(url, nds != nil && titleLines.count > 1 ? titleLines.dropLast().joined(separator: " ") : titleLines.joined(separator: " "),
                       L("ニンテンドー 3DS のインストール用パッケージ (CIA)", "Nintendo 3DS installable package (CIA)"))
        rep.icon = smdh.flatMap { smdhIcon(r, $0) } ?? nds?.icon
        if smdh == nil, let nds { rep.iconFrames = nds.frames }
        if !rep.iconFrames.isEmpty { rep.badges.append(Badge(text: L("アニメーションアイコン", "Animated icon"), tone: .neutral)) }
        rep.badges.append(Badge(text: titleKind(hi), tone: .info))
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("3DS のインストール用パッケージ (CIA)", "3DS installable package (CIA)"))
        sum.add(L("タイトル", "Title"), pick?.1)
        sum.add(L("販売元", "Publisher"), pick.flatMap { $0.2.isEmpty ? nil : $0.2 })
        sum.add(L("内容", "Content type"), titleKind(hi))
        sum.add(L("タイトル ID", "Title ID"), String(format: "%08X%08X", hi, lo), mono: true)
        sum.add(L("バージョン", "Version"), "\(version >> 10).\((version >> 4) & 63).\(version & 15) (v\(version))")
        if let n = inner.nds {
            sum.add(L("中身", "Inside"), L("DS / DSi の ROM", "DS / DSi ROM"))
            sum.add(L("内部名", "Internal name"), text(n.bytes(0, 12)), mono: true)
            sum.add(L("ゲームコード", "Game code"), "TWL-" + n.fixedStr(0x0c, 4), mono: true)
            sum.add(L("販売地域", "Region"), n.fixedStr(0x0c, 4).last.flatMap { region($0) })
            sum.add(L("メーカー", "Maker"), maker(n.fixedStr(0x10, 2)))
        }
        sum.add(L("コンテンツ数", "Contents"), "\(contents)")
        sum.add(L("中身の暗号化", "Content encryption"), l.encrypted ? L("あり（アイコンやタイトルは読めません）", "Encrypted (icon and titles cannot be read)") : L("なし", "None"))
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        _ = metaSize
        rep.summary = sum
        if titles.count > 1 {
            rep.sections.append(ReportSection(id: "titles", title: L("各言語のタイトル", "Titles by Language"), symbol: "globe",
                blocks: [.table(TableData(columns: [L("言語", "Language"), L("タイトル", "Title"), L("販売元", "Publisher")], rows: titles.map { [$0.0, $0.1.replacingOccurrences(of: "\n", with: " / "), $0.2] }))], count: titles.count))
        }
        var rows = [[String]]()
        for i in 0..<Swift.min(contents, 64) {
            let e = tb + 0x9c4 + i * 0x30
            let type = r.be16(e + 6)
            rows.append([String(format: "%08X", r.be32(e)), "\(r.be16(e + 4))", byteSize(Int(clamping: r.be64(e + 8))), type & 1 != 0 ? L("暗号化", "Encrypted") : L("平文", "Plain")])
        }
        if !rows.isEmpty {
            rep.sections.append(ReportSection(id: "contents", title: L("コンテンツ", "Contents"), symbol: "tray.full",
                blocks: [.table(TableData(columns: ["ID", L("番号", "Index"), L("サイズ", "Size"), L("状態", "State")], rows: rows))], count: rows.count))
        }
        return rep
    }

    static func threeDSX(_ url: URL, _ r: Reader) -> Report {
        let hsize = Int(r.u16(4))
        let smdh = hsize > 32 ? Int(r.u32(32)) : 0
        let titles = smdh > 0 ? smdhTitles(r, smdh) : []
        let pick = titles.first { $0.0 == L("英語", "English") } ?? titles.first
        var rep = base(url, pick?.1.replacingOccurrences(of: "\n", with: " ") ?? "", L("ニンテンドー 3DS の自作ソフト (3DSX)", "Nintendo 3DS homebrew (3DSX)"))
        rep.icon = smdh > 0 ? smdhIcon(r, smdh) : nil
        var sum = [Row]()
        sum.add(L("種類", "Kind"), L("3DS の自作ソフト (3DSX)", "3DS homebrew (3DSX)"))
        sum.add(L("タイトル", "Title"), pick?.1)
        sum.add(L("作者", "Author"), pick?.2)
        sum.add(L("コード", "Code"), byteSize(Int(r.u32(16))))
        sum.add(L("読み取り専用データ", "Read-only data"), byteSize(Int(r.u32(20))))
        sum.add(L("データ", "Data"), byteSize(Int(r.u32(24))))
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        return rep
    }

    // MARK: PlayStation

    static func psRegion(_ id: String) -> String? {
        let p = id.prefix(4).uppercased()
        if ["SLPS", "SLPM", "SCPS", "SCPM", "SLKA", "SCKA", "PAPX", "ULJM", "ULJS", "UCJS", "NPJH", "NPJG", "UCAS", "ULAS"].contains(p) { return p.hasSuffix("AS") || p.hasSuffix("KA") ? L("アジア", "Asia") : L("日本", "Japan") }
        if ["SLUS", "SCUS", "ULUS", "UCUS", "NPUH", "NPUG"].contains(p) { return L("北米", "North America") }
        if ["SLES", "SCES", "SCED", "ULES", "UCES", "NPEH", "NPEG"].contains(p) { return L("欧州", "Europe") }
        if ["ULKS", "UCKS"].contains(p) { return L("韓国", "Korea") }
        return nil
    }

    static func sfoRows(_ sfo: [String: String]) -> [Row] {
        var rows = [Row]()
        rows.add(L("タイトル", "Title"), sfo["TITLE"]?.replacingOccurrences(of: "\n", with: " "))
        let id = sfo["DISC_ID"] ?? sfo["TITLE_ID"]
        rows.add(L("ゲーム ID", "Game ID"), id, mono: true)
        rows.add(L("販売地域", "Region"), id.flatMap { psRegion($0) })
        rows.add(L("バージョン", "Version"), sfo["DISC_VERSION"] ?? sfo["APP_VER"] ?? sfo["VERSION"])
        rows.add(L("必要なシステムソフトウェア", "Required firmware"), sfo["PSP_SYSTEM_VER"] ?? sfo["PS3_SYSTEM_VER"] ?? sfo["PSP2_DISP_VER"])
        let cats = ["UG": L("UMD ゲーム", "UMD game"), "EG": L("ダウンロード版ゲーム", "Downloadable game"), "MG": L("メモリースティック用ゲーム", "Memory Stick game"), "ME": L("PS1 クラシック", "PS1 classic"),
                    "UV": L("UMD ビデオ", "UMD video"), "DG": L("ディスクゲーム", "Disc game"), "HG": L("HDD ゲーム", "HDD game"), "gd": L("ゲーム", "Game"), "gp": L("更新データ", "Patch")]
        rows.add(L("カテゴリ", "Category"), sfo["CATEGORY"].map { cats[$0] ?? $0 })
        rows.add(L("対象年齢レベル", "Parental level"), sfo["PARENTAL_LEVEL"])
        return rows
    }

    static func sfoSection(_ sfo: [String: String]) -> ReportSection {
        ReportSection(id: "sfo", title: "PARAM.SFO", symbol: "doc.text",
                      blocks: [.table(TableData(columns: [L("キー", "Key"), L("値", "Value")], rows: sfo.keys.sorted().map { [$0, sfo[$0]!.replacingOccurrences(of: "\n", with: " ")] }))], count: sfo.count)
    }

    /// PBP: header with eight offsets (PARAM.SFO, ICON0.PNG, ICON1, PIC0, PIC1, SND0, DATA.PSP, DATA.PSAR).
    static func pbpParts(_ r: Reader) -> (sfo: Data?, icon: Data?, parts: [[String]]) {
        let names = ["PARAM.SFO", "ICON0.PNG", "ICON1.PMF", "PIC0.PNG", "PIC1.PNG", "SND0.AT3", "DATA.PSP", "DATA.PSAR"]
        var offs = (0..<8).map { Int(r.u32(8 + $0 * 4)) }
        offs.append(r.count)
        var parts = [[String]]()
        var sfo: Data?, icon: Data?
        for i in 0..<8 where offs[i + 1] > offs[i] {
            let len = offs[i + 1] - offs[i]
            parts.append([names[i], byteSize(len)])
            if i == 0, len < 1 << 20 { sfo = r.bytes(offs[i], len) }
            if i == 1, len < 4 << 20 { icon = r.bytes(offs[i], len) }
        }
        return (sfo, icon, parts)
    }

    static func pbp(_ url: URL, _ r: Reader) -> Report {
        let p = pbpParts(r)
        let sfo = p.sfo.map(SFO.parse) ?? [:]
        var rep = base(url, sfo["TITLE"]?.replacingOccurrences(of: "\n", with: " ") ?? "", L("PSP のパッケージ (PBP)", "PSP package (PBP)"))
        rep.icon = p.icon.flatMap { ImageKit.decode($0) }
        var sum = [Row(L("種類", "Kind"), L("PSP のパッケージ (EBOOT.PBP)", "PSP package (EBOOT.PBP)"))]
        sum.append(contentsOf: sfoRows(sfo))
        sum.add(L("サイズ", "Size"), byteSizeExact(r.count))
        rep.summary = sum
        rep.sections = [ReportSection(id: "parts", title: L("中身", "Contents"), symbol: "tray.full", blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: p.parts))], count: p.parts.count)]
        if !sfo.isEmpty { rep.sections.append(sfoSection(sfo)) }
        return rep
    }

    // MARK: ISO images (PlayStation discs and ordinary data discs)

    static func isoReport(_ url: URL, _ iso: ISO9660, data: Data, size: Int, opts: AnalyzeOptions) -> Report {
        let fs = DiscFS(data: data, iso: iso)
        let root = fs.list()
        // The primary volume name is ASCII only; a Japanese name survives only in the Joliet descriptor.
        var volume = iso.field(40, 32)
        if !iso.jolietVolume.isEmpty, volume.isEmpty || volume.allSatisfy({ $0 == "_" }) { volume = iso.jolietVolume }
        var rep = base(url, volume, L("光ディスクイメージ (ISO 9660)", "Optical disc image (ISO 9660)"), kind: .disc)
        var sum = [Row]()
        var extra = [ReportSection]()
        var kind = L("光ディスクイメージ", "Optical disc image")

        if let e = iso.find("PSP_GAME/PARAM.SFO"), let d = iso.read(e) {
            let sfo = SFO.parse(d)
            kind = L("PSP のディスクイメージ (UMD)", "PSP disc image (UMD)")
            rep.title = sfo["TITLE"]?.replacingOccurrences(of: "\n", with: " ") ?? volume
            rep.badges.append(Badge(text: "PSP", tone: .info))
            if let i = iso.find("PSP_GAME/ICON0.PNG"), let png = iso.read(i) { rep.icon = ImageKit.decode(png) }
            sum.append(contentsOf: sfoRows(sfo))
            if !sfo.isEmpty { extra.append(sfoSection(sfo)) }
        } else if let e = iso.find("SYSTEM.CNF"), let d = iso.read(e, max: 1 << 16) {
            let cnf = text(d)
            let ps2 = cnf.uppercased().contains("BOOT2")
            kind = ps2 ? L("PlayStation 2 のディスクイメージ", "PlayStation 2 disc image") : L("PlayStation のディスクイメージ", "PlayStation disc image")
            rep.badges.append(Badge(text: ps2 ? "PS2" : "PS1", tone: .info))
            if let exe = firstMatch(cnf, #"BOOT2?\s*=\s*cdrom0?:\\?([^;\s]+)"#) {
                let id = exe.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "")
                sum.add(L("ゲーム ID", "Game ID"), id, mono: true)
                sum.add(L("販売地域", "Region"), psRegion(id))
                sum.add(L("起動ファイル", "Boot file"), exe, mono: true)
            }
            sum.add(L("バージョン", "Version"), firstMatch(cnf, #"VER\s*=\s*(\S+)"#))
            sum.add(L("映像方式", "Video mode"), firstMatch(cnf, #"VMODE\s*=\s*(\S+)"#))
            extra.append(ReportSection(id: "cnf", title: "SYSTEM.CNF", symbol: "doc.text", blocks: [.text(cnf)]))
        } else if let os = OSInstaller.detect(fs, volume: fs.udf?.volumeName.isEmpty == false ? fs.udf!.volumeName : volume) {
            kind = os.kind
            if let t = os.title, !t.isEmpty { rep.title = t }
            rep.badges.append(contentsOf: os.badges)
            sum.append(contentsOf: os.rows)
            extra.append(contentsOf: os.sections)
        } else if root.contains(where: { $0.name.uppercased() == "PS3_GAME" }) {
            kind = L("PlayStation 3 のディスクイメージ", "PlayStation 3 disc image")
            if let e = iso.find("PS3_GAME/PARAM.SFO"), let d = iso.read(e) {
                let sfo = SFO.parse(d)
                rep.title = sfo["TITLE"]?.replacingOccurrences(of: "\n", with: " ") ?? volume
                sum.append(contentsOf: sfoRows(sfo))
                extra.append(sfoSection(sfo))
            }
            if let i = iso.find("PS3_GAME/ICON0.PNG"), let png = iso.read(i) { rep.icon = ImageKit.decode(png) }
        }
        rep.subtitle = kind + (iso.raw ? L("（CD の生データ）", " (raw CD image)") : "")
        var head = [Row(L("種類", "Kind"), kind)]
        head.append(contentsOf: sum)
        // Windows discs: what starts on insert, and the disc's own icon.
        if let auto = Autorun.inspect(fs) {
            head.append(contentsOf: auto.rows.filter { $0.key != L("右クリックメニューの項目", "Context menu items") })
            extra.append(auto.section)
            if rep.icon == nil { rep.icon = auto.icon }
        }
        // Mac discs: the volume's custom icon.
        if rep.icon == nil, let n = fs.size(".VolumeIcon.icns"), n > 0, n < 8 << 20, let d = fs.read(".VolumeIcon.icns", length: n) { rep.icon = ImageKit.decode(d) }
        head.add(L("ボリューム名", "Volume name"), volume, mono: true)
        head.add(L("システム", "System"), iso.field(8, 32))
        head.add(L("発行者", "Publisher"), iso.field(318, 128))
        head.add(L("作成ソフト", "Application"), iso.field(574, 128))
        head.add(L("作成日時", "Created"), iso.date(813))
        head.add(L("起動方式", "Boot"), iso.bootable ? (iso.bootPlatforms.isEmpty ? L("起動可能", "Bootable") : iso.bootPlatforms.joined(separator: " + ")) : nil)
        head.add(L("ファイルシステム", "File system"), "ISO 9660" + (iso.hasUDF ? " + UDF" : ""))
        head.add(L("セクター形式", "Sector format"), iso.raw ? L("2352 バイト（生データ）", "2352 bytes (raw)") : nil)
        head.add(L("サイズ", "Size"), byteSizeExact(size))
        rep.summary = head
        rep.sections = extra
        if !root.isEmpty {
            rep.sections.append(ReportSection(id: "root", title: L("最上位のファイル", "Top-level Files"), symbol: "folder",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("サイズ", "Size")], rows: root.map { [$0.name + ($0.isDir ? "/" : ""), $0.isDir ? "" : byteSize($0.size)] }))],
                count: root.count))
        }
        return rep
    }
}
