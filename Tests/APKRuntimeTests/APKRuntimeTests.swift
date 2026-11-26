import APKRuntime
import Foundation
import Testing

@Test func badgingParserExtractsChineseLabelAndHighestDensityIcon() throws {
    let raw = """
    package: name='dev.example.notes' versionCode='7' versionName='1.4.0'
    application-label:'Notes'
    application-label-zh-CN:'随手记'
    application-icon-240:'res/mipmap-hdpi/ic_launcher.png'
    application-icon-640:'res/mipmap-xxxhdpi/ic_launcher.png'
    launchable-activity: name='dev.example.notes.MainActivity' label='' icon=''
    native-code: 'arm64-v8a'
    """

    let parsed = try APKParser.parseBadging(raw)
    #expect(parsed.packageName == "dev.example.notes")
    #expect(parsed.appName == "随手记")
    #expect(parsed.versionName == "1.4.0")
    #expect(parsed.launchableActivity == "dev.example.notes.MainActivity")
    #expect(parsed.rasterIcons.max(by: { $0.density < $1.density })?.entryPath == "res/mipmap-xxxhdpi/ic_launcher.png")
}

@Test func arm64CompatibilityCheckFlagsNonArm64() {
    let ok = APKPackageInfo(
        apkPath: "/tmp/ok.apk", packageName: "a.b", appName: "OK",
        versionName: "1", versionCode: "1", launchableActivity: ".Main",
        nativeABIs: ["arm64-v8a"], iconPath: nil
    )
    #expect(ok.isARM64Supported)
    #expect(ok.incompatibilityReason == nil)

    let bad = APKPackageInfo(
        apkPath: "/tmp/x86.apk", packageName: "a.c", appName: "X86",
        versionName: "1", versionCode: "1", launchableActivity: ".Main",
        nativeABIs: ["x86_64"], iconPath: nil
    )
    #expect(!bad.isARM64Supported)
    #expect(bad.incompatibilityReason != nil)
}

@Test func annexBScannerSplits3And4ByteStartCodes() {
    let stream: [UInt8] = [
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E,
        0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84
    ]
    let units = AnnexBScanner.splitNALUs(Data(stream))
    #expect(units.count == 3)
    #expect(AnnexBScanner.unitType(units[0]) == 7)
    #expect(AnnexBScanner.unitType(units[1]) == 8)
    #expect(AnnexBScanner.unitType(units[2]) == 5)
}

@Test func keyMapTranslatesSpecialKeys() {
    #expect(KeyMap.specialKey(forMacCode: 36) == AndroidKey.enter)
    #expect(KeyMap.specialKey(forMacCode: 51) == AndroidKey.backspace)
    #expect(KeyMap.specialKey(forMacCode: 53) == AndroidKey.back)
    #expect(KeyMap.specialKey(forMacCode: 0) == nil)
}

@Test func localizationFollowsSelectedLanguage() {
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: AppLanguage.defaultsKey)
    defer {
        if let previous { defaults.set(previous, forKey: AppLanguage.defaultsKey) }
        else { defaults.removeObject(forKey: AppLanguage.defaultsKey) }
    }

    defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
    #expect(L10n.t("安装失败", "Install failed") == "Install failed")
    #expect(SizePreset.all.first?.label == "Portrait")

    defaults.set(AppLanguage.chinese.rawValue, forKey: AppLanguage.defaultsKey)
    #expect(L10n.t("安装失败", "Install failed") == "安装失败")
    #expect(SizePreset.all.first?.label == "标准竖屏")
}

@Test func shortcutBuilderGeneratesSignedMacApp() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-shortcut-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let item = AndroidAppItem(packageName: "dev.demo.counter", appName: "Counter Demo", versionName: "1.0.0", versionCode: "1")
    let appURL = try await ShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: "/Applications/APKInMacOS.app", in: tmp)

    #expect(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path))
    #expect(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
    #expect(FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/open-app").path))
    let script = try String(contentsOf: appURL.appendingPathComponent("Contents/MacOS/open-app"), encoding: .utf8)
    #expect(script.contains("apkinmacos://open?pkg=dev.demo.counter"))
}

@Test func packageListParsingAndSlimListKeepsEssentials() {
    let out = "package:com.google.android.gms\r\npackage:com.google.android.as\n\nnoise\npackage:net.gsantner.markor\n"
    #expect(SandboxEngine.packageSet(out) == ["com.google.android.gms", "com.google.android.as", "net.gsantner.markor"])
    // Packages that apps depend on must never be in the slim list.
    for essential in ["com.google.android.gms", "com.google.android.webview", "com.android.chrome",
                      "com.google.android.inputmethod.latin", "com.google.android.apps.nexuslauncher"] {
        #expect(!RuntimeSettings.slimPackages.contains(essential))
    }
}

@Test func memorySettingFallsBackToDefaultForUnknownValues() {
    let key = RuntimeSettings.memoryKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(1234, forKey: key)
    #expect(RuntimeSettings.memoryMB == RuntimeSettings.defaultMemoryMB)
    RuntimeSettings.memoryMB = 4096
    #expect(RuntimeSettings.memoryMB == 4096)
}

@Test func splitAPKFilterDropsIncompatibleABIsAndKeepsARM64AndResources() {
    let inputs = [
        "/tmp/x/base.apk",
        "/tmp/x/split_config.arm64_v8a.apk",
        "/tmp/x/split_config.armeabi_v7a.apk",
        "/tmp/x/split_config.x86.apk",
        "/tmp/x/split_config.x86_64.apk",
        "/tmp/x/split_config.xxhdpi.apk",
        "/tmp/x/split_config.zh.apk"
    ]
    let kept = APKParser.filterCompatibleSplitAPKs(inputs).map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(kept == [
        "base.apk",
        "split_config.arm64_v8a.apk",
        "split_config.xxhdpi.apk",
        "split_config.zh.apk"
    ])
}
