# Nakami

**ファイルを開かずに、中身が何かを知る。** Nakami は macOS 用の Quick Look 拡張とビューア（iOS / iPadOS 版もあります）で、アプリ・実行ファイル・パッケージ・インストーラー・ディスクイメージについて、それが何で、誰が署名し、何を必要とし、何をするのかを説明します。

Finder でファイルを選んでスペースキーを押すと概要が出ます。アプリで開くと全体のレポートが見られます。

## 読める形式

| 種類 | 形式 | 見えるもの |
|---|---|---|
| Apple のアプリ | `.app`、`.ipa`、フレームワーク、バンドル、`.kext` | バージョン、署名と Team、権限、機能拡張、プライバシー関連の利用、ライブラリ |
| 実行ファイル | Mach-O、PE（`.exe` `.dll` `.sys`）、ELF（`.so` `.ko`）、`.a` / `.lib` | アーキテクチャ、インポートとエクスポート、セクション、署名、バージョン情報、ドライバーの種類 |
| Android | `.apk`、`.aab` | バージョン、権限、署名、対応 OS、アイコン |
| Windows のパッケージ | `.msi`、`.appx` / `.msix`、`.cab`、`.msu`、`.wim` / `.esd` | 製品、バージョン、署名者、中身 |
| macOS のパッケージ | `.pkg`、`.xip`、`.ipsw`、`.dmg`（HFS+ / APFS） | インストールされるもの、スクリプト、ディスクイメージの中のアプリ |
| Linux のパッケージ | `.deb`、`.rpm`、AppImage、Snap、Flatpak | 依存関係、インストール時のスクリプト、常駐サービス、サンドボックスの権限、アイコン |
| Java | `.jar`、`.war`、`.aar` | 必要な Java、Maven の座標、Minecraft（本体・Mod・Mod ローダー） |
| ディスクイメージ | `.iso`、`.img`、`.vhd` / `.vhdx` / `.vmdk` / `.qcow2` / `.vdi`、フロッピー | どの OS のインストーラーか、バージョンとエディション、パーティション、`autorun.inf` |
| Classic Mac OS | MacBinary、BinHex、AppleDouble、リソースフォーク、HFS / MFS のイメージ、Disk Copy 4.2、StuffIt、Compact Pro | バージョン、CPU（68K / PowerPC）、使用メモリー、アイコン、起動ディスクのシステムのバージョン（漢字Talk を含む） |
| PC-98 | FDI、HDM、D88、NFD、HDI、NHD | DOS のバージョン、ファイル、PC-98 のパーティション表 |
| ゲーム機 | ファミコン、ゲームボーイ / カラー / アドバンス、DS、N64、スーパーファミコン、メガドライブ、ゲームキューブ / Wii、3DS（`.cia` `.3dsx`）、PSP | タイトル、地域、メーカー、アイコン |
| その他 | `.swf`、カーネル（Linux、NT、XNU）、tar / gzip / xz / bzip2 / zstd | ヘッダーの情報、スクリプトにできること、中身 |

ファイルを実行することはなく、情報を外部へ送ることもありません。すべての形式を Nakami 自身のコードで読んでいて、外部ライブラリは使っていません。

## インストール

[Releases](../../releases) から最新の `Nakami-x.y.zip` を取得して展開し、`Nakami.app` を `/Applications` に移します。一度起動すると、macOS が Quick Look 拡張を登録します。プレビューが出ない場合は、システム設定 → 一般 → ログイン項目と機能拡張 → Quick Look で「Nakami」を有効にしてください。

macOS 15 以降が必要です。

## コマンドライン

アプリの中にコマンドラインツールが入っています。

```sh
/Applications/Nakami.app/Contents/Helpers/nakami <ファイル> [--json] [--deep] [--png out.png]
```

`--json` はレポートを JSON で出力、`--deep` はプレビュー用の時間制限を外して最後まで読み、`--png` はプレビューを画像にします。表示言語は `NAKAMI_LANG=ja` / `en` で指定できます。

## ビルド

Xcode と [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）が必要です。

```sh
./build.sh -          # その場限りの署名で build/Nakami.app を作る（この Mac で動く）
./install.sh          # /Applications に入れて拡張を登録する
Tests/run.sh          # テスト（生成した試験用ファイルと、それを壊したもの）
NAKAMI_TEAM=XXXXXXXXXX ./build-ios.sh   # 自分の端末向けの iOS / iPadOS 版
```

`./build.sh "Developer ID Application: …"` でその証明書を使って署名します。`scripts/release-mac.sh` はビルド・公証・配布物の作成までを行います。

コードは 1 つのマルチプラットフォームターゲットです。`Core/`（各形式の読み取りとレポートのモデル、UI なし）、`UI/`（全プラットフォーム共通の SwiftUI）、`App/`・`Preview/`・`Thumbnail/`（プラットフォームごとの薄い外枠）、`CLI/`。

## 分かっている制限

- StuffIt と Compact Pro は中身の一覧までで、展開はしません。
- 暗号化されたディスクイメージや APFS ボリュームは、種類の判別までで中は読めません。
- iOS では、Quick Look 拡張に問い合わせるかどうかをシステムが決めます。多くの形式では呼ばれません。

## ライセンス

[MIT](LICENSE)
