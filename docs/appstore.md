# App Store metadata (draft)

Text to paste into App Store Connect. The iOS / iPadOS app and the Mac App Store app share one record and one bundle ID (`jp.takpika.Nakami`), so buying one gives both.

Builds: `scripts/store.sh ios upload` and `scripts/store.sh mac upload` (run by the release workflow) sign with an explicit certificate and profiles and upload to App Store Connect. The Mac App Store build has no command-line tool and no "Open in Nakami" button in Quick Look (neither is possible inside the sandbox); the Developer ID build on GitHub keeps both.

## iOS / iPadOS version

### English

- **Name**: Nakami – File Inspector
- **Subtitle**: See what is inside a file
- **Category**: Developer Tools (secondary: Utilities)
- **Keywords**: ipa,apk,exe,dll,elf,mach-o,dmg,iso,deb,rpm,jar,signature,inspector,binary,installer
- **Promotional text**: Find out what an app, installer or disk image really is before you trust it.
- **Description**:

  Nakami explains files that normally stay opaque: apps, executables, packages, installers and disk images.

  Open a file from the Files app and Nakami shows what it is, which version, who signed it, which system it needs, what it asks permission for and what it contains.

  • Apple apps (.ipa, .app): version, signing, entitlements, extensions, privacy usage
  • Android (.apk, .aab): permissions, signing, SDK levels
  • Windows (.exe, .dll, .sys, .msi, .msix): version, signer, imports
  • Linux (.deb, .rpm, AppImage, Snap, Flatpak): dependencies, install scripts, sandbox permissions
  • macOS packages and disk images (.pkg, .dmg, .ipsw, .xip)
  • Disc images (.iso): which OS installer, version and editions
  • Java (.jar), Flash (.swf), kernels, compressed archives
  • Classic Mac OS files and disks, PC-98 disks, game console ROMs

  Nothing is executed. Nothing is uploaded: every file is read on your device, and the app makes no network connections.

- **Privacy**: Data Not Collected. Privacy policy URL: the `PRIVACY.md` page of the GitHub repository.
- **Review notes**: The app is a read-only viewer. It parses the selected file's headers and metadata and displays them; it does not run, install or modify anything. Sample files can be created with any app or downloaded; an .ipa or .zip from the Files app is enough to see it work.

### 日本語

- **名前**: （App Store Connect で通った名前）
- **サブタイトル**: アプリやインストーラーの情報を表示
- **キーワード**: ipa,apk,exe,dmg,iso,deb,jar,署名,解析,インストーラー,中身,ファイル情報,バイナリ,確認
- **プロモーション用テキスト**: アプリやインストーラーの中身を、インストールせずに確認できます。ipa、apk、exe、iso など多くの形式に対応しています。
- **説明**:

  アプリやインストーラー、ディスクイメージなどのファイルを開いて、その詳しい情報を表示するアプリです。インストールや実行をせずに、中身を確認できます。

  ■ 使い方
  ・Nakami を起動して、調べたいファイルを選びます
  ・「ファイル」アプリでファイルを長押しして、Nakami で開くこともできます

  ■ 表示できる情報
  ・バージョン、対応 OS、対応 CPU
  ・コード署名の状態、開発元
  ・権限、プライバシー関連の利用目的
  ・機能拡張、使用しているライブラリ
  ・ディスクイメージやパッケージの中身

  ■ 対応形式
  ・iOS / macOS: ipa、app、dmg、pkg、ipsw
  ・Android / Linux: apk、aab、deb、rpm、AppImage、Snap、Flatpak
  ・Windows: exe、dll、sys、msi、msix
  ・ディスクイメージ: iso、vhd、vmdk、qcow2
  ・その他: jar、swf、Classic Mac OS、PC-98、ゲーム ROM

  ■ その他
  ・ipa や apk、exe、ROM などのアイコンを「ファイル」アプリに表示します
  ・iPad では複数のファイルを別々のウインドウで開けます
  ・ファイルの実行や外部との通信は行いません

## macOS version (separate text — the Mac app is used from Finder, not from the Files app)

### English

- **Subtitle**: Quick Look for apps and installers
- **Promotional text**: Press Space on an app, installer or disk image in Finder and see what it really is.
- **Description**:

  Nakami adds Quick Look previews for the files macOS normally shows as a blank icon: apps, executables, packages, installers and disk images.

  Select a file in Finder and press Space. Nakami shows what it is, which version, who signed it, which system it needs, what it asks permission for and what it contains. Open the file in Nakami for the full report, section by section.

  Finder also shows the real icon of Windows programs, Android and Linux packages, classic Mac applications and game ROMs instead of a generic one.

  • Apple apps (.app, .ipa, .pkg, .dmg, .ipsw): version, signature and notarization, entitlements, extensions, privacy usage; the app inside a disk image is analysed like an installed one
  • Windows (.exe, .dll, .sys, .msi, .msix): version, signer, imports, driver type
  • Android (.apk, .aab) and Linux (.deb, .rpm, AppImage, Snap, Flatpak): permissions, dependencies, install scripts
  • Disc images (.iso): which OS installer, version and editions, autorun
  • Java (.jar, including Minecraft and its mods), Flash (.swf), kernels, compressed archives
  • Classic Mac OS files and disks, PC-98 disks, game console ROMs

  Nothing is executed. Nothing is uploaded: every file is read on your Mac, and the app makes no network connections.

  If previews do not appear, enable Nakami under System Settings → General → Login Items & Extensions → Quick Look.

### 日本語

- **サブタイトル**: アプリやインストーラーの情報を Quick Look で表示
- **プロモーション用テキスト**: Finder でスペースキーを押すだけで、アプリやインストーラーの情報を確認できます。exe や apk などのアイコンも Finder に表示します。
- **説明**:

  Finder でファイルを選んでスペースキーを押すと、そのファイルの詳しい情報を表示する Quick Look 拡張です。アプリやインストーラー、ディスクイメージなどを、開かずに確認できます。

  ■ 表示できる情報
  ・バージョン、対応 OS、対応 CPU
  ・コード署名と公証の状態、開発元
  ・権限、プライバシー関連の利用目的
  ・機能拡張、使用しているライブラリ
  ・ディスクイメージやパッケージの中身

  ■ 対応形式
  ・macOS / iOS: app、ipa、dmg、pkg、ipsw
  ・Windows: exe、dll、sys、msi、msix
  ・Android / Linux: apk、aab、deb、rpm、AppImage、Snap、Flatpak
  ・ディスクイメージ: iso、vhd、vmdk、qcow2
  ・その他: jar、swf、Classic Mac OS、PC-98、ゲーム ROM

  ■ その他
  ・exe や apk、ROM などのアイコンを Finder に表示します
  ・Nakami で開くと、すべての項目を確認できます
  ・ファイルの実行や外部との通信は行いません

  プレビューが表示されない場合は、システム設定 > 一般 > ログイン項目と機能拡張 > Quick Look で Nakami を有効にしてください。

## Still needed before submitting

- Screenshots: iPhone 6.9" and iPad 13" (at least one each), and Mac (1280 × 800 or larger).
- Add the macOS platform to the same app record.
- An app record in App Store Connect for `jp.takpika.Nakami` (iOS platform).
- Age rating questionnaire (no objectionable content), export compliance (no non-exempt encryption — already declared in Info.plist).
