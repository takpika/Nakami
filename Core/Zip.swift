import Foundation
import Compression

/// Read-only ZIP access over a memory-mapped file (stored and deflated entries, ZIP64 offsets).
/// The same interface can also sit on top of a plain folder (`init(directory:)`), so a package's
/// contents are analysed the same way whether they are zipped or not.
struct Zip {
    struct Entry { var name: String; var method: UInt16; var compSize: Int; var size: Int; var headerOffset: Int }

    let r: Reader
    var entries: [Entry] = []
    var cdOffset = 0
    private var index: [String: Int] = [:]
    /// Set when the entries are real files under this folder instead of ZIP members.
    var directory: URL?
    /// Set when the entries come from somewhere else entirely (e.g. an app inside a disk image): reads go through this.
    var provider: ((Entry) -> Data?)?
    /// How the container should be called in reports (".app", "dmg" …) when it is not a ZIP file.
    var containerLabel: String?

    /// A listing backed by a custom source. `headerOffset` of each entry is free for the source's own use.
    init(entries: [Entry], label: String, provider: @escaping (Entry) -> Data?) {
        r = Reader(Data())
        self.entries = entries
        self.provider = provider
        containerLabel = label
        for (i, e) in entries.enumerated() { index[e.name] = i }
    }

    /// Lists a folder as if it were an archive whose top-level item is the folder itself ("Foo.app/…").
    init?(directory url: URL, limit: Int = 200_000) {
        r = Reader(Data())
        directory = url.deletingLastPathComponent()
        containerLabel = ".app"
        let root = url.lastPathComponent
        let base = url.resolvingSymlinksInPath().path
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return nil }
        for case let u as URL in en {
            guard entries.count < limit else { break }
            guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { continue }
            let full = u.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let name = root + "/" + String(full.dropFirst(base.count + 1))
            index[name] = entries.count
            entries.append(Entry(name: name, method: 0, compSize: v.fileSize ?? 0, size: v.fileSize ?? 0, headerOffset: 0))
        }
        guard !entries.isEmpty else { return nil }
    }

    static func isZip(_ r: Reader) -> Bool { r.le32(0) == 0x0403_4b50 }

    init?(_ data: Data) {
        r = Reader(data, little: true)
        let n = data.count
        guard n >= 22 else { return nil }
        var eocd = -1
        var i = n - 22
        let stop = Swift.max(0, n - 22 - 65535)
        while i >= stop {
            if r.u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        var count = Int(r.u16(eocd + 10))
        cdOffset = Int(r.u32(eocd + 16))
        if eocd >= 20, r.u32(eocd - 20) == 0x0706_4b50 {  // ZIP64 locator
            let e64 = Int(clamping: r.u64(eocd - 12))
            if r.u32(e64) == 0x0606_4b50 {
                count = Int(clamping: r.u64(e64 + 32))
                cdOffset = Int(clamping: r.u64(e64 + 48))
            }
        }
        var p = cdOffset
        entries.reserveCapacity(Swift.min(count, 200_000))
        for _ in 0..<Swift.min(count, 500_000) {
            guard r.ok(p, 46), r.u32(p) == 0x0201_4b50 else { break }
            let nameLen = Int(r.u16(p + 28)), extraLen = Int(r.u16(p + 30)), commentLen = Int(r.u16(p + 32))
            var e = Entry(name: Reader.decode(r.bytes(p + 46, nameLen)), method: r.u16(p + 10),
                          compSize: Int(r.u32(p + 20)), size: Int(r.u32(p + 24)), headerOffset: Int(r.u32(p + 42)))
            if e.compSize == 0xffff_ffff || e.size == 0xffff_ffff || e.headerOffset == 0xffff_ffff {
                var x = p + 46 + nameLen
                let xe = x + extraLen
                while x + 4 <= xe {
                    let id = r.u16(x), sz = Int(r.u16(x + 2))
                    if id == 1 {
                        var q = x + 4
                        if e.size == 0xffff_ffff { e.size = Int(clamping: r.u64(q)); q += 8 }
                        if e.compSize == 0xffff_ffff { e.compSize = Int(clamping: r.u64(q)); q += 8 }
                        if e.headerOffset == 0xffff_ffff { e.headerOffset = Int(clamping: r.u64(q)) }
                    }
                    x += 4 + sz
                }
            }
            index[e.name] = entries.count
            entries.append(e)
            p += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { return nil }
    }

    func entry(_ name: String) -> Entry? { index[name].map { entries[$0] } }

    func read(_ name: String, max: Int = 64 << 20) -> Data? { entry(name).flatMap { read($0, max: max) } }

    func read(_ e: Entry, max: Int = 64 << 20) -> Data? {
        if let provider { return e.size <= max ? provider(e) : nil }
        if let directory {
            guard e.size <= max else { return nil }
            return try? Data(contentsOf: directory.appendingPathComponent(e.name), options: .alwaysMapped)
        }
        let h = e.headerOffset
        guard r.ok(h, 30), r.u32(h) == 0x0403_4b50, e.size <= max else { return nil }
        let start = h + 30 + Int(r.u16(h + 26)) + Int(r.u16(h + 28))
        guard r.ok(start, e.compSize) else { return nil }
        if e.method == 0 { return r.bytes(start, Swift.min(e.compSize, e.size)) }
        guard e.method == 8, e.size > 0 else { return e.size == 0 ? Data() : nil }
        var out = Data(count: e.size)
        let n: Int = out.withUnsafeMutableBytes { dst in
            r.data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                          src.bindMemory(to: UInt8.self).baseAddress! + start, e.compSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        if n < e.size { out.removeSubrange(n...) }
        return out
    }

    var totalUncompressed: Int { entries.reduce(0) { $0 + $1.size } }
}
