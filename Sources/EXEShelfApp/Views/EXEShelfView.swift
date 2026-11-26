import ShelfKit
import SwiftUI
import UniformTypeIdentifiers
import WineRuntime

struct EXEShelfView: View {
    @Bindable var store: EXEShelfStore
    @State private var dragHovering = false
    @State private var renamingItem: WindowsAppItem?
    @State private var renameText = ""

    private let grid = [
        GridItem(.adaptive(minimum: 112, maximum: 124), spacing: 14)
    ]

    var body: some View {
        ZStack {
            ParchmentBackdrop()

            VStack(spacing: 0) {
                topStrip
                shelfBody
                bottomWhisper
            }

            if dragHovering {
                dropCurtain
            }

            if let notice = store.notice {
                ShelfNoticeBanner(notice: notice) { store.notice = nil }
            }
        }
        .preferredColorScheme(.light)
        .animation(.easeOut(duration: 0.16), value: dragHovering)
        .animation(.easeInOut(duration: 0.20), value: store.notice)
        .onDrop(of: [.fileURL], isTargeted: $dragHovering) { providers in
            acceptDrop(providers)
        }
        .alert(
            tr("重命名应用", "Rename App"),
            isPresented: Binding(
                get: { renamingItem != nil },
                set: { if !$0 { renamingItem = nil } }
            )
        ) {
            TextField(tr("显示名称", "Display Name"), text: $renameText)
            Button(tr("取消", "Cancel"), role: .cancel) {
                renamingItem = nil
            }
            Button(tr("保存", "Save")) {
                if let target = renamingItem {
                    let nextName = renameText
                    renamingItem = nil
                    Task { await store.rename(target, to: nextName) }
                }
            }
        }
    }

    // MARK: - Minimal Top Strip

    private var topStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if store.sandboxState.isTransitioning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.68)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }
                Text(statusWord)
                    .font(.system(size: 12))
                    .foregroundStyle(IvoryTheme.inkMuted)
                    .lineLimit(1)

                Text(tr("实验性", "Experimental"))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(IvoryTheme.warmGold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(IvoryTheme.warmGoldSoft, in: Capsule())
            }

            Spacer()

            LanguageToggle()

            Button {
                store.pickAndRunExecutables()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IvoryTheme.ink)
                    .frame(width: 28, height: 28)
                    .background(IvoryTheme.paper, in: Circle())
                    .overlay(Circle().strokeBorder(IvoryTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            .help(tr("添加并运行 EXE / MSI (⌘O)", "Add and run EXE / MSI (⌘O)"))

            Menu {
                Button(tr("打开独立快捷方式目录", "Open Shortcuts Folder")) {
                    store.openShortcutsFolder()
                }
                Button(tr("浏览虚拟 C 盘 (drive_c)", "Browse Virtual C: Drive")) {
                    store.openDriveCFolder()
                }
                Button(tr("打开 Wine 配置 (winecfg)", "Open Wine Configuration (winecfg)")) {
                    Task { await store.openWineCfg() }
                }
                Button(tr("查看运行日志", "View Run Log")) {
                    store.openRunLog()
                }
                Divider()
                performanceMenu
                Divider()
                if store.sandboxState.isReady {
                    Button(tr("停止后台 Wine 环境", "Stop Wine Environment")) {
                        Task { await store.sleepEnvironment() }
                    }
                } else if !store.sandboxState.isTransitioning {
                    Button(tr("准备后台 Wine 环境", "Prepare Wine Environment")) {
                        Task { try? await store.ensureEnvironmentReady() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IvoryTheme.inkMuted)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("更多", "More"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private var performanceMenu: some View {
        @Bindable var prefs = WinePreferences.shared
        return Menu(tr("性能与兼容", "Performance & Compatibility")) {
            Toggle(tr("DXVK 硬件加速 (DirectX → Metal)", "DXVK Acceleration (DirectX → Metal)"), isOn: Binding(
                get: { prefs.dxvkEnabled },
                set: { prefs.dxvkEnabled = $0; store.graphicsSettingChanged() }
            ))
            Toggle(tr("空闲 2 分钟后关闭 Wine 后台", "Stop Wine After 2 Idle Minutes"), isOn: Binding(
                get: { prefs.idleSleep },
                set: { prefs.idleSleep = $0; store.idleSettingChanged() }
            ))
            Toggle(tr("实验性 Retina 缩放（部分游戏不兼容）", "Experimental Retina Scaling"), isOn: Binding(
                get: { prefs.retinaMode },
                set: { prefs.retinaMode = $0; store.graphicsSettingChanged() }
            ))
            Divider()
            Button(tr("安装常用运行库 (VC++ x64)", "Install VC++ Runtime (x64)")) {
                Task { await store.installVCRedist() }
            }
        }
    }

    private var dotColor: Color {
        switch store.sandboxState {
        case .ready: return IvoryTheme.sage
        case .downloadingRuntime, .initializingBottle, .stopping: return IvoryTheme.warmGold
        case .failed: return IvoryTheme.terracotta
        case .idle: return IvoryTheme.inkFaint
        }
    }

    private var statusWord: String {
        switch store.sandboxState {
        case .idle:
            return store.hasInstalledWine
                ? tr("待机", "Idle")
                : tr("待机 · Wine 按需拉起", "Idle · Wine on demand")
        case .downloadingRuntime(let text):
            return text
        case .initializingBottle:
            return tr("正在初始化 Windows 环境…", "Initializing Windows bottle…")
        case .ready:
            let n = store.activeAppIDs.count
            if n > 0 {
                return tr("运行中 · \(n) 个程序", n == 1 ? "Running · 1 app" : "Running · \(n) apps")
            }
            return tr("已就绪", "Ready")
        case .stopping:
            return tr("正在停止…", "Stopping…")
        case .failed:
            return tr("环境不可用", "Environment unavailable")
        }
    }

    // MARK: - Shelf Body

    @ViewBuilder
    private var shelfBody: some View {
        if store.apps.isEmpty && store.installingTiles.isEmpty {
            emptyDesk
        } else {
            ScrollView {
                LazyVGrid(columns: grid, spacing: 18) {
                    ForEach(store.installingTiles) { tile in
                        InstallingTileView(tile: tile)
                    }
                    ForEach(store.apps) { item in
                        EXEAppTileView(
                            item: item,
                            isRunning: store.activeAppIDs.contains(item.id),
                            onOpen: { Task { await store.openApp(item) } },
                            onToggleBackend: supportsNativeToggle(item) ? { Task { await store.toggleBackend(for: item) } } : nil,
                            onSelectLocale: { loc in Task { await store.setLocale(loc, for: item) } },
                            onRename: {
                                renameText = item.appName
                                renamingItem = item
                            },
                            onViewLog: { store.openRunLog() },
                            onRevealExecutable: { store.revealExecutable(for: item) },
                            onRevealShortcut: { store.revealShortcut(for: item) },
                            onCopyToDesktop: { Task { await store.createOrRevealShortcut(for: item, copyToDesktop: true, reveal: false) } },
                            onRemove: { Task { await store.remove(item) } }
                        )
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
            }
        }
    }

    private var emptyDesk: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(IvoryTheme.warmGold)
                    .frame(width: 62, height: 62)
                    .background(IvoryTheme.warmGoldSoft, in: Circle())

                VStack(spacing: 5) {
                    Text(tr("拖入 EXE / 游戏文件夹直接运行", "Drop an EXE, folder, or ZIP"))
                        .font(.system(size: 18, weight: .medium, design: .serif))
                        .foregroundStyle(IvoryTheme.ink)
                    Text(tr("支持 .exe / .zip / 目录，打开独立窗口并生成 Mac 快捷方式", "Opens Windows apps or games and adds a Mac shortcut"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(IvoryTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }

                Button(tr("选择 EXE / 目录 / ZIP", "Choose App / Folder / ZIP")) {
                    store.pickAndRunExecutables()
                }
                .buttonStyle(IvoryPillButtonStyle())
                .padding(.top, 4)
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 36)
            .frame(maxWidth: 420)
            .background(IvoryTheme.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(IvoryTheme.hairlineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            )

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var bottomWhisper: some View {
        Text(tr("拖入 .exe / .zip / 游戏目录自动运行 · 右键图标切换引擎或区域", "Drop an .exe, .zip, or game folder · Right-click an icon for options"))
            .font(.system(size: 11))
            .foregroundStyle(IvoryTheme.inkFaint)
            .padding(.vertical, 12)
    }

    private var dropCurtain: some View {
        ZStack {
            IvoryTheme.canvas.opacity(0.94)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(IvoryTheme.warmGold, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .padding(22)
            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(IvoryTheme.warmGold)
                Text(tr("松开即自动加入并运行", "Release to add and run"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IvoryTheme.ink)
            }
        }
        .ignoresSafeArea()
    }

    private func supportsNativeToggle(_ item: WindowsAppItem) -> Bool {
        if item.backend == .nativeNWJS { return true }
        let dir = URL(fileURLWithPath: item.executablePath).deletingLastPathComponent()
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("package.json").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("www/package.json").path)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var matched = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            matched = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                if let url, ArchiveAndFolderResolver.isSupportedDropURL(url) {
                    Task { @MainActor in
                        store.importSilently(urls: [url])
                    }
                }
            }
        }
        return matched
    }
}
