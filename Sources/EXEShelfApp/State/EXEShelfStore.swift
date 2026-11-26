import AppKit
import Foundation
import Observation
import ShelfKit
import UniformTypeIdentifiers
import WineRuntime

@Observable
@MainActor
public final class EXEShelfStore {
    public let engine = WineEngine()

    public var sandboxState: WineSandboxState = .idle
    public var hasInstalledWine: Bool = false
    public var apps: [WindowsAppItem] = []
    public var installingTiles: [InstallingTile] = []
    public var activeAppIDs: Set<String> = []
    public var notice: InlineNotice?

    private var prepareTask: Task<Void, Error>?
    private var idleTask: Task<Void, Never>?

    public init() {
        Task { await initialLoad() }
    }

    private func initialLoad() async {
        do {
            try await engine.ensureFolders()
            apps = await engine.loadShelf()
            hasInstalledWine = await engine.hasLocalWine()
            sandboxState = .idle

            // Refresh shortcuts if any item upgraded its name/icon (e.g. NW.js game title)
            for idx in apps.indices {
                let item = apps[idx]
                if let oldShortcut = item.shortcutPath,
                   URL(fileURLWithPath: oldShortcut).deletingPathExtension().lastPathComponent != item.appName {
                    try? FileManager.default.removeItem(atPath: oldShortcut)
                    if let updated = try? await WineShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: hostBundlePath()) {
                        apps[idx].shortcutPath = updated.path
                    }
                }
            }
            await engine.saveShelf(apps)
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

    // MARK: - Environment Preparation & Idle Policy

    public func ensureRuntimeForBackend(_ backend: WindowsExecutionBackend) async throws {
        switch backend {
        case .wine:
            try await ensureEnvironmentReady()
        case .nativeNWJS:
            idleTask?.cancel()
            idleTask = nil
            if await engine.hasLocalNWJS() {
                if !sandboxState.isReady {
                    sandboxState = .ready(wineVersion: "NW.js")
                }
                return
            }
            do {
                let ver = try await engine.prepareNWJSEnvironment { [weak self] stage in
                    Task { @MainActor in
                        self?.sandboxState = stage
                    }
                }
                sandboxState = .ready(wineVersion: ver)
            } catch {
                sandboxState = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    public func ensureEnvironmentReady() async throws {
        idleTask?.cancel()
        idleTask = nil
        defer { reconsiderIdle() }

        if sandboxState.isReady { return }
        if let existing = prepareTask {
            try await existing.value
            return
        }

        let task = Task<Void, Error> {
            let ver = try await engine.prepareEnvironment { [weak self] stage in
                Task { @MainActor in
                    guard let self, self.prepareTask != nil, !self.sandboxState.isReady else { return }
                    self.sandboxState = stage
                }
            }
            self.hasInstalledWine = true
            self.sandboxState = .ready(wineVersion: ver)
        }
        prepareTask = task
        defer { prepareTask = nil }

        do {
            try await task.value
        } catch {
            sandboxState = .failed(error.localizedDescription)
            throw error
        }
    }

    public func sleepEnvironment() async {
        idleTask?.cancel()
        idleTask = nil
        sandboxState = .stopping
        await engine.sleep()
        activeAppIDs.removeAll()
        sandboxState = .idle
    }

    private func refreshActiveApps() async {
        activeAppIDs = await engine.activeAppIDs()
        reconsiderIdle()
    }

    private func reconsiderIdle() {
        idleTask?.cancel()
        idleTask = nil
        guard sandboxState.isReady, activeAppIDs.isEmpty, installingTiles.isEmpty else { return }
        guard WineRuntimeSettings.idleSleepEnabled else { return }

        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WineRuntimeSettings.idleSleepAfter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.sandboxState.isReady, self.activeAppIDs.isEmpty, self.installingTiles.isEmpty else { return }
            self.idleTask = nil
            await self.sleepEnvironment()
        }
    }

    public func idleSettingChanged() {
        reconsiderIdle()
    }

    public func graphicsSettingChanged() {
        Task {
            await engine.applyGraphicsSettings(
                retinaEnabled: WineRuntimeSettings.retinaModeEnabled,
                dxvkEnabled: WineRuntimeSettings.dxvkEnabled
            )
            showNotice(tr("已更新图形兼容设置（下次启动程序生效）", "Updated graphics settings (applies on next launch)"))
        }
    }

    // MARK: - Zero-Popup Silent Add / Install / Run

    public func pickAndRunExecutables() {
        let panel = NSOpenPanel()
        panel.title = tr("选择 Windows 程序、游戏目录或 ZIP 压缩包", "Choose Windows App, Game Folder, or ZIP")
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data,
            UTType(filenameExtension: "msi") ?? .data,
            .zip,
            .folder
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            importSilently(urls: panel.urls)
        }
    }

    public func importSilently(urls: [URL]) {
        let valid = urls.filter { ArchiveAndFolderResolver.isSupportedDropURL($0) }
        guard !valid.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for url in valid {
            Task { await importSingleFile(url: url) }
        }
    }

    private func importSingleFile(url: URL) async {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        var isDir: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        let initialStage: String
        if url.pathExtension.lowercased() == "zip" {
            initialStage = tr("解压中", "Extracting")
        } else if isFolder {
            initialStage = tr("扫描目录", "Scanning")
        } else {
            initialStage = tr("识别中", "Reading")
        }
        let tile = InstallingTile(sourcePath: url.path, appName: fallbackName, iconPath: nil, stageText: initialStage)
        installingTiles.append(tile)
        idleTask?.cancel()
        idleTask = nil

        defer {
            installingTiles.removeAll { $0.id == tile.id }
            reconsiderIdle()
        }

        do {
            let targetURL = try await engine.resolveDroppedInput(url)
            updateTile(tile.id, name: fallbackName, icon: nil, stage: tr("识别中", "Reading"))
            let info = await engine.inspectExecutable(targetURL.path)
            updateTile(tile.id, name: info.displayName, icon: info.iconPath, stage: tr("准备环境", "Preparing"))

            if let reason = info.incompatibilityReason {
                showNotice("\(info.displayName)：\(reason)", isError: true)
                return
            }

            try await ensureRuntimeForBackend(info.recommendedBackend)

            switch info.inputKind {
            case .portableExe:
                updateTile(tile.id, name: info.displayName, icon: info.iconPath, stage: tr("加入书架", "Adding"))
                var item = try await engine.stagePortableExecutable(info)
                let existing = apps.first(where: { $0.id == item.id || $0.executablePath == item.executablePath })
                if let existing {
                    item.addedAt = existing.addedAt
                }
                if let shortcutURL = try? await WineShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: hostBundlePath()) {
                    item.shortcutPath = shortcutURL.path
                }
                upsertItems([item])

                updateTile(tile.id, name: item.appName, icon: item.iconPath, stage: tr("打开中", "Opening"))
                try await launchItem(item)

            case .installerExe, .msiInstaller:
                updateTile(tile.id, name: info.displayName, icon: info.iconPath, stage: tr("运行安装器", "Running Setup"))
                let discovered = try await engine.runInstallerAndDiscoverApps(info)
                if discovered.isEmpty {
                    showNotice(tr(
                        "安装向导已结束；若未自动出现图标，可点右上角 + 从 C 盘选择主程序",
                        "Installer finished; if no icon appeared, click + to pick the installed .exe from drive_c"
                    ))
                } else {
                    var finalized: [WindowsAppItem] = []
                    for var item in discovered {
                        if let shortcutURL = try? await WineShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: hostBundlePath()) {
                            item.shortcutPath = shortcutURL.path
                        }
                        finalized.append(item)
                    }
                    upsertItems(finalized)
                    if let first = finalized.first {
                        try? await launchItem(first)
                    }
                }
            }
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func upsertItems(_ newItems: [WindowsAppItem]) {
        var updated = apps
        for item in newItems {
            updated.removeAll { $0.id == item.id || $0.executablePath == item.executablePath }
            updated.append(item)
        }
        updated.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        apps = updated
        let snapshot = updated
        Task { await engine.saveShelf(snapshot) }
    }

    private func updateTile(_ id: UUID, name: String, icon: String?, stage: String) {
        guard let idx = installingTiles.firstIndex(where: { $0.id == id }) else { return }
        installingTiles[idx].appName = name
        installingTiles[idx].iconPath = icon
        installingTiles[idx].stageText = stage
    }

    // MARK: - Open, Shortcuts, Tools & Remove

    public func openApp(_ item: WindowsAppItem) async {
        do {
            let hasNWJS = (item.backend == .nativeNWJS) ? await engine.hasLocalNWJS() : true
            let needsPrep = (item.backend == .wine && !sandboxState.isReady) || !hasNWJS
            if needsPrep {
                showNotice(tr("正在启动 \(item.appName)…", "Starting \(item.appName)…"))
            }
            try await ensureRuntimeForBackend(item.backend)
            try await launchItem(item)
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func launchItem(_ item: WindowsAppItem) async throws {
        try await engine.launch(item) { [weak self] report in
            Task { @MainActor in
                await self?.refreshActiveApps()
                if let diag = WineEngine.diagnoseExit(report, appName: item.appName) {
                    self?.showNotice(diag, isError: true)
                }
            }
        }
        await refreshActiveApps()
    }

    public func openAppByDeepLink(_ id: String) async {
        if apps.isEmpty {
            apps = await engine.loadShelf()
        }
        guard let found = apps.first(where: { $0.id == id }) else {
            showNotice(tr("找不到对应的 Windows 程序", "Windows app not found on shelf"), isError: true)
            return
        }
        await openApp(found)
    }

    public func createOrRevealShortcut(for item: WindowsAppItem, copyToDesktop: Bool, reveal: Bool) async {
        do {
            let shortcutURL = try await WineShortcutBuilder.createMacAppShortcut(for: item, hostAppPath: hostBundlePath())
            if let idx = apps.firstIndex(where: { $0.id == item.id }) {
                apps[idx].shortcutPath = shortcutURL.path
                await engine.saveShelf(apps)
            }
            if copyToDesktop {
                let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/\(shortcutURL.lastPathComponent)")
                try? FileManager.default.removeItem(at: desktop)
                try FileManager.default.copyItem(at: shortcutURL, to: desktop)
                showNotice(tr("已复制到桌面", "Copied to Desktop"))
            }
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([shortcutURL])
            }
        } catch {
            showNotice(tr("创建快捷方式失败：\(error.localizedDescription)", "Could not create shortcut: \(error.localizedDescription)"), isError: true)
        }
    }

    public func revealShortcut(for item: WindowsAppItem) {
        if let path = item.shortcutPath, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            Task { await createOrRevealShortcut(for: item, copyToDesktop: false, reveal: true) }
        }
    }

    public func revealExecutable(for item: WindowsAppItem) {
        let url = URL(fileURLWithPath: item.executablePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            showNotice(tr("程序文件不存在", "Executable file not found"), isError: true)
        }
    }

    public func openShortcutsFolder() {
        let dir = WineShortcutBuilder.shortcutsFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    public func openDriveCFolder() {
        let dir = engine.driveCDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    public func openRunLog() {
        let logURL = engine.logURL
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }

    public func installVCRedist() async {
        do {
            showNotice(tr("正在下载并安装 VC++ 运行库…", "Downloading and installing VC++ Runtime…"))
            try await engine.installVCRedistRuntime { [weak self] stage in
                Task { @MainActor in
                    self?.sandboxState = stage
                }
            }
            hasInstalledWine = true
            sandboxState = .ready(wineVersion: "Wine")
            reconsiderIdle()
            showNotice(tr("VC++ 运行库安装完成", "VC++ Runtime installed"))
        } catch {
            sandboxState = await engine.hasLocalWine() ? .idle : .failed(error.localizedDescription)
            showNotice(error.localizedDescription, isError: true)
        }
    }

    public func rename(_ item: WindowsAppItem, to rawName: String) async {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = apps.firstIndex(where: { $0.id == item.id }) else { return }
        if let oldShortcut = apps[idx].shortcutPath {
            try? FileManager.default.removeItem(atPath: oldShortcut)
        }
        apps[idx].appName = trimmed
        if let updated = try? await WineShortcutBuilder.createMacAppShortcut(for: apps[idx], hostAppPath: hostBundlePath()) {
            apps[idx].shortcutPath = updated.path
        }
        apps.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        await engine.saveShelf(apps)
        showNotice(tr("已重命名为 \(trimmed)", "Renamed to \(trimmed)"))
    }

    public func openWineCfg() async {
        do {
            try await ensureEnvironmentReady()
            try await engine.openWineConfig()
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    public func setLocale(_ locale: WindowsAppLocale, for item: WindowsAppItem) async {
        guard let idx = apps.firstIndex(where: { $0.id == item.id }) else { return }
        apps[idx].locale = locale
        await engine.saveShelf(apps)
        showNotice(tr("已设置区域：\(locale.label)（下次启动生效）", "Locale set to \(locale.label) (applies on next launch)"))
    }

    public func toggleBackend(for item: WindowsAppItem) async {
        guard let idx = apps.firstIndex(where: { $0.id == item.id }) else { return }
        await engine.terminateApp(id: item.id)
        let next: WindowsExecutionBackend = (apps[idx].backend == .nativeNWJS) ? .wine : .nativeNWJS
        apps[idx].backend = next
        if next == .wine && apps[idx].arguments.isEmpty {
            apps[idx].arguments = ["--in-process-gpu", "--use-gl=swiftshader", "--disable-gpu-compositing", "--no-sandbox"]
        } else if next == .nativeNWJS {
            apps[idx].arguments = []
        }
        await engine.saveShelf(apps)
        showNotice(next == .nativeNWJS
            ? tr("已切换为原生引擎（金属 GPU 加速）", "Switched to Native Engine (Metal GPU)")
            : tr("已切换为 Wine 兼容层运行", "Switched to Wine Compatibility Layer"))
    }

    public func remove(_ item: WindowsAppItem) async {
        await engine.terminateApp(id: item.id)
        await engine.removeAppFilesIfManaged(item)
        apps.removeAll { $0.id == item.id }
        await engine.saveShelf(apps)
        await refreshActiveApps()
    }

    private func hostBundlePath() -> String {
        let url = Bundle.main.bundleURL
        if url.pathExtension == "app" {
            return url.path
        }
        let dist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/EXEInMacOS.app")
        return dist.path
    }
}
