import Foundation
import CoreGraphics

/// Minimal Protocol Buffers reader: walks the fields of a message in place.
struct ProtoBuf {
    let b: [UInt8]
    init(_ d: Data) { b = [UInt8](d) }

    /// Calls `visit(field number, wire type, varint value, start, end)` for each field in `lo ..< hi`.
    /// For length-delimited fields (wire type 2) start/end bound the payload.
    func each(_ lo: Int, _ hi: Int, _ visit: (Int, Int, UInt64, Int, Int) -> Void) {
        var p = lo
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while p < hi, shift < 64 {
                let c = b[p]; p += 1
                v |= UInt64(c & 0x7f) << shift
                if c & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while p < hi {
            guard let key = varint() else { return }
            let num = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: guard let v = varint() else { return }; visit(num, 0, v, p, p)
            case 1: guard p + 8 <= hi else { return }; var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[p + i]) << UInt64(8 * i) }; visit(num, 1, v, p, p + 8); p += 8
            case 2:
                guard let len = varint(), len <= UInt64(hi - p) else { return }
                visit(num, 2, 0, p, p + Int(len)); p += Int(len)
            case 5: guard p + 4 <= hi else { return }; var v: UInt64 = 0; for i in 0..<4 { v |= UInt64(b[p + i]) << UInt64(8 * i) }; visit(num, 5, v, p, p + 4); p += 4
            default: return
            }
        }
    }

    func string(_ lo: Int, _ hi: Int) -> String { String(decoding: b[lo..<hi], as: UTF8.self) }

    /// First field `num` of the message: its payload range (wire type 2) or value.
    func first(_ lo: Int, _ hi: Int, _ num: Int) -> (value: UInt64, lo: Int, hi: Int)? {
        var out: (UInt64, Int, Int)?
        each(lo, hi) { n, _, v, a, e in if n == num, out == nil { out = (v, a, e) } }
        return out
    }
    func str(_ lo: Int, _ hi: Int, _ num: Int) -> String? { first(lo, hi, num).map { string($0.lo, $0.hi) } }
}

extension AXML {
    /// The protobuf form of compiled XML used inside app bundles (aapt2's XmlNode), flattened the same way.
    init?(proto data: Data) {
        let pb = ProtoBuf(data)
        guard !pb.b.isEmpty, pb.b[0] == 0x0a else { return nil }
        var out = [Element]()
        func item(_ lo: Int, _ hi: Int, _ text: String) -> Value {
            var v = Value(type: 3, data: 0, string: text)
            pb.each(lo, hi) { n, _, _, a, e in
                switch n {
                case 1: if let id = pb.first(a, e, 2) { v = Value(type: 1, data: UInt32(truncatingIfNeeded: id.value), string: text) }
                case 7:
                    pb.each(a, e) { pn, _, pv, _, _ in
                        switch pn {
                        case 6, 7: v = Value(type: pn == 6 ? 0x10 : 0x11, data: UInt32(truncatingIfNeeded: pv), string: text)
                        case 8: v = Value(type: 0x12, data: pv != 0 ? 0xffff_ffff : 0, string: text)
                        case 9, 10, 11, 12: v = Value(type: 0x1c, data: UInt32(truncatingIfNeeded: pv), string: text)
                        default: break
                        }
                    }
                default: break
                }
            }
            return v
        }
        func node(_ lo: Int, _ hi: Int, _ depth: Int) {
            guard depth < 64, out.count < 20000, let el = pb.first(lo, hi, 1) else { return }
            var name = "", attrs = [String: Value](), children = [(Int, Int)]()
            pb.each(el.lo, el.hi) { n, _, _, a, e in
                switch n {
                case 3: name = pb.string(a, e)
                case 4:
                    var an = "", text = "", resID: UInt32 = 0, compiled: (Int, Int)?
                    pb.each(a, e) { fn, _, fv, fa, fe in
                        switch fn {
                        case 2: an = pb.string(fa, fe)
                        case 3: text = pb.string(fa, fe)
                        case 5: resID = UInt32(truncatingIfNeeded: fv)
                        case 6: compiled = (fa, fe)
                        default: break
                        }
                    }
                    if an.isEmpty, let known = AXML.attrIDs[resID] { an = known }
                    attrs[an] = compiled.map { item($0.0, $0.1, text) } ?? Value(type: 3, data: 0, string: text)
                case 5: children.append((a, e))
                default: break
                }
            }
            out.append(Element(name: name, depth: depth, attrs: attrs))
            for c in children { node(c.0, c.1, depth + 1) }
        }
        node(0, pb.b.count, 0)
        guard !out.isEmpty else { return nil }
        elements = out
    }
}

extension ARSC {
    /// The protobuf resource table of an app bundle (resources.pb), indexed by resource ID.
    static func protoTable(_ data: Data) -> [UInt32: [Hit]]? {
        let pb = ProtoBuf(data)
        guard pb.b.count > 2 else { return nil }
        var table = [UInt32: [Hit]]()
        let densities = ["ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240, "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640, "anydpi": 0xfffe, "nodpi": 0xffff]
        pb.each(0, pb.b.count) { n, w, _, pa, pe in
            guard n == 2, w == 2 else { return }
            let pkg = pb.first(pa, pe, 1).flatMap { pb.first($0.lo, $0.hi, 1)?.value } ?? 0x7f
            pb.each(pa, pe) { tn, tw, _, ta, te in
                guard tn == 3, tw == 2 else { return }
                let type = pb.first(ta, te, 1).flatMap { pb.first($0.lo, $0.hi, 1)?.value } ?? 0
                pb.each(ta, te) { en, ew, _, ea, ee in
                    guard en == 3, ew == 2, table.count < 400_000 else { return }
                    let entry = pb.first(ea, ee, 1).flatMap { pb.first($0.lo, $0.hi, 1)?.value } ?? 0
                    let id = UInt32(truncatingIfNeeded: pkg << 24 | (type & 0xff) << 16 | (entry & 0xffff))
                    var hits = [Hit]()
                    pb.each(ea, ee) { cn, cw, _, ca, ce in
                        guard cn == 6, cw == 2, hits.count < 64 else { return }
                        var language = "", density = 0
                        if let cfg = pb.first(ca, ce, 1) {
                            pb.each(cfg.lo, cfg.hi) { fn, _, fv, fa, fe in
                                if fn == 3 { language = String(pb.string(fa, fe).prefix(2)) }
                                if fn == 18 { density = Int(fv) }
                            }
                        }
                        guard let value = pb.first(ca, ce, 2), let it = pb.first(value.lo, value.hi, 4) else { return }
                        pb.each(it.lo, it.hi) { vn, _, _, va, ve in
                            switch vn {
                            case 1: if let ref = pb.first(va, ve, 2) { hits.append(Hit(language: language, density: density, type: 1, data: UInt32(truncatingIfNeeded: ref.value), string: nil)) }
                            case 2, 3, 4: hits.append(Hit(language: language, density: density, type: 3, data: 0, string: pb.str(va, ve, 1) ?? ""))
                            case 5:
                                let path = pb.str(va, ve, 1) ?? ""
                                var d = density
                                if d == 0, let q = firstMatch(path, #"-(ldpi|mdpi|tvdpi|hdpi|xhdpi|xxhdpi|xxxhdpi|anydpi|nodpi)"#) { d = densities[q] ?? 0 }
                                hits.append(Hit(language: language, density: d, type: 3, data: 0, string: path))
                            case 7:
                                pb.each(va, ve) { pn, _, pv, _, _ in
                                    switch pn {
                                    case 6, 7: hits.append(Hit(language: language, density: density, type: 0x10, data: UInt32(truncatingIfNeeded: pv), string: nil))
                                    case 8: hits.append(Hit(language: language, density: density, type: 0x12, data: pv != 0 ? 0xffff_ffff : 0, string: nil))
                                    case 9, 10, 11, 12: hits.append(Hit(language: language, density: density, type: 0x1c, data: UInt32(truncatingIfNeeded: pv), string: nil))
                                    case 13: hits.append(Hit(language: language, density: density, type: 0x05, data: UInt32(truncatingIfNeeded: pv), string: nil))
                                    default: break
                                    }
                                }
                            default: break
                            }
                        }
                    }
                    if !hits.isEmpty { table[id] = hits }
                }
            }
        }
        return table.isEmpty ? nil : table
    }
}

/// Android App Bundle (.aab): what developers upload to Google Play. The store builds the installable
/// apk files from it, so it holds every module, CPU and screen variant at once.
enum AAB {
    static func isAAB(_ zip: Zip) -> Bool { zip.entry("base/manifest/AndroidManifest.xml") != nil }

    /// The base module seen as if it were an apk: "base/res/…" → "res/…", "base/dex/classes.dex" → "classes.dex".
    static func baseView(_ zip: Zip) -> Zip {
        var entries = [Zip.Entry]()
        var originals = [String]()
        for e in zip.entries {
            var name: String?
            if e.name.hasPrefix("base/dex/") { name = String(e.name.dropFirst(9)) }
            else if e.name.hasPrefix("base/root/") { name = String(e.name.dropFirst(10)) }
            else if e.name.hasPrefix("base/") { name = String(e.name.dropFirst(5)) }
            else if e.name.hasPrefix("META-INF/") { name = e.name }
            guard let n = name, !n.isEmpty else { continue }
            var c = e
            c.name = n
            c.headerOffset = originals.count
            originals.append(e.name)
            entries.append(c)
        }
        return Zip(entries: entries, label: "aab") { e in zip.read(originals[e.headerOffset], max: 512 << 20) }
    }

    static func icon(_ zip: Zip) -> CGImage? {
        guard isAAB(zip) else { return nil }
        return APK.icon(baseView(zip))
    }

    static func report(url: URL, zip: Zip, fileSize: Int, opts: AnalyzeOptions) -> Report {
        var rep = APK.report(url: url, zip: baseView(zip), fileSize: fileSize, opts: opts)
        let kind = L("Android App Bundle (aab)", "Android App Bundle (aab)")
        rep.subtitle = kind
        rep.summary.removeAll { $0.key == L("種類", "Kind") || $0.key == L("サイズ", "Size") }
        rep.summary.insert(Row(L("種類", "Kind"), kind), at: 0)
        rep.summary.insert(Row(L("用途", "Purpose"), L("Google Play へ提出する形式（端末に入れる apk はストア側がここから作ります）", "The format uploaded to Google Play (the store builds the installable apks from it)")), at: 1)
        // Modules: the base, plus features delivered on demand or at install time.
        var modules = [String: (files: Int, size: Int)]()
        for e in zip.entries {
            let parts = e.name.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, parts[0] != "META-INF", parts[0] != "BUNDLE-METADATA" else { continue }
            var cur = modules[String(parts[0])] ?? (0, 0)
            cur.files += 1; cur.size += e.size
            modules[String(parts[0])] = cur
        }
        var rows = [[String]]()
        for (name, m) in modules.sorted(by: { $0.key == "base" ? true : $1.key == "base" ? false : $0.key < $1.key }) {
            var delivery = name == "base" ? L("本体（必ず入る）", "Base (always installed)") : ""
            if name != "base", let d = zip.read("\(name)/manifest/AndroidManifest.xml", max: 4 << 20), let x = AXML(proto: d) {
                let names = Set(x.elements.map { $0.name })
                if names.contains("on-demand") { delivery = L("必要になったときに追加", "On demand") }
                else if names.contains("install-time") { delivery = L("インストール時に一緒に入る", "At install time") }
                else if let m = x.elements.first(where: { $0.name == "module" }), m.attrs["onDemand"]?.string == "true" { delivery = L("必要になったときに追加", "On demand") }
                if names.contains("conditions") { delivery += L("（端末の条件つき）", " (conditional)") }
                if x.elements.first(where: { $0.name == "module" })?.attrs["instant"]?.string == "true" { delivery += L("（Instant App 対応）", " (instant)") }
                if delivery.isEmpty { delivery = L("追加の機能", "Feature module") }
            }
            let abis = Set(zip.entries.compactMap { e -> String? in e.name.hasPrefix(name + "/lib/") ? e.name.split(separator: "/").dropFirst(2).first.map(String.init) : nil }).sorted()
            rows.append([name, delivery, abis.joined(separator: ", "), "\(m.files)", byteSize(m.size)])
        }
        rep.summary.add(L("モジュール", "Modules"), "\(modules.count)" + L(" 個", "") + (modules.count > 1 ? L("（\(modules.keys.filter { $0 != "base" }.sorted().prefix(6).joined(separator: ", "))）", " (\(modules.keys.filter { $0 != "base" }.sorted().prefix(6).joined(separator: ", ")))") : ""))
        if let d = zip.read("BundleConfig.pb", max: 4 << 20) {
            let pb = ProtoBuf(d)
            if let bt = pb.first(0, pb.b.count, 1) { rep.summary.add(L("作成した bundletool", "Built with bundletool"), pb.str(bt.lo, bt.hi, 2)) }
        }
        let meta = zip.entries.filter { $0.name.hasPrefix("BUNDLE-METADATA/") }
        if meta.contains(where: { $0.name.contains("proguard.map") || $0.name.contains("obfuscation") }) { rep.summary.add(L("難読化の対応表", "Obfuscation map"), L("同梱されています", "Included")) }
        if meta.contains(where: { $0.name.contains("debugsymbols") }) { rep.summary.add(L("ネイティブのデバッグ情報", "Native debug symbols"), L("同梱されています", "Included")) }
        rep.summary.add(L("サイズ", "Size"), byteSizeExact(fileSize))
        rep.sections.insert(ReportSection(id: "modules", title: L("モジュール", "Modules"), symbol: "square.stack.3d.up",
            blocks: [.table(TableData(columns: [L("名前", "Name"), L("届け方", "Delivery"), L("CPU", "ABIs"), L("ファイル数", "Files"), L("サイズ", "Size")], rows: rows))], count: rows.count), at: 0)
        // The file list should show the bundle as it is, not the remapped view.
        rep.sections.removeAll { $0.id == "files" }
        rep.sections.append(IPA.largestFiles(zip, strip: "", deep: opts.deep))
        return rep
    }
}
