# Nakami

**See what is inside a file without opening it.** Nakami is a Quick Look extension and viewer for macOS (with an iOS / iPadOS app) that explains apps, executables, packages, installers and disk images: what they are, who signed them, what they need, and what they will do.

Press Space on a file in Finder and Nakami shows a summary. Open the file in the app for the full report.

日本語の説明は [README.ja.md](README.ja.md) にあります。

## What it reads

| Kind | Formats | What you see |
|---|---|---|
| Apple apps | `.app`, `.ipa`, frameworks, bundles, `.kext` | version, signature and team, entitlements, extensions, privacy usage, libraries |
| Executables | Mach-O, PE (`.exe` `.dll` `.sys`), ELF (`.so` `.ko`), `.a` / `.lib` | architecture, imports and exports, sections, signature, version info, driver type |
| Android | `.apk`, `.aab` | version, permissions, signing, SDK levels, icon |
| Windows packages | `.msi`, `.appx` / `.msix`, `.cab`, `.msu`, `.wim` / `.esd` | product, version, signer, contents |
| macOS packages | `.pkg`, `.xip`, `.ipsw`, `.dmg` (HFS+ and APFS) | what gets installed, scripts, the app inside a disk image |
| Linux packages | `.deb`, `.rpm`, AppImage, Snap, Flatpak | dependencies, install scripts, services, sandbox permissions, icon |
| Java | `.jar`, `.war`, `.aar` | required Java, Maven coordinates, Minecraft (game, mods, loaders) |
| Disc and disk images | `.iso`, `.img`, `.vhd` / `.vhdx` / `.vmdk` / `.qcow2` / `.vdi`, floppies | which OS installer it is, version and editions, partitions, `autorun.inf` |
| Classic Mac OS | MacBinary, BinHex, AppleDouble, resource forks, HFS / MFS images, Disk Copy 4.2, StuffIt, Compact Pro | version, CPU (68K / PowerPC), memory, icon, system version of a startup disk |
| PC-98 | FDI, HDM, D88, NFD, HDI, NHD | DOS version, files, PC-98 partition table |
| Game consoles | NES, Game Boy / Color / Advance, DS, N64, SNES, Mega Drive, GameCube / Wii, 3DS (`.cia` `.3dsx`), PSP | title, region, maker, icon |
| Other | `.swf`, kernels (Linux, NT, XNU), tar / gzip / xz / bzip2 / zstd archives | header facts, what scripts can do, what is inside |

Nothing is executed and nothing leaves your computer: every format is parsed by Nakami's own code, with no third-party libraries.

## Install

Download the latest `Nakami-x.y.zip` from [Releases](../../releases), unzip it and move `Nakami.app` to `/Applications`. Open it once; macOS then registers the Quick Look extensions. If previews do not appear, enable "Nakami" under System Settings → General → Login Items & Extensions → Quick Look.

Requires macOS 15 or later.

## Command line

The app contains a command-line tool:

```sh
/Applications/Nakami.app/Contents/Helpers/nakami <file> [--json] [--deep] [--png out.png]
```

`--json` prints the report as JSON, `--deep` removes the time limits used for previews, `--png` renders the preview to an image. Set `NAKAMI_LANG=en` or `ja` to choose the language.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./build.sh -          # ad-hoc signed build in build/Nakami.app (runs on this Mac)
./install.sh          # copy to /Applications and register the extensions
Tests/run.sh          # tests: generated fixtures, then damaged copies of them
NAKAMI_TEAM=XXXXXXXXXX ./build-ios.sh   # iOS / iPadOS build for your own devices
```

`./build.sh "Developer ID Application: …"` signs with that identity; `scripts/release-mac.sh` builds, notarizes and packages a release. `scripts/build-mas.sh` builds the fully sandboxed Mac App Store variant (no command-line tool).

The code is one multi-platform target: `Core/` (parsers and the report model, no UI), `UI/` (SwiftUI views shared by every platform), `App/`, `Preview/`, `Thumbnail/` (thin platform-specific shells), `CLI/`.

## Known limits

- StuffIt and Compact Pro archives are listed, but their contents are not unpacked.
- Encrypted disk images and APFS volumes are identified but not read.
- On iOS the system decides whether a Quick Look extension is asked at all; for many file types it is not.

## License

[MIT](LICENSE)
