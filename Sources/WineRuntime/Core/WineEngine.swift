import AppKit
import CryptoKit
import Foundation

public struct WinePaths: Sendable, Equatable {
    public let wineBinary: String
    public let wineserverBinary: String
    public let binDir: String

    public init(wineBinary: String, wineserverBinary: String, binDir: String) {
        self.wineBinary = wineBinary
        self.wineserverBinary = wineserverBinary
        self.binDir = binDir
    }
}

public struct WineExitReport: Sendable, Equatable {
    public let exitCode: Int32
    public let duration: TimeInterval
    public let logDelta: String

    public init(exitCode: Int32, duration: TimeInterval, logDelta: String) {
        self.exitCode = exitCode
        self.duration = duration
        self.logDelta = logDelta
    }
}

/// Manages Windows app execution under `~/Library/Application Support/EXEInMacOS/`:
/// - NW.js / RPG Maker MV·MZ / HTML5 Windows games run **natively** on Apple Silicon Metal
///   via `nwjs-osx-arm64` (60 FPS, <1% idle CPU, native CoreText CJK & macOS keyboard).
/// - Standard Win32 / DirectX `.exe` apps run via Wine Stable 11.0 + DXVK-macOS (Metal 3)
///   with `Arial Unicode.ttf` registered for DirectWrite CJK rendering.
public actor WineEngine {
    nonisolated public let dataRoot: URL
    nonisolated public let runtimeDir: URL
    nonisolated public let nwjsDir: URL
    nonisolated public let nwjsProfilesDir: URL
    nonisolated public let nwjsWrappersDir: URL
    nonisolated public let prefixDir: URL
    nonisolated public let driveCDir: URL
    nonisolated public let shelfAppsDir: URL
    nonisolated public let extractedDir: URL
    nonisolated public let iconsDir: URL
    nonisolated public let shelfStoreURL: URL
    nonisolated public let logURL: URL

    private var cachedPaths: WinePaths?
    private var cachedNWJSBinary: String?
    private var runningProcs: [String: [Process]] = [:]

    public init(dataRoot: URL? = nil) {
        let base = dataRoot ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/EXEInMacOS", isDirectory: true)
        self.dataRoot = base
        self.runtimeDir = base.appendingPathComponent("runtime", isDirectory: true)
        self.nwjsDir = base.appendingPathComponent("nwjs-arm64", isDirectory: true)
        self.nwjsProfilesDir = base.appendingPathComponent("nwjs-profiles", isDirectory: true)
        self.nwjsWrappersDir = base.appendingPathComponent("nwjs-wrappers", isDirectory: true)
        self.prefixDir = base.appendingPathComponent("prefix", isDirectory: true)
        self.driveCDir = prefixDir.appendingPathComponent("drive_c", isDirectory: true)
        self.shelfAppsDir = driveCDir.appendingPathComponent("ShelfApps", isDirectory: true)
        self.extractedDir = base.appendingPathComponent("extracted", isDirectory: true)
        self.iconsDir = base.appendingPathComponent("icons", isDirectory: true)
        self.shelfStoreURL = base.appendingPathComponent("shelf.json")
        self.logURL = base.appendingPathComponent("wine.log")
    }

    public func ensureFolders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: nwjsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefixDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)
    }

    // MARK: - Discovery & Readiness

    public static func discoverWine(in managedRuntimeDir: URL) -> WinePaths? {
        let fm = FileManager.default
        var candidates: [String] = []

        if let override = ProcessInfo.processInfo.environment["WINE_BIN"], !override.isEmpty {
            candidates.append(override)
        }

        let appNames = ["Wine Stable.app", "Wine Devel.app", "Wine Staging.app"]
        let searchRoots = [
            managedRuntimeDir.path,
            "/Applications",
            "\(NSHomeDirectory())/Applications"
        ]
        for root in searchRoots {
            for app in appNames {
                candidates.append("\(root)/\(app)/Contents/Resources/wine/bin/wine")
                candidates.append("\(root)/\(app)/Contents/Resources/wine/bin/wine64")
            }
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/wine",
            "/opt/homebrew/bin/wine64",
            "/usr/local/bin/wine",
            "/usr/local/bin/wine64"
        ])

        for bin in candidates where fm.isExecutableFile(atPath: bin) {
            let binDir = URL(fileURLWithPath: bin).deletingLastPathComponent().path
            let server = "\(binDir)/wineserver"
            let resolvedServer = fm.isExecutableFile(atPath: server) ? server : bin
            return WinePaths(wineBinary: bin, wineserverBinary: resolvedServer, binDir: binDir)
        }
        return nil
    }

    public static func discoverNWJS(in nwjsRoot: URL) -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["NWJS_BIN"], fm.isExecutableFile(atPath: override) {
            return override
        }
        let direct = nwjsRoot
            .appendingPathComponent("nwjs-v\(WineDownloader.nwjsVersion)-osx-arm64/nwjs.app/Contents/MacOS/nwjs")
            .path
        if fm.isExecutableFile(atPath: direct) {
            return direct
        }
        if let entries = try? fm.contentsOfDirectory(at: nwjsRoot, includingPropertiesForKeys: nil) {
            for item in entries {
                let candidate = item.appendingPathComponent("nwjs.app/Contents/MacOS/nwjs").path
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    public func hasLocalWine() -> Bool {
        if cachedPaths != nil { return true }
        if let found = Self.discoverWine(in: runtimeDir) {
            cachedPaths = found
            return true
        }
        return false
    }

    public func hasLocalNWJS() -> Bool {
        if cachedNWJSBinary != nil { return true }
        if let found = Self.discoverNWJS(in: nwjsDir) {
            cachedNWJSBinary = found
            return true
        }
        return false
    }

    public func isBottleInitialized() -> Bool {
        FileManager.default.fileExists(atPath: prefixDir.appendingPathComponent("system.reg").path)
    }

    public func checkRosetta() async throws {
        #if arch(arm64)
        let res = try? await ShellCommand.run("/usr/bin/arch", args: ["-x86_64", "/usr/bin/true"], timeout: 8)
        guard res?.ok == true else {
            throw WineRuntimeError.rosettaRequired
        }
        #endif
    }

    public func prepareNWJSEnvironment(
        onStage: @escaping @Sendable (WineSandboxState) -> Void
    ) async throws -> String {
        try ensureFolders()
        if let existing = cachedNWJSBinary ?? Self.discoverNWJS(in: nwjsDir) {
            cachedNWJSBinary = existing
            return "NW.js \(WineDownloader.nwjsVersion) ARM64"
        }

        try await WineDownloader.installNWJSRuntime(into: nwjsDir) { progress in
            onStage(.downloadingRuntime(progressText: progress))
        }
        guard let installed = Self.discoverNWJS(in: nwjsDir) else {
            throw WineRuntimeError.nwjsNotFound
        }
        cachedNWJSBinary = installed
        return "NW.js \(WineDownloader.nwjsVersion) ARM64"
    }

    /// Ensures Rosetta 2, Wine runtime (auto-downloading on first use if needed), and the
    /// isolated Windows bottle (including DXVK Metal acceleration & CJK fonts) are ready.
    public func prepareEnvironment(
        onStage: @escaping @Sendable (WineSandboxState) -> Void
    ) async throws -> String {
        try ensureFolders()
        try await checkRosetta()

        let paths: WinePaths
        if let existing = cachedPaths ?? Self.discoverWine(in: runtimeDir) {
            cachedPaths = existing
            paths = existing
        } else {
            try await WineDownloader.installWineRuntime(into: runtimeDir) { progress in
                onStage(.downloadingRuntime(progressText: progress))
            }
            guard let installed = Self.discoverWine(in: runtimeDir) else {
                throw WineRuntimeError.wineNotFound
            }
            cachedPaths = installed
            paths = installed
        }

        let markerURL = prefixDir.appendingPathComponent(".exeinmacos-bottle-v3")
        if !isBottleInitialized() || !FileManager.default.fileExists(atPath: markerURL.path) {
            onStage(.initializingBottle)
            try await initializeBottle(paths: paths, markerURL: markerURL)
        }

        let ver = await queryWineVersion(paths: paths)
        return ver
    }

    private func queryWineVersion(paths: WinePaths) async -> String {
        if let res = try? await runWineCommand(paths: paths, args: ["--version"], timeout: 10), res.ok {
            let trimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "wine-\(WineDownloader.releaseVersion)"
    }

    private func initializeBottle(paths: WinePaths, markerURL: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: prefixDir, withIntermediateDirectories: true)

        if !isBottleInitialized() {
            let bootRes = try await runWineCommand(
                paths: paths,
                args: ["wineboot", "-u"],
                extraEnv: ["WINEDLLOVERRIDES": "winemenubuilder.exe=d;mscoree=d;mshtml=d"],
                timeout: 180
            )
            if !bootRes.ok && !fm.fileExists(atPath: prefixDir.appendingPathComponent("system.reg").path) {
                let detail = (bootRes.stderr + "\n" + bootRes.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                throw WineRuntimeError.prefixInitFailed(detail)
            }
        }

        try fm.createDirectory(at: shelfAppsDir, withIntermediateDirectories: true)
        installCJKFontsIntoBottle()
        let dxvkInstalled: Bool
        if WineRuntimeSettings.dxvkEnabled {
            dxvkInstalled = await WineDownloader.installDXVKIfPossible(into: driveCDir)
        } else {
            dxvkInstalled = false
        }
        await applyBottleRegistryTweaks(
            paths: paths,
            retinaEnabled: WineRuntimeSettings.retinaModeEnabled,
            dxvkEnabled: dxvkInstalled && WineRuntimeSettings.dxvkEnabled
        )
        await waitWineServer(paths: paths)
        try? Data("ok\n".utf8).write(to: markerURL, options: .atomic)
    }

    private func installCJKFontsIntoBottle() {
        let fm = FileManager.default
        let fontsDir = driveCDir.appendingPathComponent("windows/Fonts", isDirectory: true)
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // Copy (or link) Arial Unicode.ttf as a pure TrueType .ttf file so both GDI and
        // DirectWrite (`dwrite.dll`) resolve full Simplified/Traditional Chinese, Japanese, and Korean.
        let arialUnicode = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
        let arialDest = fontsDir.appendingPathComponent("ArialUnicode.ttf")
        if fm.fileExists(atPath: arialUnicode), !fm.fileExists(atPath: arialDest.path) {
            try? fm.createSymbolicLink(atPath: arialDest.path, withDestinationPath: arialUnicode)
        }

        let extraFonts = [
            "/System/Library/Fonts/STHeiti Medium.ttc",
            "/System/Library/Fonts/Supplemental/Songti.ttc"
        ]
        for src in extraFonts where fm.fileExists(atPath: src) {
            let dst = fontsDir.appendingPathComponent(URL(fileURLWithPath: src).lastPathComponent)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.createSymbolicLink(atPath: dst.path, withDestinationPath: src)
            }
        }
    }

    private func applyBottleRegistryTweaks(paths: WinePaths, retinaEnabled: Bool, dxvkEnabled: Bool) async {
        let retinaVal = retinaEnabled ? "Y" : "N"
        let d3dOverride = dxvkEnabled ? "\"d3d11\"=\"native,builtin\"\n\"d3d10core\"=\"native,builtin\"" : "\"d3d11\"=-\n\"d3d10core\"=-"
        let regContent = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(retinaVal)"

        [HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]
        \(d3dOverride)

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "FontSmoothing"="2"
        "FontSmoothingType"=dword:00000002

        [HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]
        "Arial Unicode MS (TrueType)"="ArialUnicode.ttf"

        [HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]
        "Microsoft YaHei"="Arial Unicode MS"
        "Microsoft YaHei UI"="Arial Unicode MS"
        "Microsoft JhengHei"="Arial Unicode MS"
        "SimHei"="Arial Unicode MS"
        "SimSun"="Arial Unicode MS"
        "NSimSun"="Arial Unicode MS"
        "PMingLiU"="Arial Unicode MS"
        "MingLiU"="Arial Unicode MS"
        "KaiTi"="Arial Unicode MS"
        "FangSong"="Arial Unicode MS"
        "DengXian"="Arial Unicode MS"
        "MS Gothic"="Arial Unicode MS"
        "MS PGothic"="Arial Unicode MS"
        "MS Mincho"="Arial Unicode MS"
        "MS PMincho"="Arial Unicode MS"
        "Meiryo"="Arial Unicode MS"
        "Meiryo UI"="Arial Unicode MS"
        "Yu Gothic"="Arial Unicode MS"
        "Yu Mincho"="Arial Unicode MS"
        "VL Gothic"="Arial Unicode MS"
        "VL PGothic"="Arial Unicode MS"
        "Noto Sans CJK SC"="Arial Unicode MS"
        "Noto Sans CJK JP"="Arial Unicode MS"
        "Malgun Gothic"="Arial Unicode MS"
        "宋体"="Arial Unicode MS"
        "新宋体"="Arial Unicode MS"
        "黑体"="Arial Unicode MS"
        "微软雅黑"="Arial Unicode MS"
        "楷体"="Arial Unicode MS"
        "仿宋"="Arial Unicode MS"
        "ＭＳ ゴシック"="Arial Unicode MS"
        "ＭＳ Ｐゴシック"="Arial Unicode MS"
        "ＭＳ 明朝"="Arial Unicode MS"
        "メイリオ"="Arial Unicode MS"
        "游ゴシック"="Arial Unicode MS"

        [HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink]
        "Tahoma"="ArialUnicode.ttf,Arial Unicode MS"
        "Microsoft Sans Serif"="ArialUnicode.ttf,Arial Unicode MS"
        "Segoe UI"="ArialUnicode.ttf,Arial Unicode MS"
        "Lucida Sans Unicode"="ArialUnicode.ttf,Arial Unicode MS"
        "SourceSerifPro-Bold"="ArialUnicode.ttf,Arial Unicode MS"

        """
        let tmpReg = dataRoot.appendingPathComponent("bottle-tweaks.reg")
        defer { try? FileManager.default.removeItem(at: tmpReg) }
        guard let data = regContent.data(using: .utf8),
              (try? data.write(to: tmpReg, options: .atomic)) != nil else { return }

        _ = try? await runWineCommand(paths: paths, args: ["regedit", "/S", Self.toWindowsPath(tmpReg.path)], timeout: 30)
    }

    public static func toWindowsPath(_ posixPath: String) -> String {
        "Z:" + posixPath.replacingOccurrences(of: "/", with: "\\")
    }

    private func waitWineServer(paths: WinePaths) async {
        let inv = buildServerInvocation(paths: paths, args: ["-w"])
        _ = try? await ShellCommand.run(
            inv.executable,
            args: inv.arguments,
            env: buildEnvironment(paths: paths, extra: [:]),
            timeout: 20
        )
    }

    public func applyGraphicsSettings(retinaEnabled: Bool, dxvkEnabled: Bool) async {
        guard let paths = cachedPaths ?? Self.discoverWine(in: runtimeDir), isBottleInitialized() else { return }
        var hasDXVK = FileManager.default.fileExists(atPath: driveCDir.appendingPathComponent("windows/.dxvk-macos-1.10.3").path)
        if dxvkEnabled && !hasDXVK {
            hasDXVK = await WineDownloader.installDXVKIfPossible(into: driveCDir)
        }
        await applyBottleRegistryTweaks(paths: paths, retinaEnabled: retinaEnabled, dxvkEnabled: dxvkEnabled && hasDXVK)
        await waitWineServer(paths: paths)
    }

    // MARK: - Inspect, Stage, Install & Launch

    /// Resolves a dropped `.exe`, `.msi`, folder, or `.zip` archive into a launchable `.exe`/`.msi`.
    public func resolveDroppedInput(_ url: URL) async throws -> URL {
        try ensureFolders()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            guard let found = ArchiveAndFolderResolver.findPrimaryExecutable(in: url) else {
                throw WineRuntimeError.noExecutableInFolder(url.lastPathComponent)
            }
            return found
        }
        if url.pathExtension.lowercased() == "zip" {
            let extractedFolder = try await ArchiveAndFolderResolver.extractZipWithSmartEncoding(zipURL: url, into: extractedDir)
            guard let found = ArchiveAndFolderResolver.findPrimaryExecutable(in: extractedFolder) else {
                throw WineRuntimeError.noExecutableInFolder(url.lastPathComponent)
            }
            return found
        }
        return url
    }

    public func installVCRedistRuntime(
        onStage: @escaping @Sendable (WineSandboxState) -> Void
    ) async throws {
        _ = try await prepareEnvironment(onStage: onStage)
        guard let paths = cachedPaths ?? Self.discoverWine(in: runtimeDir) else {
            throw WineRuntimeError.wineNotFound
        }
        onStage(.initializingBottle)
        let installerURL = try await WineDownloader.downloadVCRedistX64 { progress in
            onStage(.downloadingRuntime(progressText: progress))
        }
        defer { try? FileManager.default.removeItem(at: installerURL) }

        onStage(.initializingBottle)
        _ = try await runWineCommand(
            paths: paths,
            args: [Self.toWindowsPath(installerURL.path), "/install", "/quiet", "/norestart"],
            timeout: 240
        )
        await waitWineServer(paths: paths)
    }

    public func inspectExecutable(_ path: String) -> PEExecutableInfo {
        try? ensureFolders()
        return PEInspector.inspect(path: path, iconCacheDir: iconsDir)
    }

    /// Stages a portable `.exe`. Single-file utilities dropped from transient folders
    /// (`Downloads`, `Desktop`, `tmp`) are copied into `drive_c/ShelfApps/<slug>/`;
    /// multi-file or NW.js game folders stay in place so all sibling assets/DLLs work.
    public func stagePortableExecutable(_ info: PEExecutableInfo) throws -> WindowsAppItem {
        try ensureFolders()
        let fm = FileManager.default
        let srcURL = URL(fileURLWithPath: info.sourcePath)
        guard fm.fileExists(atPath: srcURL.path) else {
            throw WineRuntimeError.executableMissing(srcURL.path)
        }

        let parent = srcURL.deletingLastPathComponent().standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let transientFolders: Set<String> = [
            home,
            "\(home)/Downloads",
            "\(home)/Desktop",
            "\(home)/Documents",
            "/tmp",
            "/private/tmp"
        ]

        let slug = Self.makeAppSlug(name: info.displayName, seedPath: info.sourcePath)
        let finalExeURL: URL
        if info.recommendedBackend == .wine && transientFolders.contains(parent) {
            let destFolder = shelfAppsDir.appendingPathComponent(slug, isDirectory: true)
            try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
            let destExe = destFolder.appendingPathComponent(srcURL.lastPathComponent)
            if fm.fileExists(atPath: destExe.path) {
                try fm.removeItem(at: destExe)
            }
            try fm.copyItem(at: srcURL, to: destExe)
            finalExeURL = destExe
        } else {
            finalExeURL = srcURL
        }

        return WindowsAppItem(
            id: slug,
            appName: info.displayName,
            executablePath: finalExeURL.path,
            workingDirectoryPath: info.recommendedWorkingDir ?? finalExeURL.deletingLastPathComponent().path,
            arguments: info.recommendedArguments,
            backend: info.recommendedBackend,
            locale: info.recommendedLocale,
            versionName: info.versionName,
            companyName: info.companyName,
            isConsoleApp: info.isConsoleSubsystem,
            iconPath: info.iconPath
        )
    }

    public func runInstallerAndDiscoverApps(_ info: PEExecutableInfo) async throws -> [WindowsAppItem] {
        guard let paths = cachedPaths ?? Self.discoverWine(in: runtimeDir) else {
            throw WineRuntimeError.wineNotFound
        }
        let before = scanInstalledExecutables()

        let args: [String]
        if info.inputKind == .msiInstaller {
            args = ["msiexec", "/i", Self.toWindowsPath(info.sourcePath)]
        } else {
            args = [Self.toWindowsPath(info.sourcePath)]
        }

        let cwd = URL(fileURLWithPath: info.sourcePath).deletingLastPathComponent()
        _ = try await runWineCommand(paths: paths, args: args, cwd: cwd, timeout: 1800)

        let after = scanInstalledExecutables()
        let added = after.subtracting(before)
            .filter { !PEInspector.isAuxiliaryUninstallerOrUpdater(fileName: URL(fileURLWithPath: $0).lastPathComponent) }
            .sorted()

        var discovered: [WindowsAppItem] = []
        for exePath in added {
            let parsed = PEInspector.inspect(path: exePath, iconCacheDir: iconsDir)
            guard parsed.incompatibilityReason == nil, parsed.inputKind == .portableExe else { continue }
            let slug = Self.makeAppSlug(name: parsed.displayName, seedPath: exePath)
            discovered.append(WindowsAppItem(
                id: slug,
                appName: parsed.displayName,
                executablePath: exePath,
                workingDirectoryPath: parsed.recommendedWorkingDir ?? URL(fileURLWithPath: exePath).deletingLastPathComponent().path,
                arguments: parsed.recommendedArguments,
                backend: parsed.recommendedBackend,
                locale: parsed.recommendedLocale,
                versionName: parsed.versionName,
                companyName: parsed.companyName,
                isConsoleApp: parsed.isConsoleSubsystem,
                iconPath: parsed.iconPath
            ))
        }
        return discovered
    }

    public func launch(
        _ item: WindowsAppItem,
        onExit: @escaping @Sendable (WineExitReport) -> Void
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.executablePath) else {
            throw WineRuntimeError.executableMissing(item.executablePath)
        }

        try ensureFolders()
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let logOffsetBefore = ((try? fm.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.uint64Value) ?? 0
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        let proc = Process()
        let workDir = item.workingDirectoryPath
            .flatMap { fm.fileExists(atPath: $0) ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? URL(fileURLWithPath: item.executablePath).deletingLastPathComponent()

        switch item.backend {
        case .nativeNWJS:
            guard let nwjsBin = cachedNWJSBinary ?? Self.discoverNWJS(in: nwjsDir) else {
                try? logHandle?.close()
                throw WineRuntimeError.nwjsNotFound
            }
            let prepared = Self.prepareNWJSLaunchDirectory(
                workDir: workDir,
                appID: item.id,
                appName: item.appName,
                wrappersRoot: nwjsWrappersDir,
                profilesRoot: nwjsProfilesDir
            )
            proc.executableURL = URL(fileURLWithPath: nwjsBin)
            proc.arguments = [
                "--user-data-dir=\(prepared.profileDir.path)",
                "--nwapp=\(prepared.nwappDir.path)"
            ] + item.arguments
            proc.currentDirectoryURL = workDir

        case .wine:
            guard let paths = cachedPaths ?? Self.discoverWine(in: runtimeDir) else {
                try? logHandle?.close()
                throw WineRuntimeError.wineNotFound
            }
            let invocation = buildWineInvocation(
                paths: paths,
                args: (item.isConsoleApp ? ["wineconsole", item.executablePath] : [item.executablePath]) + item.arguments
            )
            proc.executableURL = URL(fileURLWithPath: invocation.executable)
            proc.arguments = invocation.arguments
            proc.environment = buildEnvironment(paths: paths, locale: item.locale, extra: [
                "SDL_RENDER_DRIVER": "direct3d11"
            ])
            proc.currentDirectoryURL = workDir
        }

        if let logHandle {
            proc.standardOutput = logHandle
            proc.standardError = logHandle
        }

        let appID = item.id
        let startedAt = Date()
        let capturedLogURL = logURL
        proc.terminationHandler = { [weak self] finished in
            try? logHandle?.close()
            let duration = Date().timeIntervalSince(startedAt)
            let delta = Self.readLogDelta(from: capturedLogURL, offset: logOffsetBefore)
            let report = WineExitReport(exitCode: finished.terminationStatus, duration: duration, logDelta: delta)
            Task {
                await self?.removeProcess(finished, for: appID)
                onExit(report)
            }
        }

        do {
            try proc.run()
        } catch {
            try? logHandle?.close()
            throw WineRuntimeError.launchFailed(error.localizedDescription)
        }

        runningProcs[appID, default: []].append(proc)

        // Bring the launched app window forward once initialized
        let pid = proc.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Prepares a launch directory and isolated user-data-dir for native Apple Silicon NW.js.
    /// Legacy RPG Maker MV/MZ games often ship `package.json` with `"name": ""`, which NW.js 0.90+
    /// rejects with an error dialog. When `"name"` is missing or empty, creates a lightweight
    /// symlink wrapper with a sanitized `package.json` without mutating the user's game folder.
    public static func prepareNWJSLaunchDirectory(
        workDir: URL,
        appID: String,
        appName: String,
        wrappersRoot: URL,
        profilesRoot: URL
    ) -> (nwappDir: URL, profileDir: URL) {
        let fm = FileManager.default
        let safeID = appID.isEmpty ? "nwjs-app" : appID
        let profileDir = profilesRoot.appendingPathComponent(safeID, isDirectory: true)
        try? fm.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let pkgURL = workDir.appendingPathComponent("package.json")
        guard let rawData = try? Data(contentsOf: pkgURL),
              var json = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any] else {
            return (workDir, profileDir)
        }

        let rawName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nameIsValid = !rawName.isEmpty && !rawName.contains("/") && !rawName.contains("..")
        if nameIsValid {
            return (workDir, profileDir)
        }

        let wrapperDir = wrappersRoot.appendingPathComponent(safeID, isDirectory: true)
        try? fm.removeItem(at: wrapperDir)
        do {
            try fm.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
            let entries = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            for entry in entries {
                if entry.lastPathComponent.lowercased() == "package.json" { continue }
                let linkURL = wrapperDir.appendingPathComponent(entry.lastPathComponent)
                try? fm.createSymbolicLink(at: linkURL, withDestinationURL: entry)
            }

            json["name"] = safeID
            if var windowObj = json["window"] as? [String: Any] {
                let title = (windowObj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if title.isEmpty && !appName.isEmpty {
                    windowObj["title"] = appName
                    json["window"] = windowObj
                }
            }
            let patchedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try patchedData.write(to: wrapperDir.appendingPathComponent("package.json"), options: .atomic)
            return (wrapperDir, profileDir)
        } catch {
            return (workDir, profileDir)
        }
    }

    private static func readLogDelta(from url: URL, offset: UInt64) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            let data = fh.readDataToEndOfFile()
            let tail = data.count > 4096 ? data.suffix(4096) : data
            return String(data: tail, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// Diagnoses quick non-zero exits (within 8 seconds) to give actionable hints.
    public static func diagnoseExit(_ report: WineExitReport, appName: String) -> String? {
        guard report.exitCode != 0, report.duration < 8.0 else { return nil }
        let lower = report.logDelta.lowercased()
        if lower.contains("vcruntime") || lower.contains("msvcp") || lower.contains("mfc140") || lower.contains("api-ms-win-crt") {
            return L10n.t(
                "\(appName) 缺少 VC++ 运行库，可在右上角 ⋯ → 性能与兼容中一键安装",
                "\(appName) is missing VC++ Runtime; install it from ⋯ → Performance & Compatibility"
            )
        }
        if lower.contains("rgss") || lower.contains("rtp") {
            return L10n.t(
                "\(appName) 可能缺少 RPG Maker RTP 素材包，可将其安装包拖入书架安装",
                "\(appName) may require an RPG Maker RTP package; drop its installer onto the shelf"
            )
        }
        if lower.contains("d3d12") || lower.contains("direct3d 12") {
            return L10n.t(
                "\(appName) 需要 DirectX 12，当前开源 Wine 暂不支持",
                "\(appName) requires DirectX 12, which is not supported by open-source Wine"
            )
        }
        return L10n.t(
            "\(appName) 异常退出 (代码 \(report.exitCode))，可右键查看运行日志",
            "\(appName) exited unexpectedly (code \(report.exitCode)); right-click to view run log"
        )
    }

    public func openWineConfig() throws {
        guard let paths = cachedPaths ?? Self.discoverWine(in: runtimeDir) else {
            throw WineRuntimeError.wineNotFound
        }
        let proc = Process()
        let inv = buildWineInvocation(paths: paths, args: ["winecfg"])
        proc.executableURL = URL(fileURLWithPath: inv.executable)
        proc.arguments = inv.arguments
        proc.environment = buildEnvironment(paths: paths, extra: [:])
        try proc.run()
    }

    public func removeAppFilesIfManaged(_ item: WindowsAppItem) {
        let fm = FileManager.default
        let stdExe = URL(fileURLWithPath: item.executablePath).standardizedFileURL.path
        let stdShelfRoot = shelfAppsDir.standardizedFileURL.path
        if stdExe.hasPrefix(stdShelfRoot + "/") {
            let folder = URL(fileURLWithPath: stdExe).deletingLastPathComponent()
            if folder.standardizedFileURL.path != stdShelfRoot {
                try? fm.removeItem(at: folder)
            } else {
                try? fm.removeItem(atPath: stdExe)
            }
        }
        let stdExtractedRoot = extractedDir.standardizedFileURL.path
        if stdExe.hasPrefix(stdExtractedRoot + "/") {
            let rel = String(stdExe.dropFirst((stdExtractedRoot + "/").count))
            if let topSlug = rel.split(separator: "/").first {
                let topFolder = extractedDir.appendingPathComponent(String(topSlug), isDirectory: true)
                try? fm.removeItem(at: topFolder)
            }
        }
        if let icon = item.iconPath {
            try? fm.removeItem(atPath: icon)
        }
        if let shortcut = item.shortcutPath {
            try? fm.removeItem(atPath: shortcut)
        }
    }

    public func terminateApp(id: String) {
        guard let list = runningProcs.removeValue(forKey: id) else { return }
        for p in list where p.isRunning {
            p.terminate()
        }
    }

    public func activeAppIDs() -> Set<String> {
        var active = Set<String>()
        for (id, list) in runningProcs where list.contains(where: { $0.isRunning }) {
            active.insert(id)
        }
        return active
    }

    public func sleep() async {
        for (_, list) in runningProcs {
            for p in list where p.isRunning { p.terminate() }
        }
        runningProcs.removeAll()

        guard let paths = cachedPaths ?? Self.discoverWine(in: runtimeDir) else { return }
        let inv = buildServerInvocation(paths: paths, args: ["-k"])
        _ = try? await ShellCommand.run(
            inv.executable,
            args: inv.arguments,
            env: buildEnvironment(paths: paths, extra: [:]),
            timeout: 12
        )
    }

    // MARK: - Shelf Persistence & Auto-Upgrade

    public func loadShelf() -> [WindowsAppItem] {
        guard let data = try? Data(contentsOf: shelfStoreURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var items = try? dec.decode([WindowsAppItem].self, from: data) else { return [] }

        // Automatically upgrade any pre-existing shelf entries (e.g. generic "nwjs") if a native
        // NW.js or framework configuration is detected on disk.
        var mutated = false
        for i in items.indices where FileManager.default.fileExists(atPath: items[i].executablePath) {
            if items[i].backend == .wine {
                let rechecked = PEInspector.inspect(path: items[i].executablePath, iconCacheDir: iconsDir)
                if rechecked.recommendedBackend == .nativeNWJS {
                    items[i].backend = .nativeNWJS
                    items[i].appName = rechecked.displayName
                    if let newIcon = rechecked.iconPath {
                        items[i].iconPath = newIcon
                    }
                    mutated = true
                } else if items[i].arguments.isEmpty && !rechecked.recommendedArguments.isEmpty {
                    items[i].arguments = rechecked.recommendedArguments
                    mutated = true
                }
            }
        }
        if mutated {
            saveShelf(items)
        }
        return items
    }

    public func saveShelf(_ items: [WindowsAppItem]) {
        try? ensureFolders()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) {
            try? data.write(to: shelfStoreURL, options: .atomic)
        }
    }

    // MARK: - Internal Helpers

    private func removeProcess(_ proc: Process, for id: String) {
        guard var list = runningProcs[id] else { return }
        list.removeAll { $0 === proc || !$0.isRunning }
        if list.isEmpty {
            runningProcs.removeValue(forKey: id)
        } else {
            runningProcs[id] = list
        }
    }

    private func buildWineInvocation(paths: WinePaths, args: [String]) -> (executable: String, arguments: [String]) {
        #if arch(arm64)
        return ("/usr/bin/arch", ["-x86_64", paths.wineBinary] + args)
        #else
        return (paths.wineBinary, args)
        #endif
    }

    private func buildServerInvocation(paths: WinePaths, args: [String]) -> (executable: String, arguments: [String]) {
        #if arch(arm64)
        return ("/usr/bin/arch", ["-x86_64", paths.wineserverBinary] + args)
        #else
        return (paths.wineserverBinary, args)
        #endif
    }

    private func buildEnvironment(
        paths: WinePaths,
        locale: WindowsAppLocale = .auto,
        extra: [String: String]
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(paths.binDir):\(existingPath)"
        env["WINEPREFIX"] = prefixDir.path
        env["WINEDEBUG"] = "-all"
        env["MVK_CONFIG_LOG_LEVEL"] = "0"
        env["DXVK_ASYNC"] = "1"
        env["WINEESYNC"] = "1"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"

        switch locale {
        case .auto:
            let prefersChinese = !AppLanguage.stored.resolvedIsEnglish
                || (Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false)
            if prefersChinese {
                env["LANG"] = "zh_CN.UTF-8"
                env["LC_CTYPE"] = "zh_CN.UTF-8"
            }
        case .zhCN, .jaJP, .zhTW, .enUS:
            env["LANG"] = locale.rawValue
            env["LC_ALL"] = locale.rawValue
            env["LC_CTYPE"] = locale.rawValue
        }

        for (k, v) in extra { env[k] = v }
        return env
    }

    private func runWineCommand(
        paths: WinePaths,
        args: [String],
        extraEnv: [String: String] = [:],
        cwd: URL? = nil,
        timeout: TimeInterval = 60
    ) async throws -> ShellOutput {
        let inv = buildWineInvocation(paths: paths, args: args)
        let env = buildEnvironment(paths: paths, extra: extraEnv)
        return try await ShellCommand.run(inv.executable, args: inv.arguments, env: env, cwd: cwd, timeout: timeout)
    }

    private func scanInstalledExecutables() -> Set<String> {
        let fm = FileManager.default
        var roots: [URL] = [
            driveCDir.appendingPathComponent("Program Files", isDirectory: true),
            driveCDir.appendingPathComponent("Program Files (x86)", isDirectory: true)
        ]
        let usersDir = driveCDir.appendingPathComponent("users", isDirectory: true)
        if let userFolders = try? fm.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: nil) {
            for u in userFolders {
                roots.append(u.appendingPathComponent("AppData/Local/Programs", isDirectory: true))
            }
        }

        let ignoredSystemRoots: Set<String> = [
            "Common Files", "Internet Explorer", "Windows Mail", "Windows Media Player", "Windows NT", "Windows Photo Viewer"
        ]

        var found = Set<String>()
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let topDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for dir in topDirs where !ignoredSystemRoots.contains(dir.lastPathComponent) {
                collectExeFiles(in: dir, depth: 0, maxDepth: 3, into: &found)
            }
        }
        return found
    }

    private func collectExeFiles(in folder: URL, depth: Int, maxDepth: Int, into out: inout Set<String>) {
        guard depth <= maxDepth else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            if entry.pathExtension.lowercased() == "exe" {
                out.insert(entry.standardizedFileURL.path)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                collectExeFiles(in: entry, depth: depth + 1, maxDepth: maxDepth, into: &out)
            }
        }
    }

    public static func makeAppSlug(name: String, seedPath: String) -> String {
        let ascii = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let hash = SHA256.hash(data: Data(seedPath.lowercased().utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
        return ascii.isEmpty ? "winapp-\(hash)" : "\(ascii)-\(hash)"
    }
}
