import Foundation

public enum SandboxError: LocalizedError {
    case notReady
    case bridgeJarMissing
    case emulatorCrashed(String)
    case bootTimeout
    case installFailed(String)
    case uninstallFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return L10n.t("Android 后台环境尚未就绪", "The Android background environment is not ready")
        case .bridgeJarMissing: return L10n.t("应用包内缺少 display-bridge.jar", "display-bridge.jar is missing from the app bundle")
        case .emulatorCrashed(let msg): return L10n.t("Android 模拟器异常退出：\(msg)", "The Android emulator exited unexpectedly: \(msg)")
        case .bootTimeout: return L10n.t("Android 环境启动超时", "Timed out while starting Android")
        case .installFailed(let msg): return L10n.t("安装失败：\(msg)", "Install failed: \(msg)")
        case .uninstallFailed(let msg): return L10n.t("卸载失败：\(msg)", "Uninstall failed: \(msg)")
        case .launchFailed(let msg): return L10n.t("启动失败：\(msg)", "Launch failed: \(msg)")
        }
    }
}

/// Manages a strictly isolated Android 15 ARM64 runtime dedicated to this app,
/// reusing ~/Library/Android/sdk without ever touching ~/.android/avd.
public actor SandboxEngine {
    public static let avdName = "APKInMacOS_Shelf35"
    public static let emulatorPort: Int = 5576
    public static let serial = "emulator-\(emulatorPort)"
    public static let socketName = "apkinmacos_bridge"
    public static let bridgePort: UInt16 = 15576

    nonisolated public let dataRoot: URL
    nonisolated public let avdHome: URL
    nonisolated public let iconsDir: URL
    nonisolated public let shelfStoreURL: URL
    nonisolated public let bootLogURL: URL

    private var sdk: SDKPaths?
    private var emulatorProc: Process?

    public init() {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/APKInMacOS", isDirectory: true)
        self.dataRoot = base
        self.avdHome = base.appendingPathComponent("avd", isDirectory: true)
        self.iconsDir = base.appendingPathComponent("icons", isDirectory: true)
        self.shelfStoreURL = base.appendingPathComponent("shelf.json")
        self.bootLogURL = base.appendingPathComponent("emulator.log")
    }

    public func resolveSDK() throws -> SDKPaths {
        if let sdk { return sdk }
        let found = try SDKEnvironment.discover()
        self.sdk = found
        return found
    }

    public func ensureFolders() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: avdHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)
    }

    public func wake() async throws -> String {
        let sdk = try resolveSDK()
        try ensureIsolatedAVD(sdk: sdk)

        if !(await isDeviceOnline(adb: sdk.adbPath)) {
            try spawnEmulator(sdk: sdk)
            try await waitForBoot(adb: sdk.adbPath)
        }

        let verRes = try await adb(sdk.adbPath, ["shell", "getprop", "ro.build.version.release"])
        let version = verRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Enable root on userdebug google_apis image for trusted multi-window virtual displays
        let rootRes = try? await adb(sdk.adbPath, ["root"], timeout: 15)
        if rootRes?.ok == true && !(rootRes?.stdout.contains("cannot run as root") ?? false) {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            _ = try? await adb(sdk.adbPath, ["wait-for-device"], timeout: 15)
        }

        await applyDesktopTweaks(adbPath: sdk.adbPath)
        await applySlimSystem(RuntimeSettings.slimSystemEnabled)
        try await ensureBridgeUp(adbPath: sdk.adbPath)
        return version.isEmpty ? "\(sdk.apiLevel)" : version
    }

    public func sleep() async {
        guard let sdk = try? resolveSDK() else { return }
        _ = try? await adb(sdk.adbPath, ["shell", "pkill -f BridgeMain || true"], timeout: 5)
        _ = try? await adb(sdk.adbPath, ["forward", "--remove", "tcp:\(Self.bridgePort)"], timeout: 5)
        _ = try? await adb(sdk.adbPath, ["emu", "kill"], timeout: 10)
        for _ in 0..<20 {
            if !(await isDeviceOnline(adb: sdk.adbPath)) { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if let p = emulatorProc, p.isRunning { p.terminate() }
        emulatorProc = nil
    }

    public func isOnline() async -> Bool {
        guard let sdk = try? resolveSDK() else { return false }
        return await isDeviceOnline(adb: sdk.adbPath)
    }

    public func ensureBridgeReady() async throws {
        let sdk = try resolveSDK()
        guard await isDeviceOnline(adb: sdk.adbPath) else { throw SandboxError.notReady }
        try await ensureBridgeUp(adbPath: sdk.adbPath)
    }

    public func inspectAPK(_ path: String) async throws -> APKPackageInfo {
        let sdk = try resolveSDK()
        try ensureFolders()
        return try await APKParser.inspect(apkPath: path, aapt2Path: sdk.aapt2Path, iconCacheDir: iconsDir)
    }

    public func install(_ info: APKPackageInfo) async throws {
        defer {
            if let dir = info.tempExtractDir {
                try? FileManager.default.removeItem(atPath: dir)
            }
        }
        let sdk = try resolveSDK()
        guard await isDeviceOnline(adb: sdk.adbPath) else { throw SandboxError.notReady }

        var res: ShellOutput
        if info.splitAPKPaths.count > 1 {
            res = try await adb(sdk.adbPath, ["install-multiple", "--no-incremental", "-r", "-g"] + info.splitAPKPaths, timeout: 240)
            if !res.ok {
                res = try await adb(sdk.adbPath, ["install-multiple", "--no-incremental", "-r"] + info.splitAPKPaths, timeout: 240)
            }
        } else {
            res = try await adb(sdk.adbPath, ["install", "--no-incremental", "-r", "-g", info.apkPath], timeout: 120)
            if !res.ok {
                res = try await adb(sdk.adbPath, ["install", "--no-incremental", "-r", info.apkPath], timeout: 120)
            }
        }

        guard res.ok && res.stdout.contains("Success") else {
            let detail = (res.stderr + "\n" + res.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SandboxError.installFailed(detail)
        }

        if !info.obbPayloads.isEmpty {
            let obbDir = "/sdcard/Android/obb/\(info.packageName)"
            _ = try? await adb(sdk.adbPath, ["shell", "mkdir", "-p", obbDir], timeout: 15)
            for obb in info.obbPayloads {
                _ = try? await adb(sdk.adbPath, ["push", obb.localPath, "\(obbDir)/\(obb.remoteFileName)"], timeout: 240)
            }
        }
    }

    public func pushFilesToDownload(_ urls: [URL]) async throws -> Int {
        let sdk = try resolveSDK()
        guard await isDeviceOnline(adb: sdk.adbPath) else { throw SandboxError.notReady }
        _ = try? await adb(sdk.adbPath, ["shell", "mkdir", "-p", "/sdcard/Download"], timeout: 10)

        var pushed = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let remote = "/sdcard/Download/\(url.lastPathComponent)"
            let res = try await adb(sdk.adbPath, ["push", url.path, remote], timeout: 120)
            if res.ok {
                pushed += 1
                let encoded = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent
                _ = try? await adb(sdk.adbPath, [
                    "shell", "am", "broadcast",
                    "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                    "-d", "file:///sdcard/Download/\(encoded)"
                ], timeout: 10)
            }
        }
        return pushed
    }

    public func uninstall(_ packageName: String) async throws {
        let sdk = try resolveSDK()
        guard await isDeviceOnline(adb: sdk.adbPath) else { throw SandboxError.notReady }
        let res = try await adb(sdk.adbPath, ["uninstall", packageName], timeout: 60)
        guard res.ok else {
            throw SandboxError.uninstallFailed((res.stderr + res.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func installedPackages() async -> [String] {
        guard let sdk = try? resolveSDK(), await isDeviceOnline(adb: sdk.adbPath),
              let res = try? await adb(sdk.adbPath, ["shell", "pm", "list", "packages", "-3"], timeout: 15),
              res.ok else { return [] }
        return res.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
            .sorted()
    }

    public func resolveActivity(for packageName: String) async -> String? {
        guard let sdk = try? resolveSDK(),
              let res = try? await adb(sdk.adbPath, ["shell", "cmd", "package", "resolve-activity", "--brief", packageName], timeout: 10),
              res.ok else { return nil }
        let lines = res.stdout.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let comp = lines.last(where: { $0.contains("/") }) {
            let parts = comp.split(separator: "/", maxSplits: 1)
            if parts.count == 2 { return String(parts[1]) }
        }
        return nil
    }

    public func launch(packageName: String, activity: String?, onDisplay displayId: Int32) async throws {
        let sdk = try resolveSDK()
        guard await isDeviceOnline(adb: sdk.adbPath) else { throw SandboxError.notReady }

        let resolved = (activity?.isEmpty == false) ? activity : await resolveActivity(for: packageName)
        if let act = resolved, !act.isEmpty {
            let comp = act.contains("/") ? act : "\(packageName)/\(act)"
            let res = try await adb(sdk.adbPath, [
                "shell", "am", "start",
                "--display", "\(displayId)",
                "-a", "android.intent.action.MAIN",
                "-c", "android.intent.category.LAUNCHER",
                "-f", "0x10200000",
                "-n", comp
            ], timeout: 15)
            if res.ok && !res.stdout.contains("Error:") { return }
        }

        let fallback = try await adb(sdk.adbPath, ["shell", "monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"], timeout: 15)
        if !fallback.ok {
            throw SandboxError.launchFailed(fallback.stderr.isEmpty ? fallback.stdout : fallback.stderr)
        }
    }

    public func loadShelf() -> [AndroidAppItem] {
        guard let data = try? Data(contentsOf: shelfStoreURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([AndroidAppItem].self, from: data)) ?? []
    }

    public func saveShelf(_ items: [AndroidAppItem]) {
        try? ensureFolders()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) {
            try? data.write(to: shelfStoreURL, options: .atomic)
        }
    }

    // MARK: - Resource policy

    /// Disable (or restore) the preinstalled packages listed in `RuntimeSettings.slimPackages`.
    /// Only packages from that list are ever touched, and only when their state differs.
    public func applySlimSystem(_ enabled: Bool) async {
        guard let sdk = try? resolveSDK(), await isDeviceOnline(adb: sdk.adbPath) else { return }
        guard let all = try? await adb(sdk.adbPath, ["shell", "pm", "list", "packages"], timeout: 15), all.ok,
              let off = try? await adb(sdk.adbPath, ["shell", "pm", "list", "packages", "-d"], timeout: 15), off.ok
        else { return }
        let installed = Self.packageSet(all.stdout)
        let disabled = Self.packageSet(off.stdout)
        for pkg in RuntimeSettings.slimPackages where installed.contains(pkg) {
            if enabled, !disabled.contains(pkg) {
                _ = try? await adb(sdk.adbPath, ["shell", "pm", "disable-user", "--user", "0", pkg], timeout: 10)
            } else if !enabled, disabled.contains(pkg) {
                _ = try? await adb(sdk.adbPath, ["shell", "pm", "enable", pkg], timeout: 10)
            }
        }
    }

    /// Move the emulator processes in or out of macOS background priority (PRIO_DARWIN_BG).
    /// Used only while no Android window is open.
    public func setBackgroundPriority(_ background: Bool) async {
        guard let r = try? await ShellCommand.run("/usr/bin/pgrep", args: ["-f", "avd \(Self.avdName)"], timeout: 5),
              r.ok else { return }
        let pids = r.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Int32($0) != nil }
        for pid in pids {
            _ = try? await ShellCommand.run("/usr/sbin/taskpolicy", args: [background ? "-b" : "-B", "-p", pid], timeout: 5)
        }
    }

    public static func packageSet(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) })
    }

    // MARK: - Private

    private func ensureIsolatedAVD(sdk: SDKPaths) throws {
        try ensureFolders()
        let fm = FileManager.default
        let iniURL = avdHome.appendingPathComponent("\(Self.avdName).ini")
        let dirURL = avdHome.appendingPathComponent("\(Self.avdName).avd", isDirectory: true)
        let cfgURL = dirURL.appendingPathComponent("config.ini")

        if !fm.fileExists(atPath: dirURL.path) {
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        let ini = """
        avd.ini.encoding=UTF-8
        path=\(dirURL.path)
        path.rel=avd/\(Self.avdName).avd
        target=android-\(sdk.apiLevel)
        """
        try ini.write(to: iniURL, atomically: true, encoding: .utf8)

        if !fm.fileExists(atPath: cfgURL.path) {
            let cfg = """
            PlayStore.enabled=no
            abi.type=arm64-v8a
            avd.id=\(Self.avdName)
            avd.ini.encoding=UTF-8
            avd.name=\(Self.avdName)
            disk.cachePartition=yes
            disk.cachePartition.size=128MB
            disk.dataPartition.size=8G
            fastboot.forceChosenSnapshotBoot=no
            fastboot.forceColdBoot=no
            fastboot.forceFastBoot=yes
            hw.accelerometer=yes
            hw.audioInput=no
            hw.audioOutput=yes
            hw.battery=yes
            hw.camera.back=emulated
            hw.camera.front=emulated
            hw.cpu.arch=arm64
            hw.cpu.ncore=4
            hw.dPad=no
            hw.device.manufacturer=Google
            hw.device.name=pixel_7
            hw.gps=yes
            hw.gpu.enabled=yes
            hw.gpu.mode=host
            hw.gsmModem=yes
            hw.initialOrientation=portrait
            hw.keyboard=yes
            hw.keyboard.charmap=qwerty2
            hw.keyboard.lid=yes
            hw.lcd.backlight=yes
            hw.lcd.density=420
            hw.lcd.depth=32
            hw.lcd.height=1920
            hw.lcd.vsync=60
            hw.lcd.width=1080
            hw.mainKeys=no
            hw.ramSize=\(RuntimeSettings.defaultMemoryMB)
            hw.screen=multi-touch
            hw.sdCard=yes
            hw.sensors.orientation=yes
            hw.sensors.proximity=yes
            hw.trackBall=no
            hw.useext4=yes
            image.sysdir.1=\(sdk.systemImageRelPath)
            runtime.network.latency=none
            runtime.network.speed=full
            sdcard.size=512 MB
            showDeviceFrame=no
            tag.display=\(sdk.tagDisplay)
            tag.id=\(sdk.tagId)
            target=android-\(sdk.apiLevel)
            vm.heapSize=512M
            """
            try cfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        }
    }

    private func spawnEmulator(sdk: SDKPaths) throws {
        let quickBoot = RuntimeSettings.quickBootEnabled
        if !quickBoot {
            // Quick boot is off: drop the RAM snapshot (often 3–4 GB) of our own AVD only.
            let snaps = avdHome.appendingPathComponent("\(Self.avdName).avd/snapshots", isDirectory: true)
            try? FileManager.default.removeItem(at: snaps)
        }
        FileManager.default.createFile(atPath: bootLogURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: bootLogURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: sdk.emulatorPath)
        p.arguments = [
            "-avd", Self.avdName,
            "-port", "\(Self.emulatorPort)",
            "-no-window",
            "-no-boot-anim",
            "-gpu", "host",
            "-memory", "\(RuntimeSettings.memoryMB)",
            "-no-metrics"
        ] + (quickBoot ? [] : ["-no-snapshot"])
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_AVD_HOME"] = avdHome.path
        env["ANDROID_SDK_ROOT"] = sdk.sdkRoot
        env["ANDROID_HOME"] = sdk.sdkRoot
        p.environment = env
        p.standardOutput = fh
        p.standardError = fh
        try p.run()
        self.emulatorProc = p
    }

    private func waitForBoot(adb adbPath: String) async throws {
        let deadline = Date().addingTimeInterval(95)
        while Date() < deadline {
            if let p = emulatorProc, !p.isRunning {
                let tail = (try? String(contentsOf: bootLogURL, encoding: .utf8))?
                    .split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n") ?? ""
                throw SandboxError.emulatorCrashed(tail)
            }
            if let r = try? await adb(adbPath, ["shell", "getprop", "sys.boot_completed"], timeout: 5),
               r.ok, r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return
            }
            try await Task.sleep(nanoseconds: 900_000_000)
        }
        throw SandboxError.bootTimeout
    }

    private func applyDesktopTweaks(adbPath: String) async {
        let cmds = [
            ["shell", "settings", "put", "global", "stay_on_while_plugged_in", "7"],
            ["shell", "settings", "put", "system", "screen_off_timeout", "2147483647"],
            ["shell", "settings", "put", "global", "force_resizable_activities", "1"],
            ["shell", "settings", "put", "global", "enable_freeform_support", "1"],
            ["shell", "wm", "dismiss-keyguard"]
        ]
        for c in cmds { _ = try? await adb(adbPath, c, timeout: 10) }
    }

    private func locateBridgeJar() -> URL? {
        let fm = FileManager.default
        if let u = Bundle.main.url(forResource: "display-bridge", withExtension: "jar"), fm.fileExists(atPath: u.path) {
            return u
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/display-bridge.jar")
        return fm.fileExists(atPath: cwd.path) ? cwd : nil
    }

    private func ensureBridgeUp(adbPath: String) async throws {
        let ps = try? await adb(adbPath, ["shell", "pgrep", "-f", "BridgeMain"], timeout: 5)
        let running = (ps?.ok == true) && !(ps?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if !running {
            guard let jar = locateBridgeJar() else { throw SandboxError.bridgeJarMissing }
            let push = try await adb(adbPath, ["push", jar.path, "/data/local/tmp/display-bridge.jar"], timeout: 20)
            guard push.ok else { throw SandboxError.launchFailed(L10n.t("推送显示桥接失败：", "Failed to push display bridge: ") + push.stderr) }

            let cmd = "nohup app_process -Djava.class.path=/data/local/tmp/display-bridge.jar / dev.apkinmacos.bridge.BridgeMain \(Self.socketName) >/data/local/tmp/bridge.log 2>&1 &"
            _ = try await adb(adbPath, ["shell", cmd], timeout: 10)
            try await Task.sleep(nanoseconds: 750_000_000)
        }

        let fwd = try await adb(adbPath, ["forward", "tcp:\(Self.bridgePort)", "localabstract:\(Self.socketName)"], timeout: 10)
        guard fwd.ok else { throw SandboxError.launchFailed(L10n.t("端口转发失败：", "Port forwarding failed: ") + fwd.stderr) }
    }

    private func isDeviceOnline(adb adbPath: String) async -> Bool {
        guard let r = try? await ShellCommand.run(adbPath, args: ["devices"], timeout: 8), r.ok else { return false }
        return r.stdout.split(whereSeparator: \.isNewline).contains { $0.contains(Self.serial) && $0.contains("\tdevice") }
    }

    private func adb(_ adbPath: String, _ args: [String], timeout: TimeInterval = 30) async throws -> ShellOutput {
        try await ShellCommand.run(adbPath, args: ["-s", Self.serial] + args, timeout: timeout)
    }
}
