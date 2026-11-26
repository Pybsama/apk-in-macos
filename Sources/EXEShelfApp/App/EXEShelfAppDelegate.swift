import AppKit
import ShelfKit
import SwiftUI
import WineRuntime

@MainActor
public final class EXEShelfAppDelegate: NSObject, NSApplicationDelegate {
    public let store = EXEShelfStore()

    private var shelfWindowController: NSWindowController?
    private var openedByExternalEvent = false

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        handleCLI()
        if !openedByExternalEvent {
            showShelfWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        var links: [URL] = []

        for u in urls {
            if u.isFileURL, ArchiveAndFolderResolver.isSupportedDropURL(u) {
                files.append(u)
            } else if u.scheme?.lowercased() == "exeinmacos" {
                links.append(u)
            }
        }

        if !files.isEmpty {
            openedByExternalEvent = true
            showShelfWindow()
            store.importSilently(urls: files)
        }

        for link in links {
            openedByExternalEvent = true
            let comps = URLComponents(url: link, resolvingAgainstBaseURL: false)
            let appId = comps?.queryItems?.first(where: { $0.name == "id" || $0.name == "app" })?.value
            if let appId, !appId.isEmpty {
                Task { await store.openAppByDeepLink(appId) }
            } else {
                showShelfWindow()
            }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showShelfWindow()
        return true
    }

    public func showShelfWindow() {
        if let existing = shelfWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = ShelfWindowBuilder.makeShelfWindow(
            title: "EXE in macOS",
            rootView: EXEShelfView(store: store)
        )
        let ctrl = NSWindowController(window: win)
        self.shelfWindowController = ctrl
        ctrl.showWindow(nil)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let paths = WineEngine.discoverWine(in: store.engine.runtimeDir) {
            let p = Process()
            #if arch(arm64)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
            p.arguments = ["-x86_64", paths.wineserverBinary, "-k"]
            #else
            p.executableURL = URL(fileURLWithPath: paths.wineserverBinary)
            p.arguments = ["-k"]
            #endif
            var env = ProcessInfo.processInfo.environment
            env["WINEPREFIX"] = store.engine.prefixDir.path
            p.environment = env
            try? p.run()
            p.waitUntilExit()
        }
    }

    private func handleCLI() {
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--open", i + 1 < args.count {
                openedByExternalEvent = true
                let appId = args[i + 1]
                Task { await store.openAppByDeepLink(appId) }
                i += 2
                continue
            } else {
                let u = URL(fileURLWithPath: a)
                if ArchiveAndFolderResolver.isSupportedDropURL(u) {
                    openedByExternalEvent = true
                    showShelfWindow()
                    store.importSilently(urls: [u])
                }
            }
            i += 1
        }
    }
}
