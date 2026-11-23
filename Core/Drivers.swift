import Foundation

/// Driver-specific details: macOS kernel / driver extensions and Windows kernel drivers.
enum Drivers {
    /// IOKit matching and dependencies of a .kext / .dext, from its Info.plist.
    static func kextSection(_ info: [String: Any]) -> ReportSection? {
        let personalities = (info["IOKitPersonalities"] as? [String: Any]) ?? [:]
        let libs = (info["OSBundleLibraries"] as? [String: Any]) ?? [:]
        guard !personalities.isEmpty || !libs.isEmpty || info["OSBundleRequired"] != nil else { return nil }
        var blocks = [Block]()
        var rows = [Row]()
        let required = ["Root": L("起動に必須（ルートのマウントに必要）", "Required to boot (root mount)"), "Local-Root": L("ローカルディスクからの起動に必須", "Required for local-root boot"),
                        "Network-Root": L("ネットワーク起動に必須", "Required for network-root boot"), "Console": L("コンソール表示に必須", "Required for console"),
                        "Safe Boot": L("セーフブートでも読み込む", "Loaded in Safe Boot"), "DriverKit": "DriverKit"]
        rows.add(L("起動時の扱い", "Boot requirement"), (info["OSBundleRequired"] as? String).map { required[$0] ?? $0 })
        if (info["OSBundleAllowUserLoad"] as? Bool) == true { rows.add(L("一般ユーザーによる読み込み", "User loading"), L("許可", "Allowed")) }
        rows.add(L("互換バージョン", "Compatible version"), info["OSBundleCompatibleVersion"] as? String)
        if (info["OSBundleUsageDescription"] as? String) != nil { rows.add(L("利用目的の説明", "Usage description"), info["OSBundleUsageDescription"] as? String) }
        if !rows.isEmpty { blocks.append(.rows(rows)) }
        if !personalities.isEmpty {
            blocks.append(.heading(L("対応するデバイスの条件", "Device matching")))
            let matchKeys = ["idVendor", "idProduct", "idVendorArray", "idProductArray", "bDeviceClass", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol", "IOPCIMatch", "IOPCIPrimaryMatch",
                             "IOPCIClassMatch", "IONameMatch", "IOPropertyMatch", "IOResourceMatch", "VendorID", "ProductID", "DeviceUsagePairs", "IOProbeScore", "IOMatchCategory", "Physical Interconnect"]
            let table = personalities.keys.sorted().compactMap { name -> [String]? in
                guard let p = personalities[name] as? [String: Any] else { return nil }
                let match = matchKeys.compactMap { k -> String? in
                    guard let v = p[k] else { return nil }
                    // USB vendor / product IDs are usually quoted in hex.
                    if (k == "idVendor" || k == "idProduct" || k == "VendorID" || k == "ProductID"), let n = v as? NSNumber { return "\(k) \(hex(n.intValue, pad: 4))" }
                    return "\(k) \(describePlistValue(v))"
                }.joined(separator: "; ")
                return [name, (p["IOClass"] as? String) ?? (p["IOUserClass"] as? String) ?? "", (p["IOProviderClass"] as? String) ?? "", match]
            }
            blocks.append(.table(TableData(columns: [L("名前", "Personality"), L("ドライバーのクラス", "Driver class"), L("接続先のクラス", "Provider class"), L("一致条件", "Match")], rows: table)))
        }
        if !libs.isEmpty {
            blocks.append(.heading(L("依存するカーネルの部品", "Kernel dependencies")))
            blocks.append(.table(TableData(columns: [L("部品", "Library"), L("必要なバージョン", "Version")], rows: libs.keys.sorted().map { [$0, describePlistValue(libs[$0]!)] })))
        }
        return ReportSection(id: "driver", title: L("ドライバー", "Driver"), symbol: "cable.connector", blocks: blocks, count: personalities.isEmpty ? nil : personalities.count)
    }

    /// Well-known parts of Windows itself. These are the providers that other drivers build on, so judging them
    /// by what they import gives misleading answers (ndis.sys is not "a network filter", it is NDIS).
    static let windowsComponents: [String: (ja: String, en: String)] = [
        "ndis.sys": ("NDIS 本体（ネットワークドライバーの土台）", "NDIS itself (the base for network drivers)"),
        "tcpip.sys": ("TCP/IP プロトコルスタック", "TCP/IP protocol stack"), "afd.sys": ("ソケットの土台 (Winsock の裏側)", "Socket layer (behind Winsock)"),
        "netio.sys": ("ネットワーク I/O の共通部品", "Network I/O subsystem"), "http.sys": ("HTTP プロトコルスタック", "HTTP protocol stack"),
        "fwpkclnt.sys": ("Windows フィルタリングプラットフォームの部品", "Windows Filtering Platform client"), "tdx.sys": ("旧式のトランスポート層の互換部品", "TDI translation driver"),
        "storport.sys": ("Storport 本体（ストレージドライバーの土台）", "Storport itself (the base for storage drivers)"), "scsiport.sys": ("SCSIPort 本体", "SCSIPort itself"),
        "classpnp.sys": ("ストレージクラスドライバーの共通部品", "Storage class driver library"), "disk.sys": ("ディスクのクラスドライバー", "Disk class driver"),
        "cdrom.sys": ("光学ドライブのクラスドライバー", "Optical drive class driver"), "partmgr.sys": ("パーティションマネージャー", "Partition manager"),
        "volmgr.sys": ("ボリュームマネージャー", "Volume manager"), "volmgrx.sys": ("ボリュームマネージャー（ダイナミックディスク）", "Volume manager (dynamic disks)"),
        "mountmgr.sys": ("マウントマネージャー（ドライブ文字の割り当て）", "Mount manager (drive letters)"), "volsnap.sys": ("ボリュームのスナップショット (VSS)", "Volume shadow copy"),
        "fvevol.sys": ("BitLocker のドライブ暗号化", "BitLocker drive encryption"), "stornvme.sys": ("NVMe のドライバー", "NVMe driver"), "storahci.sys": ("SATA (AHCI) のドライバー", "SATA (AHCI) driver"),
        "fltmgr.sys": ("フィルターマネージャー（ファイルシステムフィルターの土台）", "Filter Manager (the base for file system filters)"),
        "ntfs.sys": ("NTFS ファイルシステム", "NTFS file system"), "fastfat.sys": ("FAT ファイルシステム", "FAT file system"), "exfat.sys": ("exFAT ファイルシステム", "exFAT file system"),
        "refs.sys": ("ReFS ファイルシステム", "ReFS file system"), "cdfs.sys": ("CD-ROM ファイルシステム", "CD-ROM file system"), "udfs.sys": ("UDF ファイルシステム", "UDF file system"),
        "npfs.sys": ("名前付きパイプ", "Named pipes"), "msfs.sys": ("メールスロット", "Mailslots"), "wof.sys": ("ファイル圧縮のオーバーレイ", "Windows overlay filter"),
        "rdbss.sys": ("ネットワークファイルシステムの共通部品", "Redirected drive buffering"), "mrxsmb.sys": ("SMB クライアント", "SMB client"), "srv2.sys": ("SMB サーバー", "SMB server"),
        "wdf01000.sys": ("KMDF 本体（ドライバーフレームワークのランタイム）", "KMDF runtime itself"), "wdfldr.sys": ("KMDF のローダー", "KMDF loader"),
        "hidclass.sys": ("HID クラスドライバー（HID ドライバーの土台）", "HID class driver"), "hidparse.sys": ("HID レポートの解析部品", "HID parsing library"),
        "kbdclass.sys": ("キーボードのクラスドライバー", "Keyboard class driver"), "mouclass.sys": ("マウスのクラスドライバー", "Mouse class driver"),
        "i8042prt.sys": ("PS/2 キーボード・マウスのドライバー", "PS/2 keyboard and mouse driver"), "kbdhid.sys": ("USB キーボードのドライバー", "USB keyboard driver"),
        "usbhub.sys": ("USB ハブのドライバー", "USB hub driver"), "usbhub3.sys": ("USB 3 ハブのドライバー", "USB 3 hub driver"), "usbxhci.sys": ("USB 3 (xHCI) コントローラーのドライバー", "USB 3 (xHCI) controller driver"),
        "usbport.sys": ("USB コントローラーの共通部品", "USB port driver"), "usbd.sys": ("USB の共通部品", "USB driver library"), "ucx01000.sys": ("USB コントローラーの拡張部品", "USB controller extension"),
        "usbccgp.sys": ("USB 複合デバイスの親ドライバー", "USB composite parent driver"), "usbstor.sys": ("USB メモリーのドライバー", "USB mass storage driver"),
        "acpi.sys": ("ACPI ドライバー（電源と構成）", "ACPI driver"), "pci.sys": ("PCI バスのドライバー", "PCI bus driver"), "intelppm.sys": ("プロセッサーの電源管理", "Processor power management"),
        "win32k.sys": ("Win32 サブシステムのカーネル部分（ウインドウと描画）", "Win32 subsystem kernel part (windows and drawing)"),
        "win32kfull.sys": ("Win32 サブシステムのカーネル部分（本体）", "Win32 subsystem kernel part (full)"), "win32kbase.sys": ("Win32 サブシステムのカーネル部分（基礎）", "Win32 subsystem kernel part (base)"),
        "dxgkrnl.sys": ("DirectX グラフィックスのカーネル", "DirectX graphics kernel"), "dxgmms2.sys": ("GPU のメモリー管理とスケジューラー", "GPU memory manager and scheduler"),
        "cng.sys": ("暗号機能（次世代）", "Kernel cryptography (CNG)"), "ksecdd.sys": ("カーネルのセキュリティ支援", "Kernel security support"), "ci.dll": ("コード整合性（署名の検証）", "Code Integrity"),
        "clfs.sys": ("共通ログファイルシステム", "Common Log File System"), "wdfilter.sys": ("Microsoft Defender のファイルシステムフィルター", "Microsoft Defender file system filter"),
        "ks.sys": ("カーネルストリーミングの土台", "Kernel streaming"), "portcls.sys": ("オーディオのポートクラス", "Audio port class"), "bthport.sys": ("Bluetooth の土台", "Bluetooth port driver"),
        "null.sys": ("NUL デバイス", "Null device"), "beep.sys": ("ビープ音", "Beep"), "pshed.dll": ("ハードウェアエラーの処理", "Platform-specific hardware error driver"),
        "bootvid.dll": ("起動画面の描画", "Boot video driver"), "kdcom.dll": ("カーネルデバッガーの通信", "Kernel debugger transport"), "vmbus.sys": ("Hyper-V の仮想バス", "Hyper-V virtual bus"),
    ]

    /// What kind of Windows kernel driver this is, judged from what it imports.
    static func windowsSection(name: String = "", imports: [String], functions: Set<String> = [], exported: Int = 0, microsoft: Bool = false, is64: Bool = true,
                               signer: String?, sections: [String]) -> (section: ReportSection, model: String)? {
        let set = Set(imports.map { $0.lowercased() })
        func has(_ n: String) -> Bool { set.contains(n) }
        func calls(_ names: String...) -> Bool { names.contains { functions.contains($0) } }
        var kinds = [String]()
        // The functions a driver registers itself with say more than the libraries it links against:
        // file system drivers, for one, import nothing but the kernel itself.
        if calls("IoRegisterFileSystem") { kinds.append(L("ファイルシステムのドライバー", "File system driver")) }
        if calls("FltRegisterFilter") { kinds.append(L("ファイルシステムのミニフィルター", "File system minifilter")) }
        if calls("NdisMRegisterMiniportDriver", "NdisMRegisterMiniport") { kinds.append(L("NDIS ミニポート（ネットワークアダプター）", "NDIS miniport (network adapter)")) }
        if calls("NdisRegisterProtocolDriver", "NdisRegisterProtocol") { kinds.append(L("NDIS プロトコルドライバー", "NDIS protocol driver")) }
        if calls("NdisFRegisterFilterDriver") { kinds.append(L("NDIS フィルタードライバー", "NDIS filter driver")) }
        if calls("ClassInitialize", "ClassInitializeEx") { kinds.append(L("ストレージのクラスドライバー", "Storage class driver")) }
        if calls("StorPortInitialize") { kinds.append(L("ストレージ (Storport ミニポート)", "Storage (Storport miniport)")) }
        if calls("ScsiPortInitialize") { kinds.append(L("ストレージ (SCSIPort ミニポート)", "Storage (SCSIPort miniport)")) }
        if calls("KbdClassServiceCallback") || (calls("IoCreateDevice") && sections.isEmpty == false && functions.contains(where: { $0.hasPrefix("Kbd") })) { kinds.append(L("キーボードのドライバー", "Keyboard driver")) }
        // A named part of Windows: say what it is and skip the guesses below.
        let known = microsoft ? windowsComponents[name.lowercased()] : nil
        if let known { kinds = [L(known.ja, known.en)] }
        let precise = !kinds.isEmpty
        if known == nil, has("wdfldr.sys") { kinds.append(L("KMDF（カーネルモードドライバーフレームワーク）", "KMDF (Kernel-Mode Driver Framework)")) }
        if !precise {
            if has("ndis.sys") { kinds.append(L("NDIS ネットワークドライバー", "NDIS network driver")) }
            if has("storport.sys") { kinds.append(L("ストレージ (Storport ミニポート)", "Storage (Storport miniport)")) }
            if has("scsiport.sys") { kinds.append(L("ストレージ (SCSIPort)", "Storage (SCSIPort)")) }
            if has("fltmgr.sys") { kinds.append(L("ファイルシステムのミニフィルター", "File system minifilter")) }
        }
        if known == nil, has("ks.sys") || has("portcls.sys") { kinds.append(L("オーディオ / カーネルストリーミング", "Audio / kernel streaming")) }
        if known == nil, has("usbd.sys") || has("usbdex.lib") || has("ucx01000.sys") { kinds.append(L("USB ドライバー", "USB driver")) }
        if known == nil, has("hidclass.sys") { kinds.append(L("HID ドライバー", "HID driver")) }
        if known == nil, has("dxgkrnl.sys") || has("videoprt.sys") { kinds.append(L("ディスプレイドライバー", "Display driver")) }
        if known == nil, has("win32k.sys") || has("win32kbase.sys") { kinds.append(L("グラフィックス (win32k)", "Graphics (win32k)")) }
        if known == nil, has("fwpkclnt.sys") { kinds.append(L("ネットワークフィルター (WFP)", "Network filtering (WFP)")) }
        if known == nil, has("ksecdd.sys") || has("cng.sys") { kinds.append(L("暗号機能を使用", "Uses kernel crypto")) }
        if !precise, has("classpnp.sys") { kinds.append(L("ストレージのクラスドライバー", "Storage class driver")) }
        if known == nil, has("bthport.sys") { kinds.append(L("Bluetooth ドライバー", "Bluetooth driver")) }
        if kinds.isEmpty, has("ntoskrnl.exe") { kinds.append(L("WDM（従来型のカーネルドライバー）", "WDM (classic kernel driver)")) }
        guard !kinds.isEmpty || has("hal.dll") else { return nil }
        var rows = [Row]()
        rows.add(L("ドライバーの種類", "Driver model"), kinds.joined(separator: "\n"))
        if let signer {
            let whql = signer.contains("Hardware Compatibility")
            rows.add(L("署名の区分", "Signature class"), whql ? L("WHQL（Microsoft のハードウェア互換性の署名）", "WHQL (Microsoft hardware compatibility)") : signer.contains("Microsoft Windows") ? L("Windows 同梱のドライバー", "Shipped with Windows") : L("開発元の署名（WHQL ではありません）", "Vendor-signed (not WHQL)"),
                     tone: whql ? .good : .neutral)
        } else if microsoft {
            // Files that ship with Windows are often signed through a separate catalogue file, not inside the file.
            rows.add(L("署名の区分", "Signature class"), L("ファイル内に署名なし（Windows 同梱のファイルは、別のカタログファイルで署名されていることがあります）", "No embedded signature (files shipped with Windows are often catalogue-signed)"))
        } else {
            rows.add(L("署名の区分", "Signature class"), is64 ? L("署名なし（64 ビット版 Windows ではテストモード以外で読み込めません）", "Unsigned (64-bit Windows will not load it outside test mode)") : L("署名なし", "Unsigned"), tone: .warn)
        }
        if exported > 30 { rows.add(L("ほかのドライバーへの提供", "Offers to other drivers"), L("\(exported) 個の関数を公開（ほかのドライバーが土台として使う部品です）", "Exports \(exported) functions (other drivers build on it)", "公開 \(exported) 個函式（其他驅動程式會以此為基礎）")) }
        // Things the driver hooks into system-wide (typical of security software, anti-cheat and monitoring tools).
        var behaviours = [String]()
        if calls("PsSetCreateProcessNotifyRoutine", "PsSetCreateProcessNotifyRoutineEx", "PsSetCreateProcessNotifyRoutineEx2") { behaviours.append(L("プロセスの起動と終了を監視", "Watches process creation and exit")) }
        if calls("PsSetCreateThreadNotifyRoutine", "PsSetCreateThreadNotifyRoutineEx") { behaviours.append(L("スレッドの作成を監視", "Watches thread creation")) }
        if calls("PsSetLoadImageNotifyRoutine", "PsSetLoadImageNotifyRoutineEx") { behaviours.append(L("プログラムや DLL の読み込みを監視", "Watches image loading")) }
        if calls("ObRegisterCallbacks") { behaviours.append(L("ほかのプロセスへのアクセスを仲介", "Intercepts handle access to processes")) }
        if calls("CmRegisterCallback", "CmRegisterCallbackEx") { behaviours.append(L("レジストリの操作を監視", "Watches registry operations")) }
        if calls("FwpmCalloutAdd0", "FwpsCalloutRegister0", "FwpsCalloutRegister1", "FwpsCalloutRegister2", "FwpsCalloutRegister3") { behaviours.append(L("通信を検査・書き換え (WFP)", "Inspects network traffic (WFP)")) }
        if calls("ZwLoadDriver") { behaviours.append(L("ほかのドライバーを読み込む", "Loads other drivers")) }
        if calls("MmMapIoSpace", "MmMapIoSpaceEx") { behaviours.append(L("物理メモリーを直接マップ", "Maps physical memory")) }
        if calls("IoCreateSymbolicLink") { behaviours.append(L("アプリから開けるデバイス名を公開", "Exposes a device name to applications")) }
        rows.add(L("システムへの関わり方", "System-wide hooks"), behaviours.joined(separator: "\n"))
        if sections.contains("INIT") { rows.add(L("初期化専用のコード", "Init-only code"), L("あり（INIT セクション。読み込み後に破棄されます）", "Yes (INIT section, discarded after loading)")) }
        if sections.contains(where: { $0.hasPrefix("PAGE") }) { rows.add(L("ページアウト可能なコード", "Pageable code"), L("あり (PAGE セクション)", "Yes (PAGE sections)")) }
        rows.add(L("依存するカーネルの部品", "Kernel dependencies"), imports.joined(separator: ", "), mono: true)
        return (ReportSection(id: "driver", title: L("ドライバー", "Driver"), symbol: "cable.connector", blocks: [.rows(rows)]), kinds.first ?? "")
    }
}

extension Drivers {
    /// "pci:v000010ECd00008168sv*sd*bc*sc*i*" → ("PCI", "10EC:8168")
    static func decodeAlias(_ a: String) -> (bus: String, id: String) {
        func field(_ key: String, _ len: Int) -> String? {
            firstMatch(a, key + "([0-9A-Fa-f]{\(len)})")
        }
        if a.hasPrefix("pci:") {
            let v = field("v", 8).map { String($0.suffix(4)) } ?? "*", d = field("d", 8).map { String($0.suffix(4)) } ?? "*"
            var extra = ""
            if let sv = firstMatch(a, "sv([0-9A-Fa-f]{8})"), let sd = firstMatch(a, "sd([0-9A-Fa-f]{8})") { extra = L("、サブシステム ", ", subsystem ") + sv.suffix(4) + ":" + sd.suffix(4) }
            if let bc = firstMatch(a, "bc([0-9A-Fa-f]{2})"), v == "*" { extra += L("、クラス ", ", class ") + bc + (firstMatch(a, "sc([0-9A-Fa-f]{2})") ?? "") }
            return ("PCI", "\(v):\(d)" + extra)
        }
        if a.hasPrefix("usb:") {
            let v = field("v", 4) ?? "*", p = field("p", 4) ?? "*"
            var extra = ""
            if v == "*", let ic = firstMatch(a, "ic([0-9A-Fa-f]{2})") { extra = L("、インターフェースクラス ", ", interface class ") + ic }
            return ("USB", "\(v):\(p)" + extra)
        }
        if a.hasPrefix("of:") { return (L("デバイスツリー", "Device tree"), firstMatch(a, "C(.+)$") ?? String(a.dropFirst(3))) }
        if a.hasPrefix("acpi") { return ("ACPI", a.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: ":"))) }
        if a.hasPrefix("hid:") {
            return ("HID", (firstMatch(a, "v([0-9A-Fa-f]{8})").map { String($0.suffix(4)) } ?? "*") + ":" + (firstMatch(a, "p([0-9A-Fa-f]{8})").map { String($0.suffix(4)) } ?? "*"))
        }
        for (prefix, bus) in [("platform:", L("プラットフォーム", "Platform")), ("i2c:", "I2C"), ("spi:", "SPI"), ("sdio:", "SDIO"), ("virtio:", "VirtIO"), ("input:", L("入力", "Input")),
                              ("dmi", "DMI"), ("pnp:", "PnP"), ("serio:", "serio"), ("mdio:", "MDIO"), ("xen:", "Xen"), ("vmbus:", "Hyper-V VMBus"), ("ieee1394:", "FireWire"),
                              ("thunderbolt:", "Thunderbolt"), ("nvme:", "NVMe"), ("scsi:", "SCSI"), ("fs-", L("ファイルシステム", "File system")), ("net-pf-", L("ネットワークプロトコル", "Network protocol")),
                              ("crypto-", L("暗号アルゴリズム", "Crypto algorithm")), ("char-major-", L("キャラクターデバイス", "Character device")), ("block-major-", L("ブロックデバイス", "Block device"))] where a.hasPrefix(prefix) {
            return (bus, prefix.hasSuffix(":") ? String(a.dropFirst(prefix.count)) : a)
        }
        return (L("名前", "Name"), a)
    }

    /// Linux kernel module: its .modinfo entries arranged by meaning, the appended signature, and what it registers as.
    static func linuxModule(modinfo: [(String, String)], undefined: Set<String>, signature: (signer: String?, hash: String?)?) -> (summary: [Row], sections: [ReportSection], badges: [Badge]) {
        func all(_ k: String) -> [String] { modinfo.filter { $0.0 == k }.map { $0.1 } }
        func one(_ k: String) -> String? { all(k).first }
        var sum = [Row]()
        var badges = [Badge]()
        sum.add(L("説明", "Description"), one("description"))
        sum.add(L("作者", "Author"), all("author").joined(separator: "\n"))
        sum.add(L("ライセンス", "License"), one("license"))
        sum.add(L("バージョン", "Version"), one("version"))
        // What kind of module, from the kernel functions it registers with.
        let registrations: [(String, String)] = [
            ("register_filesystem", L("ファイルシステム", "File system")), ("__pci_register_driver", L("PCI デバイスのドライバー", "PCI device driver")),
            ("usb_register_driver", L("USB デバイスのドライバー", "USB device driver")), ("register_netdev", L("ネットワークデバイス", "Network device")),
            ("register_netdevice", L("ネットワークデバイス", "Network device")), ("__platform_driver_register", L("プラットフォームデバイスのドライバー", "Platform device driver")),
            ("i2c_register_driver", L("I2C デバイスのドライバー", "I2C device driver")), ("__spi_register_driver", L("SPI デバイスのドライバー", "SPI device driver")),
            ("__hid_register_driver", L("HID デバイスのドライバー", "HID device driver")), ("snd_card_new", L("サウンド", "Sound")), ("drm_dev_register", L("グラフィックス (DRM)", "Graphics (DRM)")),
            ("register_blkdev", L("ブロックデバイス", "Block device")), ("__register_blkdev", L("ブロックデバイス", "Block device")), ("misc_register", L("キャラクターデバイス (misc)", "Character device (misc)")),
            ("__register_chrdev", L("キャラクターデバイス", "Character device")), ("cdev_add", L("キャラクターデバイス", "Character device")), ("crypto_register_alg", L("暗号アルゴリズム", "Crypto algorithm")),
            ("crypto_register_shash", L("暗号アルゴリズム", "Crypto algorithm")), ("nf_register_net_hook", L("パケットフィルター (netfilter)", "Packet filter (netfilter)")),
            ("nf_register_net_hooks", L("パケットフィルター (netfilter)", "Packet filter (netfilter)")), ("xt_register_target", L("iptables の拡張", "iptables extension")),
            ("xt_register_match", L("iptables の拡張", "iptables extension")), ("input_register_device", L("入力デバイス", "Input device")), ("scsi_add_host_with_dma", L("SCSI ホスト", "SCSI host")),
            ("mmc_register_driver", L("SD / MMC", "SD / MMC")), ("__sdio_register_driver", L("SDIO デバイスのドライバー", "SDIO device driver")), ("register_kprobe", L("カーネルの関数にフック (kprobe)", "Kernel probes (kprobe)")),
            ("sock_register", L("ネットワークプロトコル", "Network protocol")), ("proto_register", L("ネットワークプロトコル", "Network protocol")), ("__virtio_register_driver", L("VirtIO デバイスのドライバー", "VirtIO device driver")),
            ("v4l2_device_register", L("ビデオ (V4L2)", "Video (V4L2)")), ("ieee80211_register_hw", L("無線 LAN (mac80211)", "Wi-Fi (mac80211)")), ("wiphy_register", L("無線 LAN (cfg80211)", "Wi-Fi (cfg80211)")),
            ("thermal_zone_device_register", L("温度管理", "Thermal")), ("hwmon_device_register_with_info", L("ハードウェアモニター", "Hardware monitoring")), ("register_shrinker", L("メモリー管理", "Memory management")),
        ]
        var kinds = [String]()
        for (sym, name) in registrations where undefined.contains(sym) && !kinds.contains(name) { kinds.append(name) }
        sum.add(L("モジュールの種類", "Module type"), kinds.joined(separator: L("、", ", ")))
        if let vm = one("vermagic") {
            let parts = vm.split(separator: " ").map(String.init)
            sum.add(L("対象のカーネル", "Built for kernel"), parts.first.map { $0 + (parts.count > 1 ? "（" + parts.dropFirst().joined(separator: " ") + "）" : "") })
        }
        let deps = all("depends").flatMap { $0.split(separator: ",").map(String.init) }.filter { !$0.isEmpty }
        sum.add(L("依存するモジュール", "Depends on"), deps.joined(separator: ", "))
        sum.add(L("先に読み込むモジュール", "Soft dependencies"), all("softdep").joined(separator: "; "))
        if one("intree") != nil { sum.add(L("出どころ", "Origin"), L("カーネル本体のソースに含まれるモジュール", "In-tree (part of the kernel sources)")) }
        else { sum.add(L("出どころ", "Origin"), L("カーネルの外でビルドされたモジュール", "Out-of-tree"), tone: .neutral) }
        if let sig = signature {
            sum.add(L("署名", "Signature"), (sig.signer ?? L("あり", "Present")) + (sig.hash.map { " (\($0))" } ?? ""), tone: .good)
            badges.append(Badge(text: L("署名済み", "Signed"), tone: .good))
        } else {
            sum.add(L("署名", "Signature"), L("なし（セキュアブート有効時は読み込めないことがあります）", "None (may not load with Secure Boot)"))
            badges.append(Badge(text: L("署名なし", "Unsigned"), tone: .neutral))
        }
        if let lic = one("license"), !lic.contains("GPL") { badges.append(Badge(text: L("GPL 以外のライセンス", "Non-GPL license"), tone: .warn)) }

        var sections = [ReportSection]()
        let aliases = all("alias")
        if !aliases.isEmpty {
            let rows = aliases.map { a -> [String] in let d = decodeAlias(a); return [d.bus, d.id, a] }
            sections.append(ReportSection(id: "devices", title: L("対応するデバイス", "Supported Devices"), symbol: "cable.connector",
                blocks: [.table(TableData(columns: [L("接続方式", "Bus"), L("ID（ベンダー:デバイス）", "ID (vendor:device)"), L("元の指定", "Alias")], rows: rows))], count: aliases.count))
        }
        let parms = all("parm")
        if !parms.isEmpty {
            let types = Dictionary(all("parmtype").compactMap { p -> (String, String)? in
                guard let c = p.firstIndex(of: ":") else { return nil }
                return (String(p[..<c]), String(p[p.index(after: c)...]))
            }, uniquingKeysWith: { a, _ in a })
            let rows = parms.map { p -> [String] in
                let c = p.firstIndex(of: ":")
                let name = c.map { String(p[..<$0]) } ?? p
                return [name, types[name] ?? "", c.map { String(p[p.index(after: $0)...]) } ?? ""]
            }
            sections.append(ReportSection(id: "params", title: L("パラメーター", "Parameters"), symbol: "slider.horizontal.3",
                blocks: [.table(TableData(columns: [L("名前", "Name"), L("型", "Type"), L("説明", "Description")], rows: rows))], count: parms.count))
        }
        let fw = all("firmware")
        if !fw.isEmpty {
            sections.append(ReportSection(id: "firmware", title: L("必要なファームウェア", "Firmware Files"), symbol: "memorychip",
                blocks: [.table(TableData(columns: [L("ファイル", "File")], rows: fw.map { [$0] }))], count: fw.count))
        }
        let shown: Set<String> = ["alias", "parm", "parmtype", "firmware"]
        let rest = modinfo.filter { !shown.contains($0.0) }
        if !rest.isEmpty {
            sections.append(ReportSection(id: "modinfo", title: L("モジュール情報 (.modinfo)", "Module Info (.modinfo)"), symbol: "puzzlepiece",
                blocks: [.table(TableData(columns: [L("項目", "Key"), L("値", "Value")], rows: rest.map { [$0.0, $0.1] }))], count: rest.count))
        }
        return (sum, sections, badges)
    }

    /// Signature appended to a kernel module: "~Module signature appended~\n" preceded by a 12-byte trailer and the PKCS#7 blob.
    static func moduleSignature(_ r: Reader) -> (signer: String?, hash: String?)? {
        let magic = "~Module signature appended~\n"
        let n = r.count
        guard n > 40 + magic.utf8.count, r.fixedStr(n - magic.utf8.count, magic.utf8.count) == magic else { return nil }
        let t = n - magic.utf8.count - 12
        let hashAlgo = r.u8(t + 1)
        let sigLen = Int(r.be32(t + 8))
        let hashes = [2: "SHA-1", 4: "SHA-256", 5: "SHA-384", 6: "SHA-512", 7: "SHA-224"]
        guard sigLen > 0, sigLen < 1 << 20, t - sigLen > 0 else { return (nil, hashes[Int(hashAlgo)]) }
        let blob = r.bytes(t - sigLen, sigLen)
        // The signer is named in the PKCS#7 issuer field (certificates are usually not embedded).
        var signer = decodeCMS(blob)?.names.first
        if signer == nil, let cn = blob.range(of: Data([0x06, 0x03, 0x55, 0x04, 0x03])) {
            let b = [UInt8](blob)
            let i = cn.upperBound - blob.startIndex
            if i + 2 < b.count { let len = Int(b[i + 1]); if i + 2 + len <= b.count { signer = String(decoding: b[(i + 2)..<(i + 2 + len)], as: UTF8.self) } }
        }
        return (signer, hashes[Int(hashAlgo)])
    }
}
