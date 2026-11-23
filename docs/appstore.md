# App Store metadata (draft)

Text to paste into App Store Connect for the iOS / iPadOS app. Bundle ID: `jp.takpika.Nakami`.

## English

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

## 日本語

- **名前**: Nakami – ファイルの中身を見る
- **サブタイトル**: 開かずに、何のファイルか分かる
- **キーワード**: ipa,apk,exe,dll,dmg,iso,deb,rpm,jar,署名,解析,バイナリ,インストーラー,中身
- **プロモーション用テキスト**: アプリやインストーラー、ディスクイメージが本当は何なのかを、信用する前に確かめられます。
- **説明**:

  Nakami は、ふだん中身の分からないファイル（アプリ、実行ファイル、パッケージ、インストーラー、ディスクイメージ）を説明するアプリです。

  「ファイル」アプリからファイルを開くと、それが何で、どのバージョンで、誰が署名し、どの OS が必要で、どんな許可を求め、何が入っているのかを表示します。

  ・Apple のアプリ（.ipa、.app）: バージョン、署名、権限、機能拡張、プライバシー関連の利用
  ・Android（.apk、.aab）: 権限、署名、対応 OS
  ・Windows（.exe、.dll、.sys、.msi、.msix）: バージョン、署名者、インポート
  ・Linux（.deb、.rpm、AppImage、Snap、Flatpak）: 依存関係、インストール時のスクリプト、サンドボックスの権限
  ・macOS のパッケージとディスクイメージ（.pkg、.dmg、.ipsw、.xip）
  ・ディスクイメージ（.iso）: どの OS のインストーラーか、バージョンとエディション
  ・Java（.jar）、Flash（.swf）、カーネル、圧縮アーカイブ
  ・Classic Mac OS のファイルとディスク（漢字Talk を含む）、PC-98 のディスク、ゲーム機の ROM

  ファイルを実行することはありません。どこにも送信しません。すべて端末の中で読み取り、ネットワーク通信は行いません。

## Still needed before submitting

- Screenshots: iPhone 6.9" and iPad 13" (at least one each).
- An app record in App Store Connect for `jp.takpika.Nakami` (iOS platform).
- An App Store Connect API key for `scripts/release-ios.sh`.
- Age rating questionnaire (no objectionable content), export compliance (no non-exempt encryption — already declared in Info.plist).
