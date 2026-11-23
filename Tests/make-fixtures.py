#!/usr/bin/env python3
"""Generates the test fixtures. Every file is built here from scratch, so nothing copyrighted is stored
in the repository. Usage: make-fixtures.py <output directory>"""
import gzip, io, os, plistlib, struct, sys, tarfile, zipfile, zlib

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
os.makedirs(out, exist_ok=True)

def write(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)

def zip_bytes(files, store=False):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_STORED if store else zipfile.ZIP_DEFLATED) as z:
        for n, d in files:
            z.writestr(zipfile.ZipInfo(n, (2024, 1, 1, 0, 0, 0)), d)
    return b.getvalue()

def tar_bytes(files):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w", format=tarfile.USTAR_FORMAT) as t:
        for n, d, mode in files:
            i = tarfile.TarInfo(n); i.size = len(d); i.mode = mode; i.mtime = 1704067200
            t.addfile(i, io.BytesIO(d))
    return b.getvalue()

def gz(d):
    b = io.BytesIO()
    with gzip.GzipFile(fileobj=b, mode="wb", mtime=1704067200) as g:
        g.write(d)
    return b.getvalue()

# ---- Java: a runnable jar (class file version 61 = Java 17) and a Minecraft mod
klass = b"\xca\xfe\xba\xbe" + struct.pack(">HH", 0, 61) + b"\x00" * 32
write("hello.jar", zip_bytes([("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\nMain-Class: demo.Hello\r\nImplementation-Title: Hello Demo\r\nImplementation-Version: 1.2.3\r\n\r\n"),
                              ("demo/Hello.class", klass),
                              ("META-INF/maven/org.example/hello/pom.properties", b"groupId=org.example\nartifactId=hello\nversion=1.2.3\n")]))
write("mod.jar", zip_bytes([("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\r\n\r\n"), ("demo/Mod.class", klass),
                            ("mcmod.info", b'[{"modid":"demomod","name":"Demo Mod","version":"0.1","mcversion":"1.7.10","authorList":["someone"]}]')]))

# ---- Apple: an .ipa and a tar.gz holding a Mac app
info = plistlib.dumps({"CFBundleIdentifier": "org.example.demo", "CFBundleName": "Demo", "CFBundleShortVersionString": "2.0", "CFBundleVersion": "20",
                       "CFBundleExecutable": "Demo", "MinimumOSVersion": "15.0", "CFBundlePackageType": "APPL"})
write("demo.ipa", zip_bytes([("Payload/Demo.app/Info.plist", info), ("Payload/Demo.app/Demo", b"\xcf\xfa\xed\xfe" + b"\x00" * 60)]))
write("demo-app.tar.gz", gz(tar_bytes([("Demo.app/Contents/Info.plist", info, 0o644), ("Demo.app/Contents/MacOS/Demo", b"#!/bin/sh\n", 0o755)])))

# ---- zstd: a tar archive wrapped in a frame of "raw" (uncompressed) blocks, which needs no encoder
def zstd_raw(d):
    o = b"\x28\xb5\x2f\xfd" + bytes([0xa0]) + struct.pack("<I", len(d))   # single segment, 4-byte content size
    chunks = [d[i:i + 100000] for i in range(0, len(d), 100000)] or [b""]
    for k, c in enumerate(chunks):
        h = (len(c) << 3) | (1 if k == len(chunks) - 1 else 0)
        o += struct.pack("<I", h)[:3] + c
    return o
write("files.tar.zst", zstd_raw(tar_bytes([("notes/readme.txt", b"hello\n" * 30000, 0o644), ("notes/run.sh", b"#!/bin/sh\necho hi\n", 0o755)])))

# ---- Linux packages
def ar(members):
    o = b"!<arch>\n"
    for n, d in members:
        o += ("%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (n, 0, 0, 0, "100644", len(d))).encode() + d + (b"\n" if len(d) & 1 else b"")
    return o
control = b"Package: hello-demo\nVersion: 1.0-1\nArchitecture: amd64\nMaintainer: Nobody <nobody@example.org>\nInstalled-Size: 12\nDepends: libc6 (>= 2.31)\nSection: utils\nDescription: says hello\n A longer description.\n"
desktop = b"[Desktop Entry]\nType=Application\nName=Hello Demo\nExec=hello-demo\nIcon=hello-demo\nCategories=Utility;\n"
data_tar = tar_bytes([("./usr/bin/hello-demo", b"\x7fELF" + b"\x00" * 60, 0o755), ("./usr/share/applications/hello-demo.desktop", desktop, 0o644),
                      ("./usr/lib/systemd/system/hello-demo.service", b"[Unit]\n", 0o644)])
write("hello-demo.deb", ar([("debian-binary", b"2.0\n"), ("control.tar.gz", gz(tar_bytes([("./control", control, 0o644), ("./postinst", b"#!/bin/sh\nexit 0\n", 0o755)]))),
                            ("data.tar.gz", gz(data_tar))]))

def rpm_header(magic_tail, tags):
    index, store = b"", b""
    for tag, typ, value in tags:
        if typ == 6: data, count = value.encode() + b"\0", 1
        elif typ == 4:
            while len(store) % 4: store += b"\0"
            data, count = b"".join(struct.pack(">I", v) for v in value), len(value)
        elif typ == 8: data, count = b"".join(v.encode() + b"\0" for v in value), len(value)
        elif typ == 3:
            while len(store) % 2: store += b"\0"
            data, count = b"".join(struct.pack(">H", v) for v in value), len(value)
        index += struct.pack(">IIII", tag, typ, len(store), count)
        store += data
    return b"\x8e\xad\xe8\x01" + b"\0" * 4 + struct.pack(">II", len(tags), len(store)) + index + store
lead = b"\xed\xab\xee\xdb\x03\x00\x00\x00\x00\x01" + b"hello-demo-1.0-1".ljust(66, b"\0") + struct.pack(">HH", 1, 5) + b"\0" * 16
sig = rpm_header(None, [(1000, 4, [0])])
sig += b"\0" * ((8 - len(sig) % 8) % 8)
main = rpm_header(None, [(1000, 6, "hello-demo"), (1001, 6, "1.0"), (1002, 6, "1"), (1004, 6, "says hello"), (1014, 6, "MIT"), (1022, 6, "x86_64"),
                         (1044, 6, "hello-demo-1.0-1.src.rpm"), (1117, 8, ["hello-demo"]), (1118, 8, ["/usr/bin/"]), (1116, 4, [0]), (1028, 4, [64]), (1030, 3, [0o100755])])
write("hello-demo.rpm", lead + sig + main + gz(b"0707010000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000b00000000TRAILER!!!\0\0\0\0"))

# ---- Flash: an uncompressed movie, 550 x 400 at 12 fps, one frame
def bits(values, n):
    s = "".join(format(v & ((1 << n) - 1), "0%db" % n) for v in values)
    return s
rect = format(15, "05b") + bits([0, 11000, 0, 8000], 15)
rect += "0" * ((8 - len(rect) % 8) % 8)
rect = int(rect, 2).to_bytes(len(rect) // 8, "big")
def tag(code, body): return struct.pack("<H", (code << 6) | len(body)) + body
body = rect + bytes([0, 12]) + struct.pack("<H", 1) + tag(69, struct.pack("<I", 0x08 | 0x01)) + tag(9, b"\x33\x66\x99") + tag(1, b"") + tag(0, b"")
write("movie.swf", b"FWS" + bytes([10]) + struct.pack("<I", len(body) + 8) + body)
write("movie-cws.swf", b"CWS" + bytes([10]) + struct.pack("<I", len(body) + 8) + zlib.compress(body))

# ---- Classic Mac OS: a resource fork (version 1.2, memory settings, 68K code), wrapped three ways
def resource_fork(resources):
    data, types = b"", {}
    for t, rid, d in resources:
        types.setdefault(t, []).append((rid, len(data)))
        data += struct.pack(">I", len(d)) + d
    type_list = struct.pack(">H", len(types) - 1)
    refs, ref_off = b"", 2 + 8 * len(types)
    for t, items in types.items():
        type_list += t + struct.pack(">HH", len(items) - 1, ref_off + len(refs))
        for rid, off in items:
            refs += struct.pack(">hH", rid, 0xffff) + struct.pack(">I", off) + b"\0" * 4
    m = b"\0" * 22 + struct.pack(">HHH", 0, 28, 28 + len(type_list) + len(refs)) + type_list + refs
    return struct.pack(">IIII", 256, 256 + len(data), len(data), len(m)) + b"\0" * 240 + data + m
vers = bytes([0x01, 0x20, 0x80, 0x00]) + struct.pack(">H", 0) + bytes([3]) + b"1.2" + bytes([13]) + b"1.2, Demo Inc"
rsrc = resource_fork([(b"vers", 1, vers), (b"SIZE", -1, struct.pack(">HII", 0x0080, 512 * 1024, 256 * 1024)), (b"CODE", 0, b"\0" * 32), (b"CODE", 1, b"\0" * 64)])
def crc16(b):
    c = 0
    for x in b:
        c ^= x << 8
        for _ in range(8): c = ((c << 1) ^ 0x1021) & 0xffff if c & 0x8000 else (c << 1) & 0xffff
    return c
def macbinary(name, typ, cre, d, r):
    h = bytearray(128); nb = name.encode("mac_roman"); h[1] = len(nb); h[2:2 + len(nb)] = nb; h[65:69] = typ; h[69:73] = cre
    struct.pack_into(">II", h, 83, len(d), len(r)); struct.pack_into(">II", h, 91, 0xB0000000, 0xB0000100); h[122] = h[123] = 129
    struct.pack_into(">H", h, 124, crc16(h[:124]))
    pad = lambda b: b + b"\0" * ((128 - len(b) % 128) % 128)
    return bytes(h) + pad(d) + pad(r)
def binhex(name, typ, cre, d, r):
    nb = name.encode("mac_roman"); hdr = bytes([len(nb)]) + nb + b"\0" + typ + cre + b"\0\0" + struct.pack(">II", len(d), len(r))
    raw = hdr + struct.pack(">H", crc16(hdr)) + d + struct.pack(">H", crc16(d)) + r + struct.pack(">H", crc16(r))
    o = bytearray(); i = 0
    while i < len(raw):
        b = raw[i]; n = 1
        while i + n < len(raw) and raw[i + n] == b and n < 255: n += 1
        if b == 0x90: o += b"\x90\x00" * n
        elif n > 3: o += bytes([b, 0x90, n])
        else: o += bytes([b]) * n
        i += n
    tbl = b"!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr"
    s = "".join(format(x, "08b") for x in o); s += "0" * ((6 - len(s) % 6) % 6)
    enc = b":" + bytes(tbl[int(s[k:k + 6], 2)] for k in range(0, len(s), 6)) + b":"
    return b"(This file must be converted with BinHex 4.0)\r\r" + b"\r".join(enc[k:k + 64] for k in range(0, len(enc), 64)) + b"\r"
write("classic.bin", macbinary("Demo App", b"APPL", b"DEMO", b"", rsrc))
write("classic.hqx", binhex("Demo App", b"APPL", b"DEMO", b"", rsrc))
write("._classic", struct.pack(">II16xH", 0x00051607, 0x00020000, 2) + struct.pack(">III", 9, 50, 32) + struct.pack(">III", 2, 82, len(rsrc)) + b"APPLDEMO" + b"\0" * 24 + rsrc)
write("classic.rsrc", rsrc)

# ---- PC-98: a 1.25 MB FAT12 floppy (1024-byte sectors) with DOS system files, as FDI, raw (HDM) and D88
def fat12_pc98(files, label):
    ss, total, fat_secs, root_ents = 1024, 1232, 2, 192
    img = bytearray(ss * total)
    bpb = b"\xeb\x3c\x90" + b"NEC  6.2" + struct.pack("<HBHBHHBHHHI", ss, 1, 1, 2, root_ents, total, 0xfe, fat_secs, 8, 2, 0)
    img[0:len(bpb)] = bpb
    img[54:59] = b"FAT12"
    fat = bytearray(ss * fat_secs); fat[0:3] = b"\xfe\xff\xff"
    def set12(n, v):
        o = n * 3 // 2
        if n & 1: fat[o] = (fat[o] & 0x0f) | ((v << 4) & 0xf0); fat[o + 1] = v >> 4
        else: fat[o] = v & 0xff; fat[o + 1] = (fat[o + 1] & 0xf0) | (v >> 8)
    root_start = ss * (1 + 2 * fat_secs)
    data_start = root_start + root_ents * 32
    cluster, ent = 2, 0
    root = bytearray(root_ents * 32)
    root[0:11] = label.encode("shift_jis").ljust(11); root[11] = 0x08; ent = 1
    for name, data in files:
        base, _, ext = name.partition(".")
        n = max(1, (len(data) + ss - 1) // ss)
        e = bytearray(32); e[0:8] = base.ljust(8).encode(); e[8:11] = ext.ljust(3).encode(); e[11] = 0x20
        struct.pack_into("<H", e, 26, cluster); struct.pack_into("<I", e, 28, len(data))
        root[ent * 32:ent * 32 + 32] = e; ent += 1
        img[data_start + (cluster - 2) * ss:data_start + (cluster - 2) * ss + len(data)] = data
        for k in range(n): set12(cluster + k, cluster + k + 1 if k < n - 1 else 0xfff)
        cluster += n
    img[ss:ss + len(fat)] = fat; img[ss * (1 + fat_secs):ss * (1 + fat_secs) + len(fat)] = fat
    img[root_start:root_start + len(root)] = root
    return bytes(img)
floppy = fat12_pc98([("IO.SYS", b"\0" * 3000), ("MSDOS.SYS", b"\0" * 2000), ("COMMAND.COM", b"\0" * 500 + b"MS-DOS Version 6.20" + b"\0" * 500),
                     ("AUTOEXEC.BAT", b"@ECHO OFF\r\nVER\r\n"), ("CONFIG.SYS", b"FILES=30\r\n")], "テスト")
write("dos.hdm", floppy)
write("dos.fdi", struct.pack("<IIIIIIII", 0, 0x90, 4096, len(floppy), 1024, 8, 2, 77) + b"\0" * (4096 - 32) + floppy)
tracks = []
for c in range(77):
    for h in range(2):
        t = b""
        for s in range(8):
            off = ((c * 2 + h) * 8 + s) * 1024
            t += struct.pack("<BBBBHBBB5xH", c, h, s + 1, 3, 8, 0, 0, 0, 1024) + floppy[off:off + 1024]
        tracks.append(t)
hdr = bytearray(0x2b0); hdr[0:4] = b"DEMO"; hdr[0x1b] = 0x20
pos = 0x2b0
for i, t in enumerate(tracks):
    struct.pack_into("<I", hdr, 0x20 + i * 4, pos); pos += len(t)
struct.pack_into("<I", hdr, 0x1c, pos)
write("dos.d88", bytes(hdr) + b"".join(tracks))

# ---- ISO 9660 with an autorun.inf
def iso(files, volume):
    sec = 2048
    def both16(v): return struct.pack("<H", v) + struct.pack(">H", v)
    def both32(v): return struct.pack("<I", v) + struct.pack(">I", v)
    def dirrec(name, lba, size, isdir):
        nb = name if isinstance(name, bytes) else name.encode()
        ln = 33 + len(nb) + (1 - len(nb) % 2)
        return bytes([ln, 0]) + both32(lba) + both32(size) + bytes([124, 1, 1, 0, 0, 0, 0]) + bytes([2 if isdir else 0, 0, 0]) + both16(1) + bytes([len(nb)]) + nb + (b"" if len(nb) % 2 else b"\0")
    root_lba, lba = 18, 19
    recs = dirrec(b"\0", root_lba, sec, True) + dirrec(b"\1", root_lba, sec, True)
    blobs = []
    for n, d in files:
        recs += dirrec(n.upper() + ";1", lba, len(d), False)
        blobs.append((lba, d)); lba += (len(d) + sec - 1) // sec or 1
    img = bytearray(sec * lba)
    pvd = bytearray(sec); pvd[0] = 1; pvd[1:6] = b"CD001"; pvd[6] = 1; pvd[8:40] = b"TEST".ljust(32); pvd[40:72] = volume.encode().ljust(32)
    pvd[80:88] = both32(lba); pvd[120:124] = both16(1); pvd[124:128] = both16(1); pvd[128:132] = both16(sec)
    pvd[156:190] = dirrec(b"\0", root_lba, sec, True); pvd[881] = 1
    img[16 * sec:17 * sec] = pvd
    term = bytearray(sec); term[0] = 255; term[1:6] = b"CD001"; term[6] = 1
    img[17 * sec:18 * sec] = term
    img[root_lba * sec:root_lba * sec + len(recs)] = recs
    for l, d in blobs: img[l * sec:l * sec + len(d)] = d
    return bytes(img)
write("disc.iso", iso([("autorun.inf", b"[autorun]\r\nopen=setup.exe /s\r\nlabel=Demo Disc\r\n"), ("setup.exe", b"MZ" + b"\0" * 62)], "DEMO_DISC"))

# ---- Android App Bundle: the manifest in protobuf form
def varint(v):
    o = b""
    while True:
        b = v & 0x7f; v >>= 7
        o += bytes([b | (0x80 if v else 0)])
        if not v: return o
def field(num, payload): return varint(num << 3 | 2) + varint(len(payload)) + payload
def attr(name, value): return field(4, field(2, name.encode()) + field(3, value.encode()))
def element(name, attrs=b"", children=b""): return field(1, field(3, name.encode()) + attrs + children)
manifest = element("manifest", attr("package", "org.example.bundle") + attr("versionName", "3.1") + attr("versionCode", "31"),
                   field(5, element("uses-sdk", attr("minSdkVersion", "24") + attr("targetSdkVersion", "34"))) + field(5, element("application", attr("label", "Bundle Demo"))))
write("demo.aab", zip_bytes([("base/manifest/AndroidManifest.xml", manifest), ("base/dex/classes.dex", b"dex\n035\0" + b"\0" * 100),
                             ("BundleConfig.pb", field(1, field(2, b"1.15.6")))]))

# ---- Executables: a bare ELF header (x86-64 shared object)
elf = b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8 + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 0, 0, 0, 64, 56, 0, 64, 0, 0)
write("lib.so", elf)
print("fixtures written to", out)
