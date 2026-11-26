import APKRuntime
import AppKit
import Foundation

@MainActor
public final class WindowCoordinator {
    private var openControllers: [String: AppWindowController] = [:]
    private var stagger = 0

    public var activeKeys: Set<String> { Set(openControllers.keys) }
    public var onActiveKeysChanged: ((Set<String>) -> Void)?
    public var onWindowSizeSaved: ((String, Int, Int) -> Void)?
    public var onShortcutRequested: ((AndroidAppItem) -> Void)?

    public func openWindow(for item: AndroidAppItem, engine: SandboxEngine, mode: ChannelMode = .isolatedDisplay) async throws {
        let key = (mode == .mainScreen) ? "__main__" : item.packageName
        if let existing = openControllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if mode == .mainScreen {
                await existing.switchApp(item)
            }
            return
        }

        let ctrl = AppWindowController(
            key: key,
            item: item,
            mode: mode,
            engine: engine,
            width: item.windowWidth,
            height: item.windowHeight,
            staggerIndex: stagger
        )
        stagger += 1
        bind(ctrl)
        openControllers[key] = ctrl
        onActiveKeysChanged?(activeKeys)

        do {
            try await ctrl.start()
        } catch {
            ctrl.closeNow()
            openControllers.removeValue(forKey: key)
            onActiveKeysChanged?(activeKeys)
            throw error
        }
    }

    public func openMainScreen(engine: SandboxEngine) async throws {
        let key = "__main__"
        if let existing = openControllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let ctrl = AppWindowController(
            key: key,
            item: nil,
            mode: .mainScreen,
            engine: engine,
            width: 390,
            height: 720,
            staggerIndex: stagger
        )
        stagger += 1
        bind(ctrl)
        openControllers[key] = ctrl
        onActiveKeysChanged?(activeKeys)

        do {
            try await ctrl.start()
        } catch {
            ctrl.closeNow()
            openControllers.removeValue(forKey: key)
            onActiveKeysChanged?(activeKeys)
            throw error
        }
    }

    public func close(key: String) {
        openControllers[key]?.closeNow()
        openControllers.removeValue(forKey: key)
        onActiveKeysChanged?(activeKeys)
    }

    public func closeAll() {
        let list = Array(openControllers.values)
        openControllers.removeAll()
        for c in list { c.closeNow() }
        onActiveKeysChanged?(activeKeys)
    }

    private func bind(_ ctrl: AppWindowController) {
        ctrl.onClosed = { [weak self] k in
            guard let self else { return }
            self.openControllers.removeValue(forKey: k)
            self.onActiveKeysChanged?(self.activeKeys)
        }
        ctrl.onSizeSaved = { [weak self] pkg, w, h in
            self?.onWindowSizeSaved?(pkg, w, h)
        }
        ctrl.onShortcutRequested = { [weak self] item in
            self?.onShortcutRequested?(item)
        }
    }
}
