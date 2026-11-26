import APKRuntime
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @Bindable var store: ShelfStore
    @State private var dragHovering = false

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
    }

    // MARK: - Minimal Top Strip

    private var topStrip: some View {
        HStack(spacing: 10) {
            // Subtle ambient status aligned cleanly next to / below traffic lights
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
            }

            Spacer()

            languagePicker

            Button {
                store.pickAndInstallAPKs()
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
            .help(tr("添加并安装 APK (⌘O)", "Add and install APK (⌘O)"))

            Menu {
                Button(tr("打开独立快捷方式目录", "Open Shortcuts Folder")) {
                    store.openShortcutsFolder()
                }
                Button(tr("打开 Android 主屏幕", "Open Android Home Screen")) {
                    Task { await store.openMainScreen() }
                }
                Divider()
                performanceMenu
                Divider()
                if store.sandboxState.isReady {
                    Button(tr("停止后台 Android 环境", "Stop Android Environment")) {
                        Task { await store.sleepSandbox() }
                    }
                } else if !store.sandboxState.isTransitioning {
                    Button(tr("预热后台 Android 环境", "Warm Up Android Environment")) {
                        Task { try? await store.ensureSandboxReady() }
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

    /// Resource switches. Defaults are light; anyone can turn them back off.
    private var performanceMenu: some View {
        @Bindable var prefs = RuntimePreferences.shared
        return Menu(tr("性能与资源", "Performance")) {
            Toggle(tr("空闲 5 分钟后自动休眠", "Sleep After 5 Idle Minutes"), isOn: Binding(
                get: { prefs.idleSleep },
                set: { prefs.idleSleep = $0; store.idleSettingChanged() }
            ))
            Toggle(tr("精简安卓后台", "Slim Android Background"), isOn: Binding(
                get: { prefs.slimSystem },
                set: { prefs.slimSystem = $0; store.slimSettingChanged($0) }
            ))
            Toggle(tr("快速启动（占用约 3 GB 磁盘）", "Quick Boot (uses ~3 GB disk)"), isOn: Binding(
                get: { prefs.quickBoot },
                set: { prefs.quickBoot = $0; store.showNotice(tr("下次启动安卓环境时生效", "Takes effect next time Android starts")) }
            ))
            Picker(tr("安卓内存", "Android Memory"), selection: Binding(
                get: { prefs.memoryMB },
                set: { prefs.memoryMB = $0; store.showNotice(tr("下次启动安卓环境时生效", "Takes effect next time Android starts")) }
            )) {
                ForEach(RuntimeSettings.memoryChoices, id: \.self) { mb in
                    Text("\(mb / 1024) GB").tag(mb)
                }
            }
        }
    }

    private var languagePicker: some View {
        LanguageToggle()
    }

    private var dotColor: Color {
        switch store.sandboxState {
        case .ready: return IvoryTheme.sage
        case .waking, .stopping: return IvoryTheme.warmGold
        case .failed: return IvoryTheme.terracotta
        case .idle: return IvoryTheme.inkFaint
        }
    }

    private var statusWord: String {
        switch store.sandboxState {
        case .idle: return tr("待机", "Idle")
        case .waking: return tr("启动环境中…", "Starting Android…")
        case .ready:
            let n = store.activeWindowKeys.count
            if n > 0 {
                return tr("运行中 · \(n) 个窗口", n == 1 ? "Running · 1 window" : "Running · \(n) windows")
            }
            return tr("已就绪", "Ready")
        case .stopping: return tr("正在停止…", "Stopping…")
        case .failed: return tr("环境不可用", "Environment unavailable")
        }
    }

    // MARK: - Pure App Shelf

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
                        AppTileView(
                            item: item,
                            isRunning: store.activeWindowKeys.contains(item.packageName),
                            onOpen: { Task { await store.openApp(item, mode: .isolatedDisplay) } },
                            onOpenMainScreen: { Task { await store.openApp(item, mode: .mainScreen) } },
                            onRevealShortcut: { store.revealShortcut(for: item) },
                            onCopyToDesktop: { Task { await store.createOrRevealShortcut(for: item, copyToDesktop: true, reveal: false) } },
                            onUninstall: { Task { await store.uninstall(item) } }
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

            if let sdkErr = store.sdkMissingMessage {
                sdkGuideCard(sdkErr)
            } else {
                VStack(spacing: 14) {
                    AndroidMascotIcon(tint: IvoryTheme.warmGold)
                        .frame(width: 32, height: 32)
                        .frame(width: 62, height: 62)
                        .background(IvoryTheme.warmGoldSoft, in: Circle())

                    VStack(spacing: 5) {
                        Text(tr("拖入 APK 直接运行", "Drop an APK to run it"))
                            .font(.system(size: 18, weight: .medium, design: .serif))
                            .foregroundStyle(IvoryTheme.ink)
                        Text(tr("支持 .apk / .xapk / .apkm，打开独立窗口并生成 Mac 快捷方式", "Supports .apk / .xapk / .apkm with Mac shortcuts"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(IvoryTheme.inkMuted)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }

                    Button(tr("选择 APK", "Choose APK")) {
                        store.pickAndInstallAPKs()
                    }
                    .buttonStyle(IvoryPillButtonStyle())
                    .padding(.top, 4)
                }
                .padding(.horizontal, 42)
                .padding(.vertical, 36)
                .frame(maxWidth: 400)
                .background(IvoryTheme.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(IvoryTheme.hairlineStrong, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                )
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func sdkGuideCard(_ message: String) -> some View {
        let cmd = #"brew install --cask android-commandlinetools && sdkmanager "platform-tools" "emulator" "build-tools;35.0.0" "system-images;android-35;google_apis;arm64-v8a""#
        return VStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(IvoryTheme.warmGold)
                .frame(width: 56, height: 56)
                .background(IvoryTheme.warmGoldSoft, in: Circle())

            VStack(spacing: 5) {
                Text(tr("需要配置 Android SDK", "Android SDK Required"))
                    .font(.system(size: 18, weight: .medium, design: .serif))
                    .foregroundStyle(IvoryTheme.ink)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(IvoryTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            Text(cmd)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(IvoryTheme.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IvoryTheme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(IvoryTheme.hairline, lineWidth: 1))
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button(tr("复制安装命令", "Copy Command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                    store.showNotice(tr("已复制终端安装命令", "Copied setup command"))
                }
                .buttonStyle(IvoryPillButtonStyle())

                Button(tr("下载 Android Studio", "Get Android Studio")) {
                    if let url = URL(string: "https://developer.android.com/studio") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)

                Button(tr("重新检测", "Re-check")) {
                    Task { await store.checkSDKAndLoad() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 500)
        .background(IvoryTheme.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(IvoryTheme.hairlineStrong, lineWidth: 1)
        )
    }

    private var bottomWhisper: some View {
        Text(tr("拖入 .apk 静默安装并打开 · 右键图标管理快捷方式或卸载", "Drop an .apk to install and open · Right-click an icon to manage"))
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
                Text(tr("松开即自动安装并打开", "Release to install and open"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(IvoryTheme.ink)
            }
        }
        .ignoresSafeArea()
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
                if let url, APKParser.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    Task { @MainActor in
                        store.installSilently(urls: [url])
                    }
                }
            }
        }
        return matched
    }
}

/// Minimalist line-art Android robot head matching the light stroke weight of EXEShelfView.
private struct AndroidMascotIcon: View {
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 100.0
            let ox = (size.width - 100.0 * s) / 2.0
            let oy = (size.height - 100.0 * s) / 2.0
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: ox + x * s, y: oy + y * s)
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
            }

            let baseY: CGFloat = 74.0
            let domeR: CGFloat = 35.0
            let cornerR: CGFloat = 4.5
            let cornerDX: CGFloat = 30.166
            let alphaDeg: Double = 8.485
            let stroke = StrokeStyle(lineWidth: 5.8 * s, lineCap: .round, lineJoin: .round)

            // Antennae
            var antennae = Path()
            antennae.move(to: pt(31.45, 44.32))
            antennae.addLine(to: pt(22.44, 29.90))
            antennae.move(to: pt(68.55, 44.32))
            antennae.addLine(to: pt(77.56, 29.90))
            ctx.stroke(antennae, with: .color(tint), style: stroke)

            // Tangent-rounded Android dome outline
            var head = Path()
            head.move(to: pt(50.0 - cornerDX, baseY))
            head.addArc(
                center: pt(50.0 - cornerDX, baseY - cornerR),
                radius: cornerR * s,
                startAngle: .degrees(90),
                endAngle: .degrees(180 - alphaDeg),
                clockwise: false
            )
            head.addArc(
                center: pt(50.0, baseY),
                radius: domeR * s,
                startAngle: .degrees(180 - alphaDeg),
                endAngle: .degrees(alphaDeg),
                clockwise: false
            )
            head.addArc(
                center: pt(50.0 + cornerDX, baseY - cornerR),
                radius: cornerR * s,
                startAngle: .degrees(alphaDeg),
                endAngle: .degrees(90),
                clockwise: false
            )
            head.closeSubpath()
            ctx.stroke(head, with: .color(tint), style: stroke)

            // Eyes
            ctx.fill(Path(ellipseIn: rect(36.5 - 3.8, 58.5 - 3.8, 7.6, 7.6)), with: .color(tint))
            ctx.fill(Path(ellipseIn: rect(63.5 - 3.8, 58.5 - 3.8, 7.6, 7.6)), with: .color(tint))
        }
        .accessibilityHidden(true)
    }
}
