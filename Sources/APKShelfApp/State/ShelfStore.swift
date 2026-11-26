import APKRuntime
import AppKit
import Foundation
import Observation

@Observable
@MainActor
public final class ShelfStore {
    public let engine = SandboxEngine()
    public let windows = WindowCoordinator()

    public var sandboxState: SandboxState = .idle
    public var sdkMissingMessage: String?
    public var apps: [AndroidAppItem] = []
    public var installingTiles: [InstallingTile] = []
    public var activeWindowKeys: Set<String> = []
    public var notice: InlineNotice?

    private var wakeTask: Task<Void, Error>?
    /// Pending "lower priority, then sleep" countdown while no Android window is open.
    private var idleTask: Task<Void, Never>?
    private var runtimeBackgrounded = false

    public init() {
        windows.onActiveKeysChanged = { [weak self] keys in
            self?.activeWindowKeys = keys
            self?.reconsiderIdle()
        }
        windows.onWindowSizeSaved = { [weak self] pkg, w, h in
            self?.saveWindowSize(packageName: pkg, width: w, height: h)
        }
        windows.onShortcutRequested = { [weak self] item in
            Task { await self?.createOrRevealShortcut(for: item, copyToDesktop: false, reveal: true) }
        }

        Task { await checkSDKAndLoad() }
    }

    public func checkSDKAndLoad() async {
        do {
            _ = try await engine.resolveSDK()
            sdkMissingMessage = nil
            try await engine.ensureFolders()
            apps = await engine.loadShelf()
            if await engine.isOnline() {
                // Opportunistic re-attach; if the emulator was mid-shutdown, just stay idle.
                do {
                    try await ensureSandboxReady()
                } catch {
                    sandboxState = .idle
                }
            } else {
                sandboxState = .idle
            }
        } catch let sdkErr as SDKError {
            sdkMissingMessage = sdkErr.localizedDescription
            sandboxState = .failed(sdkErr.localizedDescription)
        } catch {
            sandboxState = .failed(error.localizedDescription)
            showNotice(error.localizedDescription, isError: true)
        }
    }

    public func showNotice(_ text: String, isError: Bool = false) {
        let item = InlineNotice(text: text, isError: isError)
        notice = item
        Task {
            try? await Task.sleep(nanoseconds: isError ? 5_000_000_000 : 2_800_000_000)
            if notice?.id == item.id {
                notice = nil
            }
        }
    }

    public func ensureSandboxReady() async throws {
        noteActivity()
        defer { reconsiderIdle() }
        if sandboxState.isReady { return }
        if let existing = wakeTask {
            try await existing.value
            return
        }

        sandboxState = .waking
        let task = Task<Void, Error> {
            let ver = try await engine.wake()
            self.sandboxState = .ready(androidVersion: ver)
            await self.syncShelfWithDevice()
        }
        wakeTask = task
        defer { wakeTask = nil }

        do {
            try await task.value
        } catch {
            sandboxState = .failed(error.localizedDescription)
            throw error
        }
    }

    public func sleepSandbox() async {
        idleTask?.cancel()
        idleTask = nil
        runtimeBackgrounded = false
        windows.closeAll()
        sandboxState = .stopping
        await engine.sleep()
        sandboxState = .idle
    }

    public func syncShelfWithDevice() async {
        let cached = await engine.loadShelf()
        let map = Dictionary(uniqueKeysWithValues: cached.map { ($0.packageName, $0) })
        let live = await engine.installedPackages()
        guard !live.isEmpty || sandboxState.isReady else {
            apps = cached
            return
        }

        var merged: [AndroidAppItem] = []
        for pkg in live {
            if var existing = map[pkg] {
                if existing.launchableActivity == nil {
                    existing.launchableActivity = await engine.resolveActivity(for: pkg)
                }
                merged.append(existing)
            } else {
                let act = await engine.resolveActivity(for: pkg)
                let fallback = pkg.split(separator: ".").last.map(String.init)?.capitalized ?? pkg
                merged.append(AndroidAppItem(packageName: pkg, appName: fallback, launchableActivity: act))
            }
        }
        merged.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        apps = merged
        await engine.saveShelf(merged)
    }

    // MARK: - Zero-Popup Silent Install & Open

    public func pickAndInstallAPKs() {
        let panel = NSOpenPanel()
        panel.title = tr("选择 APK / XAPK / APKM 文件", "Choose APK / XAPK / APKM Files")
        panel.allowedContentTypes = APKParser.supportedExtensions.compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            installSilently(urls: panel.urls)
        }
    }

    public func installSilently(urls: [URL]) {
        let apkURLs = urls.filter { APKParser.supportedExtensions.contains($0.pathExtension.lowercased()) }
        guard !apkURLs.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for url in apkURLs {
            Task { await installSingleAPK(url: url) }
        }
    }

    private func installSingleAPK(url: URL) async {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let tile = InstallingTile(sourcePath: url.path, appName: fallbackName, iconPath: nil, stageText: tr("识别中", "Reading"))
        installingTiles.append(tile)
        noteActivity()

        defer {
            installingTiles.removeAll { $0.id == tile.id }
            reconsiderIdle()
        }

        do {
            let pkgInfo = try await engine.inspectAPK(url.path)
            updateTile(tile.id, name: pkgInfo.appName, icon: pkgInfo.iconPath, stage: sandboxState.isReady ? tr("安装中", "Installing") : tr("启动环境", "Starting"))

            if let reason = pkgInfo.incompatibilityReason {
                showNotice("\(pkgInfo.appName)：\(reason)", isError: true)
                return
            }

            if !sandboxState.isReady {
                try await ensureSandboxReady()
            }

            updateTile(tile.id, name: pkgInfo.appName, icon: pkgInfo.iconPath, stage: tr("安装中", "Installing"))
            try await engine.install(pkgInfo)

            let existing = apps.first(where: { $0.packageName == pkgInfo.packageName })
            var item = AndroidAppItem(
                packageName: pkgInfo.packageName,
                appName: pkgInfo.appName,
                versionName: pkgInfo.versionName,
                versionCode: pkgInfo.versionCode,
                launchableActivity: pkgInfo.launchableActivity ?? existing?.launchableActivity,
                iconPath: pkgInfo.iconPath ?? existing?.iconPath,
                shortcutPath: existing?.shortcutPath,
                windowWidth: existing?.windowWidth ?? 390,
                windowHeight: existing?.windowHeight ?? 720,
                addedAt: existing?.addedAt ?? Date()
            )
            if item.launchableActivity == nil {
                item.launchableActivity = await engine.resolveActivity(for: item.packageName)
            }

            // Silently generate standalone Mac shortcut (.app)
            if let shortcutURL = try? await ShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: hostBundlePath()) {
                item.shortcutPath = shortcutURL.path
            }

            var updated = apps
            updated.removeAll { $0.packageName == item.packageName }
            updated.append(item)
            updated.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
            apps = updated
            await engine.saveShelf(updated)

            updateTile(tile.id, name: item.appName, icon: item.iconPath, stage: tr("打开中", "Opening"))
            try await windows.openWindow(for: item, engine: engine, mode: .isolatedDisplay)
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Idle policy

    /// Something is about to use the runtime: cancel any countdown and restore normal priority.
    private func noteActivity() {
        idleTask?.cancel()
        idleTask = nil
        if runtimeBackgrounded {
            runtimeBackgrounded = false
            Task { await engine.setBackgroundPriority(false) }
        }
    }

    /// When the runtime is up but nothing uses it, lower its priority after a short grace
    /// period and, if enabled, save a snapshot and shut it down after a few minutes.
    private func reconsiderIdle() {
        idleTask?.cancel()
        idleTask = nil
        guard sandboxState.isReady else { return }
        guard activeWindowKeys.isEmpty, installingTiles.isEmpty else {
            noteActivity()
            return
        }
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RuntimeSettings.backgroundAfter * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isIdle else { return }
            self.runtimeBackgrounded = true
            await self.engine.setBackgroundPriority(true)

            guard RuntimeSettings.idleSleepEnabled else { return }
            let rest = max(0, RuntimeSettings.idleSleepAfter - RuntimeSettings.backgroundAfter)
            try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000))
            guard !Task.isCancelled, self.isIdle else { return }
            self.idleTask = nil  // don't let sleepSandbox() cancel the task that is running it
            await self.engine.setBackgroundPriority(false)
            await self.sleepSandbox()
        }
    }

    private var isIdle: Bool {
        sandboxState.isReady && activeWindowKeys.isEmpty && installingTiles.isEmpty
    }

    /// Re-evaluate after the user flips the idle-sleep switch.
    public func idleSettingChanged() {
        reconsiderIdle()
    }

    /// Apply the slim-system switch right away if Android is running.
    public func slimSettingChanged(_ enabled: Bool) {
        guard sandboxState.isReady else { return }
        Task { await engine.applySlimSystem(enabled) }
    }

    private func updateTile(_ id: UUID, name: String, icon: String?, stage: String) {
        guard let idx = installingTiles.firstIndex(where: { $0.id == id }) else { return }
        installingTiles[idx].appName = name
        installingTiles[idx].iconPath = icon
        installingTiles[idx].stageText = stage
    }

    // MARK: - Open, Shortcut, Uninstall

    public func openApp(_ item: AndroidAppItem, mode: ChannelMode = .isolatedDisplay) async {
        do {
            if !sandboxState.isReady {
                showNotice(tr("正在启动 \(item.appName)…", "Starting \(item.appName)…"))
                try await ensureSandboxReady()
            }
            try await windows.openWindow(for: item, engine: engine, mode: mode)
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    public func openPackageByDeepLink(_ packageName: String) async {
        do {
            if !sandboxState.isReady {
                try await ensureSandboxReady()
            } else {
                await syncShelfWithDevice()
            }
            if let found = apps.first(where: { $0.packageName == packageName }) {
                try await windows.openWindow(for: found, engine: engine, mode: .isolatedDisplay)
            } else {
                let act = await engine.resolveActivity(for: packageName)
                let fallback = AndroidAppItem(packageName: packageName, appName: packageName, launchableActivity: act)
                try await windows.openWindow(for: fallback, engine: engine, mode: .isolatedDisplay)
            }
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    public func openMainScreen() async {
        do {
            if !sandboxState.isReady { try await ensureSandboxReady() }
            try await windows.openMainScreen(engine: engine)
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    public func createOrRevealShortcut(for item: AndroidAppItem, copyToDesktop: Bool, reveal: Bool) async {
        do {
            let shortcutURL = try await ShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: hostBundlePath())
            if copyToDesktop {
                let dest = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Desktop", isDirectory: true)
                    .appendingPathComponent(shortcutURL.lastPathComponent)
                let fm = FileManager.default
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: shortcutURL, to: dest)
                showNotice(tr("已将 \(item.appName) 快捷方式放到桌面", "Added \(item.appName) shortcut to Desktop"))
            } else {
                showNotice(tr("已更新 \(item.appName) 快捷方式", "Updated \(item.appName) shortcut"))
            }

            if let idx = apps.firstIndex(where: { $0.packageName == item.packageName }) {
                apps[idx].shortcutPath = shortcutURL.path
                await engine.saveShelf(apps)
            }
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([shortcutURL])
            }
        } catch {
            showNotice(tr("生成快捷方式失败：", "Could not create shortcut: ") + error.localizedDescription, isError: true)
        }
    }

    public func revealShortcut(for item: AndroidAppItem) {
        if let p = item.shortcutPath, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else {
            Task { await createOrRevealShortcut(for: item, copyToDesktop: false, reveal: true) }
        }
    }

    public func openShortcutsFolder() {
        let dir = ShortcutBuilder.shortcutsFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    public func uninstall(_ item: AndroidAppItem) async {
        do {
            windows.close(key: item.packageName)
            if !sandboxState.isReady { try await ensureSandboxReady() }
            try await engine.uninstall(item.packageName)
            if let p = item.shortcutPath {
                try? FileManager.default.removeItem(atPath: p)
            }
            apps.removeAll { $0.packageName == item.packageName }
            await engine.saveShelf(apps)
            showNotice(tr("已移除 \(item.appName)", "Removed \(item.appName)"))
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func saveWindowSize(packageName: String, width: Int, height: Int) {
        guard let idx = apps.firstIndex(where: { $0.packageName == packageName }) else { return }
        apps[idx].windowWidth = width
        apps[idx].windowHeight = height
        let snapshot = apps
        Task { await engine.saveShelf(snapshot) }
    }

    private func hostBundlePath() -> String {
        let p = Bundle.main.bundlePath
        return p.hasSuffix(".app") ? p : "/Applications/APKInMacOS.app"
    }
}
