import APKRuntime
import AppKit
import SwiftUI

@MainActor
public final class ShelfAppDelegate: NSObject, NSApplicationDelegate {
    public let store = ShelfStore()

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
        var apks: [URL] = []
        var links: [URL] = []

        for u in urls {
            if u.isFileURL && APKParser.supportedExtensions.contains(u.pathExtension.lowercased()) {
                apks.append(u)
            } else if u.scheme?.lowercased() == "apkinmacos" {
                links.append(u)
            }
        }

        if !apks.isEmpty {
            openedByExternalEvent = true
            showShelfWindow()
            store.installSilently(urls: apks)
        }

        for link in links {
            openedByExternalEvent = true
            let comps = URLComponents(url: link, resolvingAgainstBaseURL: false)
            let pkg = comps?.queryItems?.first(where: { $0.name == "pkg" || $0.name == "package" })?.value
            if let pkg, !pkg.isEmpty {
                Task { await store.openPackageByDeepLink(pkg) }
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
            title: "APK in macOS",
            rootView: ShelfView(store: store)
        )
        let ctrl = NSWindowController(window: win)
        self.shelfWindowController = ctrl
        ctrl.showWindow(nil)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        store.windows.closeAll()
        let candidates = [
            ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"].map { "\($0)/platform-tools/adb" },
            ProcessInfo.processInfo.environment["ANDROID_HOME"].map { "\($0)/platform-tools/adb" },
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        ].compactMap { $0 }

        if let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["-s", SandboxEngine.serial, "emu", "kill"]
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
                let pkg = args[i + 1]
                Task { await store.openPackageByDeepLink(pkg) }
                i += 2
                continue
            } else if APKParser.supportedExtensions.contains(URL(fileURLWithPath: a).pathExtension.lowercased()),
                      FileManager.default.fileExists(atPath: a) {
                openedByExternalEvent = true
                showShelfWindow()
                store.installSilently(urls: [URL(fileURLWithPath: a)])
            }
            i += 1
        }
    }
}
