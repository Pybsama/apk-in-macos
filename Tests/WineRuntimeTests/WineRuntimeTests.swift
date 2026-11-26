import AppKit
import Foundation
import ShelfKit
import Testing
import WineRuntime

@Test func peInspectorParsesPE64GUIExecutableAndDetectsArchitecture() {
    let pe = makeSyntheticPE64(machine: 0x8664, subsystem: 2)
    let info = PEInspector.inspectData(pe, sourcePath: "/tmp/Notepad2.exe", fallbackName: "Notepad2")
    #expect(info.architecture == "x86_64")
    #expect(info.isConsoleSubsystem == false)
    #expect(info.inputKind == .portableExe)
    #expect(info.incompatibilityReason == nil)
    #expect(info.displayName == "Notepad2")
}

@Test func peInspectorFlags16BitDOSAndWindowsARM64() {
    var dos = Data(repeating: 0, count: 128)
    dos[0] = 0x4D; dos[1] = 0x5A // MZ
    dos[0x3C] = 0x40             // e_lfanew -> NE/zeros, not PE\0\0
    let dosInfo = PEInspector.inspectData(dos, sourcePath: "/tmp/old.exe", fallbackName: "Old")
    #expect(dosInfo.architecture == "dos16")
    #expect(dosInfo.incompatibilityReason != nil)

    let arm = makeSyntheticPE64(machine: 0xAA64, subsystem: 2)
    let armInfo = PEInspector.inspectData(arm, sourcePath: "/tmp/armapp.exe", fallbackName: "ArmApp")
    #expect(armInfo.architecture == "arm64")
    #expect(armInfo.incompatibilityReason != nil)
}

@Test func peInspectorExtractsUTF16VersionStringsAndDetectsInstallers() {
    let blob = makeVersionInfoBlob(entries: [
        ("ProductName", "7-Zip"),
        ("FileDescription", "7-Zip Setup"),
        ("ProductVersion", "24.08"),
        ("CompanyName", "Igor Pavlov")
    ])
    let parsed = PEInspector.parseVersionInfo(blob)
    #expect(parsed["ProductName"] == "7-Zip")
    #expect(parsed["ProductVersion"] == "24.08")
    #expect(parsed["CompanyName"] == "Igor Pavlov")

    #expect(PEInspector.detectInstaller(fileName: "7z2408-x64-setup.exe", versionStrings: parsed, manifest: "") == true)
    #expect(PEInspector.detectInstaller(fileName: "myapp.exe", versionStrings: [:], manifest: "<description>Inno Setup</description>") == true)
    #expect(PEInspector.detectInstaller(fileName: "7zFM.exe", versionStrings: ["ProductName": "7-Zip"], manifest: "") == false)
    #expect(PEInspector.isAuxiliaryUninstallerOrUpdater(fileName: "unins000.exe") == true)
    #expect(PEInspector.isAuxiliaryUninstallerOrUpdater(fileName: "Notepad++.exe") == false)
}

@Test func peInspectorReconstructsICOFromGroupIconAndPNGPayload() throws {
    let img = NSImage(size: NSSize(width: 32, height: 32))
    img.lockFocus()
    NSColor.systemOrange.setFill()
    NSRect(x: 0, y: 0, width: 32, height: 32).fill()
    img.unlockFocus()
    let tiff = try #require(img.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))

    // GRPICONDIR with 1 entry pointing to RT_ICON #1
    var grp = Data([0, 0, 1, 0, 1, 0])
    grp.append(contentsOf: [32, 32, 0, 0, 1, 0, 32, 0])
    let sz = UInt32(png.count)
    grp.append(contentsOf: [UInt8(sz & 0xFF), UInt8((sz >> 8) & 0xFF), UInt8((sz >> 16) & 0xFF), UInt8((sz >> 24) & 0xFF)])
    grp.append(contentsOf: [1, 0]) // nID = 1

    let ico = try #require(PEInspector.buildICOData(groupBlobs: [grp], iconsById: [1: png]))
    let decoded = try #require(NSImage(data: ico))
    let decodedTIFF = try #require(decoded.tiffRepresentation)
    let decodedRep = try #require(NSBitmapImageRep(data: decodedTIFF))
    let centerColor = try #require(decodedRep.colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB))
    #expect(centerColor.redComponent > 0.75)
    #expect(centerColor.blueComponent < 0.35)
}

@Test func posixToWindowsZDrivePathConversion() {
    #expect(WineEngine.toWindowsPath("/tmp/bottle-tweaks.reg") == "Z:\\tmp\\bottle-tweaks.reg")
}

@Test func peInspectorDetectsNWJSGameFolderAndExtractsRealTitleAndIcon() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nwjs-detect-\(UUID().uuidString)", isDirectory: true)
    let gameDir = root.appendingPathComponent("Sample RPG - Windows", isDirectory: true)
    let iconDir = gameDir.appendingPathComponent("www/icon", isDirectory: true)
    let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    try fm.createDirectory(at: iconDir, withIntermediateDirectories: true)
    let exeURL = gameDir.appendingPathComponent("nw.exe")
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: exeURL)
    try Data("stub".utf8).write(to: gameDir.appendingPathComponent("nw.dll"))

    let pkgJSON = """
    {
      "name": "samplerpg",
      "main": "www/index.html",
      "window": { "title": "Sample RPG", "icon": "www/icon/icon.png" }
    }
    """
    try Data(pkgJSON.utf8).write(to: gameDir.appendingPathComponent("package.json"))

    let img = NSImage(size: NSSize(width: 16, height: 16))
    img.lockFocus()
    NSColor.systemPurple.setFill()
    NSRect(x: 0, y: 0, width: 16, height: 16).fill()
    img.unlockFocus()
    let tiff = try #require(img.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let pngData = try #require(rep.representation(using: .png, properties: [:]))
    try pngData.write(to: iconDir.appendingPathComponent("icon.png"))

    let info = PEInspector.inspect(path: exeURL.path, iconCacheDir: cacheDir)
    #expect(info.recommendedBackend == .nativeNWJS)
    #expect(info.displayName == "Sample RPG")
    #expect(info.iconPath != nil)
}

@Test func peInspectorDetectsLegacyRPGMakerMVAndMZAndElectronApps() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("fw-detect-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    // 1. Legacy RPG Maker MV (nw.pak + www/package.json, no nw.dll)
    let mvDir = root.appendingPathComponent("ClassicMV - Win64", isDirectory: true)
    let mvWww = mvDir.appendingPathComponent("www", isDirectory: true)
    try fm.createDirectory(at: mvWww, withIntermediateDirectories: true)
    let mvExe = mvDir.appendingPathComponent("Game.exe")
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: mvExe)
    try Data("pak".utf8).write(to: mvDir.appendingPathComponent("nw.pak"))
    try Data(#"{"name":"classicmv","main":"index.html"}"#.utf8).write(to: mvWww.appendingPathComponent("package.json"))

    let mvInfo = PEInspector.inspect(path: mvExe.path, iconCacheDir: nil)
    #expect(mvInfo.recommendedBackend == .nativeNWJS)
    #expect(mvInfo.recommendedWorkingDir == mvWww.path)
    #expect(mvInfo.displayName == "ClassicMV")

    // 2. RPG Maker MZ (js/rmmz_core.js + root package.json)
    let mzDir = root.appendingPathComponent("ModernMZ", isDirectory: true)
    try fm.createDirectory(at: mzDir.appendingPathComponent("js", isDirectory: true), withIntermediateDirectories: true)
    let mzExe = mzDir.appendingPathComponent("Game.exe")
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: mzExe)
    try Data("// mz".utf8).write(to: mzDir.appendingPathComponent("js/rmmz_core.js"))
    try Data(#"{"name":"modernmz","main":"index.html"}"#.utf8).write(to: mzDir.appendingPathComponent("package.json"))

    let mzInfo = PEInspector.inspect(path: mzExe.path, iconCacheDir: nil)
    #expect(mzInfo.recommendedBackend == .nativeNWJS)
    #expect(mzInfo.displayName == "ModernMZ")

    // 3. Electron Win32 app (chrome_elf.dll + resources/app/package.json)
    let elDir = root.appendingPathComponent("DesktopApp", isDirectory: true)
    try fm.createDirectory(at: elDir.appendingPathComponent("resources/app", isDirectory: true), withIntermediateDirectories: true)
    let elExe = elDir.appendingPathComponent("Electron.exe")
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: elExe)
    try Data("elf".utf8).write(to: elDir.appendingPathComponent("chrome_elf.dll"))
    try Data(#"{"productName":"My Notes"}"#.utf8).write(to: elDir.appendingPathComponent("resources/app/package.json"))

    let elInfo = PEInspector.inspect(path: elExe.path, iconCacheDir: nil)
    #expect(elInfo.recommendedBackend == .wine)
    #expect(elInfo.displayName == "My Notes")
    #expect(elInfo.recommendedArguments.contains("--in-process-gpu"))
}

@Test func peInspectorOptimizesUnityRPGMakerVXAceAndRenPyGames() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("rpg-detect-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    // 1. Unity RPG -> forces -force-d3d11 for DXVK Metal acceleration
    let unityDir = root.appendingPathComponent("StarlightRPG - Windows", isDirectory: true)
    try fm.createDirectory(at: unityDir.appendingPathComponent("Game_Data", isDirectory: true), withIntermediateDirectories: true)
    let unityExe = unityDir.appendingPathComponent("Game.exe")
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: unityExe)
    try Data("unity".utf8).write(to: unityDir.appendingPathComponent("UnityPlayer.dll"))

    let unityInfo = PEInspector.inspect(path: unityExe.path, iconCacheDir: nil)
    #expect(unityInfo.recommendedBackend == .wine)
    #expect(unityInfo.displayName == "StarlightRPG")
    #expect(unityInfo.recommendedArguments.contains("-force-d3d11"))

    // 2. Classic RPG Maker VX Ace (Japanese) -> reads Game.ini Title & auto-selects ja_JP locale
    let vxDir = root.appendingPathComponent("JP_VXAce", isDirectory: true)
    try fm.createDirectory(at: vxDir, withIntermediateDirectories: true)
    let vxExe = vxDir.appendingPathComponent("Game.exe")
    try makeSyntheticPE64(machine: 0x014C, subsystem: 2).write(to: vxExe)
    try Data("rgss".utf8).write(to: vxDir.appendingPathComponent("RGSS301.dll"))
    try Data("[Game]\r\nRTP=RPGVXAce\r\nTitle=勇者の冒険\r\n".utf8).write(to: vxDir.appendingPathComponent("Game.ini"))

    let vxInfo = PEInspector.inspect(path: vxExe.path, iconCacheDir: nil)
    #expect(vxInfo.recommendedBackend == .wine)
    #expect(vxInfo.displayName == "勇者の冒険")
    #expect(vxInfo.recommendedLocale == .jaJP)

    // 3. Ren'Py RPG
    let rpDir = root.appendingPathComponent("ChronicleVN - PC", isDirectory: true)
    try fm.createDirectory(at: rpDir.appendingPathComponent("renpy", isDirectory: true), withIntermediateDirectories: true)
    try fm.createDirectory(at: rpDir.appendingPathComponent("game", isDirectory: true), withIntermediateDirectories: true)
    let rpExe = rpDir.appendingPathComponent("Game.exe")
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: rpExe)

    let rpInfo = PEInspector.inspect(path: rpExe.path, iconCacheDir: nil)
    #expect(rpInfo.recommendedBackend == .wine)
    #expect(rpInfo.displayName == "ChronicleVN")
}

@Test func archiveResolverExtractsShiftJISZipAndFindsPrimaryGameExecutable() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("zip-sjis-\(UUID().uuidString)", isDirectory: true)
    let destRoot = root.appendingPathComponent("out", isDirectory: true)
    let zipURL = root.appendingPathComponent("game.zip")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    // Create a Shift-JIS (CP932, bit 11 UTF-8 flag NOT set) archive containing a nested folder,
    // auxiliary exes (unins000.exe, notification_helper.exe), and the primary NW.js game.exe.
    let exeStub = makeSyntheticPE64(machine: 0x8664, subsystem: 2)
    let exeHex = exeStub.map { String(format: "%02x", $0) }.joined()
    let pyMakeZip = """
    import io, sys, zipfile
    zip_path, exe_hex = sys.argv[1], sys.argv[2]
    exe_bytes = bytes.fromhex(exe_hex)
    sjis_folder = '魔法少女'.encode('cp932')
    placeholder = b'A' * len(sjis_folder)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as zf:
        for rel, data in [
            ('unins000.exe', exe_bytes),
            ('notification_helper.exe', exe_bytes),
            ('nw.dll', b'nw'),
            ('package.json', b'{"name":"mahou","main":"www/index.html"}'),
            ('Game.exe', exe_bytes),
        ]:
            zf.writestr(f"{placeholder.decode('ascii')}/{rel}", data)
    raw_zip = buf.getvalue().replace(placeholder + b'/', sjis_folder + b'/')
    with open(zip_path, 'wb') as f:
        f.write(raw_zip)
    """
    let mkRes = try await ShellCommand.run("/usr/bin/python3", args: ["-c", pyMakeZip, zipURL.path, exeHex], timeout: 20)
    #expect(mkRes.ok)

    let extracted = try await ArchiveAndFolderResolver.extractZipWithSmartEncoding(zipURL: zipURL, into: destRoot)
    #expect(extracted.lastPathComponent == "魔法少女")
    #expect(fm.fileExists(atPath: extracted.appendingPathComponent("Game.exe").path))

    let picked = ArchiveAndFolderResolver.findPrimaryExecutable(in: extracted)
    #expect(picked?.lastPathComponent == "Game.exe")
}

@Test func archiveResolverRejectsZipSlipTraversal() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("zip-slip-\(UUID().uuidString)", isDirectory: true)
    let destRoot = root.appendingPathComponent("out", isDirectory: true)
    let zipURL = root.appendingPathComponent("evil.zip")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let py = """
    import sys, zipfile
    with zipfile.ZipFile(sys.argv[1], 'w') as zf:
        zf.writestr('../../evil.txt', 'nope')
    """
    let mkRes = try await ShellCommand.run("/usr/bin/python3", args: ["-c", py, zipURL.path], timeout: 20)
    #expect(mkRes.ok)

    var threw = false
    do {
        _ = try await ArchiveAndFolderResolver.extractZipWithSmartEncoding(zipURL: zipURL, into: destRoot)
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func wineExitDiagnosticsRecognizesCommonFailuresAndIgnoresNormalExits() {
    let okExit = WineExitReport(exitCode: 0, duration: 1.0, logDelta: "vcruntime140.dll")
    #expect(WineEngine.diagnoseExit(okExit, appName: "Demo") == nil)

    let longExit = WineExitReport(exitCode: 1, duration: 25.0, logDelta: "vcruntime140.dll")
    #expect(WineEngine.diagnoseExit(longExit, appName: "Demo") == nil)

    let vcErr = WineExitReport(exitCode: 53, duration: 1.2, logDelta: "err:module:import_dll Library vcruntime140_1.dll not found")
    #expect(WineEngine.diagnoseExit(vcErr, appName: "Demo")?.contains("VC++") == true)

    let rtpErr = WineExitReport(exitCode: 1, duration: 0.8, logDelta: "RGSS-RTP standard not found")
    #expect(WineEngine.diagnoseExit(rtpErr, appName: "Demo")?.contains("RTP") == true)

    let dx12Err = WineExitReport(exitCode: 1, duration: 0.9, logDelta: "Failed to initialize Direct3D 12 device")
    #expect(WineEngine.diagnoseExit(dx12Err, appName: "Demo")?.contains("DirectX 12") == true)
}

@Test func wineShortcutBuilderGeneratesSignedMacAppForDeepLink() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wine-shortcut-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let item = WindowsAppItem(
        id: "notepad2-1a2b3c4d",
        appName: "Notepad2",
        executablePath: "/tmp/Notepad2.exe",
        versionName: "4.2.25"
    )
    let appURL = try await WineShortcutBuilder.createMacAppShortcut(
        for: item,
        hostAppPath: "/Applications/EXEInMacOS.app",
        in: tmp
    )
    #expect(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path))
    #expect(FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
    let script = try String(contentsOf: appURL.appendingPathComponent("Contents/MacOS/open-app"), encoding: .utf8)
    #expect(script.contains("exeinmacos://open?id=notepad2-1a2b3c4d"))
}

@Test func wineEngineStagesDownloadsCopyIntoManagedShelfApps() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wine-engine-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let engine = WineEngine(dataRoot: root)
    try await engine.ensureFolders()

    // Put a synthetic .exe directly in /tmp (a transient drop folder)
    let srcURL = URL(fileURLWithPath: "/tmp/PortableCalc-\(UUID().uuidString).exe")
    defer { try? FileManager.default.removeItem(at: srcURL) }
    try makeSyntheticPE64(machine: 0x8664, subsystem: 2).write(to: srcURL)

    let info = await engine.inspectExecutable(srcURL.path)
    let staged = try await engine.stagePortableExecutable(info)
    #expect(staged.executablePath.contains("/drive_c/ShelfApps/"))
    #expect(FileManager.default.fileExists(atPath: staged.executablePath))
}

// MARK: - Synthetic PE & VS_VERSIONINFO Builders

private func makeSyntheticPE64(machine: UInt16, subsystem: UInt16) -> Data {
    var d = Data(repeating: 0, count: 512)
    d[0] = 0x4D; d[1] = 0x5A // MZ
    d[0x3C] = 0x80           // e_lfanew = 0x80

    // PE\0\0
    d[0x80] = 0x50; d[0x81] = 0x45; d[0x82] = 0; d[0x83] = 0
    // COFF Header at 0x84
    putU16(&d, 0x84, machine)
    putU16(&d, 0x86, 0)      // 0 sections
    putU16(&d, 0x94, 240)    // SizeOfOptionalHeader (PE32+)

    // Optional Header at 0x98
    putU16(&d, 0x98, 0x020B) // PE32+
    putU16(&d, 0x98 + 68, subsystem)
    return d
}

private func makeVersionInfoBlob(entries: [(String, String)]) -> Data {
    var stringNodes = Data()
    for (k, v) in entries {
        stringNodes.align4()
        var node = Data([0, 0, 0, 0, 1, 0]) // wLength, wValueLength (chars), wType=1
        node.appendUTF16Z(k)
        node.align4()
        let valChars = UInt16(v.utf16.count + 1)
        node.appendUTF16Z(v)
        putU16(&node, 0, UInt16(node.count))
        putU16(&node, 2, valChars)
        stringNodes.append(node)
    }

    // StringTable "040904B0"
    var st = Data([0, 0, 0, 0, 1, 0])
    st.appendUTF16Z("040904B0")
    st.align4()
    st.append(stringNodes)
    putU16(&st, 0, UInt16(st.count))

    // StringFileInfo
    var sfi = Data([0, 0, 0, 0, 1, 0])
    sfi.appendUTF16Z("StringFileInfo")
    sfi.align4()
    sfi.append(st)
    putU16(&sfi, 0, UInt16(sfi.count))

    // Root VS_VERSION_INFO
    var root = Data([0, 0, 0, 0, 0, 0])
    root.appendUTF16Z("VS_VERSION_INFO")
    root.align4()
    root.append(sfi)
    putU16(&root, 0, UInt16(root.count))
    return root
}

private func putU16(_ d: inout Data, _ offset: Int, _ v: UInt16) {
    d[offset] = UInt8(v & 0xFF)
    d[offset + 1] = UInt8((v >> 8) & 0xFF)
}

private extension Data {
    mutating func appendUTF16Z(_ s: String) {
        for u in s.utf16 {
            append(UInt8(u & 0xFF))
            append(UInt8((u >> 8) & 0xFF))
        }
        append(contentsOf: [0, 0])
    }

    mutating func align4() {
        while count % 4 != 0 { append(0) }
    }
}
