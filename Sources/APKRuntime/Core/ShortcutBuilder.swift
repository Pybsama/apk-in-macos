@_exported import ShelfKit
import Foundation

public enum ShortcutBuilder {
    public static var shortcutsFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Applications/APK in macOS", isDirectory: true)
    }

    public static func cleanAppName(_ name: String, fallback: String) -> String {
        MacShortcutGenerator.cleanAppName(name, fallback: fallback)
    }

    public static func deepLink(for packageName: String) -> String {
        var c = URLComponents()
        c.scheme = "apkinmacos"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "pkg", value: packageName)]
        return c.string ?? "apkinmacos://open?pkg=\(packageName)"
    }

    public static func createMacAppShortcut(
        for item: AndroidAppItem,
        hostAppPath: String,
        in folder: URL = shortcutsFolder
    ) async throws -> URL {
        let spec = MacShortcutSpec(
            identifier: item.packageName,
            displayName: item.appName,
            versionName: item.versionName,
            versionCode: item.versionCode,
            iconPath: item.iconPath,
            bundlePrefix: "dev.apkinmacos.app",
            deepLinkURL: deepLink(for: item.packageName)
        )
        return try await MacShortcutGenerator.build(spec: spec, hostAppPath: hostAppPath, in: folder)
    }
}
