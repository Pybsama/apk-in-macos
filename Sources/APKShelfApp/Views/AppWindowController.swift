import APKRuntime
import AppKit
import SwiftUI

@MainActor
public final class AppWindowController: NSWindowController, NSWindowDelegate, BridgeClientDelegate {
    public let key: String
    public private(set) var item: AndroidAppItem?
    public let mode: ChannelMode

    private let engine: SandboxEngine
    private let surface = DisplaySurfaceView(frame: NSRect(x: 0, y: 0, width: 390, height: 720))
    private let bridge: BridgeClient
    private let decoder: H264DecoderFeed

    private let barModel = AppWindowBarModel()
    private let coverModel = AppWindowCoverModel()
    private var coverView: NSHostingView<AppWindowCover>?

    private var resizeWork: DispatchWorkItem?
    private var resizingByCode = false
    private var closed = false
    private var paintedFirstFrame = false

    private let barHeight: CGFloat = 34

    public var onClosed: ((String) -> Void)?
    public var onSizeSaved: ((String, Int, Int) -> Void)?
    public var onShortcutRequested: ((AndroidAppItem) -> Void)?

    public init(
        key: String,
        item: AndroidAppItem?,
        mode: ChannelMode,
        engine: SandboxEngine,
        width: Int,
        height: Int,
        staggerIndex: Int
    ) {
        self.key = key
        self.item = item
        self.mode = mode
        self.engine = engine
        self.bridge = BridgeClient(port: SandboxEngine.bridgePort)
        self.decoder = H264DecoderFeed(displayLayer: surface.videoLayer)

        let title = item?.appName ?? L10n.t("Android 主屏幕", "Android Home Screen")
        let w = CGFloat(max(320, min(width, 1100)))
        let h = CGFloat(max(440, min(height, 880))) + barHeight

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.appearance = NSAppearance(named: .aqua)
        win.title = title
        win.minSize = NSSize(width: 300, height: 360)
        win.isReleasedWhenClosed = false
        win.backgroundColor = IvoryTheme.nsCanvas
        win.titlebarAppearsTransparent = true
        win.collectionBehavior = [.fullScreenAuxiliary]

        if let screen = NSScreen.main?.visibleFrame {
            let dx = CGFloat(staggerIndex % 4) * 52
            let dy = CGFloat(staggerIndex % 4) * 26
            let x = min(screen.maxX - w - 28, max(screen.minX + 36, screen.midX - w / 2 + dx))
            let y = max(screen.minY + 28, min(screen.maxY - h - 28, screen.midY - h / 2 - dy))
            win.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            win.center()
        }

        super.init(window: win)
        win.delegate = self

        barModel.hasApp = (item != nil)
        coverModel.name = title
        coverModel.iconPath = item?.iconPath

        assembleUI(in: win)
        wireEvents()

        bridge.delegate = self
        decoder.onNeedSyncFrame = { [weak self] in
            self?.bridge.requestSyncFrame()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func assembleUI(in win: NSWindow) {
        let root = NSView(frame: win.contentRect(forFrameRect: win.frame))
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = IvoryTheme.nsCanvas.cgColor

        let bar = NSHostingView(rootView: AppWindowBar(
            model: barModel,
            onBack: { [weak self] in self?.bridge.tapKey(AndroidKey.back) },
            onHome: { [weak self] in self?.bridge.tapKey(AndroidKey.home) },
            onRecents: { [weak self] in self?.bridge.tapKey(AndroidKey.recents) },
            onRotate: { [weak self] in self?.rotate() },
            onPreset: { [weak self] preset in self?.applyPreset(preset) },
            onPaste: { [weak self] in self?.pasteClipboard() },
            onRelaunch: { [weak self] in Task { await self?.relaunchCurrentApp() } },
            onShortcut: { [weak self] in
                if let item = self?.item { self?.onShortcutRequested?(item) }
            }
        ))
        bar.translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false

        let cover = NSHostingView(rootView: AppWindowCover(model: coverModel))
        cover.translatesAutoresizingMaskIntoConstraints = false
        self.coverView = cover

        root.addSubview(bar)
        root.addSubview(surface)
        root.addSubview(cover)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),

            surface.topAnchor.constraint(equalTo: bar.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            cover.topAnchor.constraint(equalTo: surface.topAnchor),
            cover.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])

        win.contentView = root
    }

    private func wireEvents() {
        surface.onTouch = { [weak self] act, nx, ny in self?.bridge.touch(action: act, x: nx, y: ny) }
        surface.onScroll = { [weak self] nx, ny, dx, dy in self?.bridge.scroll(x: nx, y: ny, dx: dx, dy: dy) }
        surface.onKey = { [weak self] act, kc, meta in self?.bridge.key(action: act, code: kc, meta: meta) }
        surface.onText = { [weak self] str in self?.bridge.text(str) }
        surface.onPaste = { [weak self] str in self?.bridge.pasteClipboard(str) }
        surface.onDropFiles = { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                self.barModel.notice = L10n.t("正在传送文件…", "Sending files…")
                do {
                    let count = try await self.engine.pushFilesToDownload(urls)
                    self.barModel.notice = count > 0
                        ? L10n.t("已发送到 Download (\(count))", "Sent \(count) file(s) to Download")
                        : L10n.t("未传送文件", "No files sent")
                } catch {
                    self.barModel.notice = error.localizedDescription
                }
                let shown = self.barModel.notice
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.barModel.notice == shown {
                    self.barModel.notice = ""
                }
            }
        }
    }

    private func retinaMetrics(for pointSize: CGSize) -> (w: Int32, h: Int32, dpi: Int32) {
        let backing = min(2.0, max(1.0, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0))
        let pw = max(240.0, pointSize.width)
        let ph = max(240.0, pointSize.height)
        var scale = backing
        let largest = max(pw, ph)
        if largest * scale > 1600.0 {
            scale = max(1.0, 1600.0 / largest)
        }
        let pxW = align16(Int32(round(pw * scale)))
        let pxH = align16(Int32(round(ph * scale)))
        let dpi = max(160, min(420, Int32(round(160.0 * scale))))
        return (pxW, pxH, dpi)
    }

    public func start() async throws {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let sz = surface.bounds.size
        let m = retinaMetrics(for: CGSize(width: sz.width > 100 ? sz.width : 390, height: sz.height > 100 ? sz.height : 720))

        try await engine.ensureBridgeReady()
        let ready = try await bridge.open(mode: mode, width: m.w, height: m.h, dpi: m.dpi)
        surface.setStreamDimensions(width: ready.width, height: ready.height)

        if let item {
            try await engine.launch(packageName: item.packageName, activity: item.launchableActivity, onDisplay: ready.displayId)
            try? await Task.sleep(nanoseconds: 220_000_000)
            bridge.requestSyncFrame()
        }
    }

    public func switchApp(_ next: AndroidAppItem) async {
        self.item = next
        window?.title = next.appName
        barModel.hasApp = true
        guard bridge.displayId >= 0 else { return }
        _ = try? await engine.launch(packageName: next.packageName, activity: next.launchableActivity, onDisplay: bridge.displayId)
        bridge.requestSyncFrame()
    }

    public func relaunchCurrentApp() async {
        guard let item, bridge.displayId >= 0 else { return }
        _ = try? await engine.launch(packageName: item.packageName, activity: item.launchableActivity, onDisplay: bridge.displayId)
        bridge.requestSyncFrame()
    }

    private func pasteClipboard() {
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            bridge.pasteClipboard(str)
        }
    }

    private func rotate() {
        let s = surface.bounds.size
        resizeWindow(toPointWidth: max(320, min(1100, s.height)), pointHeight: max(320, min(880, s.width)))
    }

    private func applyPreset(_ preset: SizePreset) {
        resizeWindow(toPointWidth: CGFloat(preset.width), pointHeight: CGFloat(preset.height))
    }

    private func resizeWindow(toPointWidth pw: CGFloat, pointHeight ph: CGFloat) {
        guard let win = window else { return }
        let targetContent = NSSize(width: pw, height: ph + barHeight)
        let targetFrame = win.frameRect(forContentRect: NSRect(origin: .zero, size: targetContent))
        var origin = win.frame.origin
        origin.y += (win.frame.height - targetFrame.height)

        resizingByCode = true
        win.setFrame(NSRect(origin: origin, size: targetFrame.size), display: true, animate: true)
        resizingByCode = false
        pushResize(for: CGSize(width: pw, height: ph))
    }

    private func pushResize(for pointSize: CGSize) {
        let m = retinaMetrics(for: pointSize)
        guard m.w != bridge.width || m.h != bridge.height else { return }
        decoder.prepareForResize()
        bridge.resize(width: m.w, height: m.h, dpi: m.dpi)
        if let pkg = item?.packageName {
            onSizeSaved?(pkg, Int(round(pointSize.width)), Int(round(pointSize.height)))
        }
    }

    public func windowDidResize(_ notification: Notification) {
        guard !resizingByCode, bridge.displayId >= 0 else { return }
        let s = surface.bounds.size
        guard s.width >= 200, s.height >= 200 else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pushResize(for: self.surface.bounds.size)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        guard !resizingByCode, bridge.displayId >= 0 else { return }
        resizeWork?.cancel()
        pushResize(for: surface.bounds.size)
    }

    public func windowWillClose(_ notification: Notification) {
        teardown()
    }

    public func closeNow() {
        teardown()
        window?.close()
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        resizeWork?.cancel()
        bridge.disconnect()
        onClosed?(key)
    }

    private func revealVideoIfNeeded() {
        guard !paintedFirstFrame else { return }
        paintedFirstFrame = true
        guard let cover = coverView else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            cover.animator().alphaValue = 0
        }, completionHandler: { [weak cover] in
            Task { @MainActor in cover?.removeFromSuperview() }
        })
    }

    public nonisolated func bridge(_ client: BridgeClient, didReceiveConfig data: Data) {
        decoder.pushConfig(data)
    }

    public nonisolated func bridge(_ client: BridgeClient, didReceiveFrame data: Data, ptsUs: Int64, isKeyframe: Bool) {
        decoder.pushFrame(data, ptsUs: ptsUs, isKeyframe: isKeyframe)
        Task { @MainActor in self.revealVideoIfNeeded() }
    }

    public nonisolated func bridge(_ client: BridgeClient, didResize width: Int32, height: Int32) {
        Task { @MainActor in self.surface.setStreamDimensions(width: width, height: height) }
    }

    public nonisolated func bridge(_ client: BridgeClient, didClose error: Error?) {
        Task { @MainActor in
            if let error {
                self.barModel.notice = error.localizedDescription
            }
        }
    }

    private func align16(_ v: Int32) -> Int32 { max(16, (v + 8) & ~15) }
}

@Observable
@MainActor
final class AppWindowBarModel {
    var hasApp = false
    var notice = ""
}

@Observable
@MainActor
final class AppWindowCoverModel {
    var name = ""
    var iconPath: String?
}

struct AppWindowCover: View {
    let model: AppWindowCoverModel

    var body: some View {
        ZStack {
            IvoryTheme.canvas
            VStack(spacing: 14) {
                SquircleIconView(path: model.iconPath, name: model.name, size: 58)
                ProgressView().controlSize(.small)
            }
        }
        .preferredColorScheme(.light)
    }
}

struct AppWindowBar: View {
    let model: AppWindowBarModel
    let onBack: () -> Void
    let onHome: () -> Void
    let onRecents: () -> Void
    let onRotate: () -> Void
    let onPreset: (SizePreset) -> Void
    let onPaste: () -> Void
    let onRelaunch: () -> Void
    let onShortcut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    tinyButton("chevron.backward", tip: tr("返回 (Esc / 右键)", "Back (Esc / Right-click)"), action: onBack)
                    tinyButton("circle", tip: tr("主页", "Home"), action: onHome)
                    tinyButton("square.on.square", tip: tr("最近任务", "Recents"), action: onRecents)
                }

                Spacer(minLength: 4)

                if !model.notice.isEmpty {
                    Text(model.notice)
                        .font(.system(size: 11))
                        .foregroundStyle(IvoryTheme.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }

                HStack(spacing: 2) {
                    tinyButton("rotate.right", tip: tr("旋转横竖屏", "Rotate"), action: onRotate)

                    Menu {
                        Section(tr("窗口尺寸", "Window Size")) {
                            ForEach(SizePreset.all) { preset in
                                Button("\(preset.label) (\(preset.width)×\(preset.height))") {
                                    onPreset(preset)
                                }
                            }
                        }
                        Divider()
                        Button(tr("粘贴 Mac 剪贴板 (⌘V)", "Paste Mac Clipboard (⌘V)"), action: onPaste)
                        if model.hasApp {
                            Button(tr("重新唤起应用", "Relaunch App"), action: onRelaunch)
                            Button(tr("更新 Mac 快捷方式", "Update Mac Shortcut"), action: onShortcut)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(IvoryTheme.inkMuted)
                            .frame(width: 26, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IvoryTheme.canvas)

            Rectangle().fill(IvoryTheme.hairline).frame(height: 1)
        }
        .preferredColorScheme(.light)
    }

    private func tinyButton(_ symbol: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(IvoryTheme.inkMuted)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless)
        .help(tip)
    }
}
