import Foundation

public enum WineShortcutBuilder {
    public static var shortcutsFolder: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Applications/EXE in macOS", isDirectory: true)
    }

    public static func deepLink(for appId: String) -> String {
        var c = URLComponents()
        c.scheme = "exeinmacos"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "id", value: appId)]
        return c.string ?? "exeinmacos://open?id=\(appId)"
    }

    public static func createMacAppShortcut(
        for item: WindowsAppItem,
        hostAppPath: String,
        in folder: URL = shortcutsFolder
    ) async throws -> URL {
        let spec = MacShortcutSpec(
            identifier: item.id,
            displayName: item.appName,
            versionName: item.versionName,
            versionCode: "1",
            iconPath: item.iconPath,
            bundlePrefix: "dev.exeinmacos.app",
            deepLinkURL: deepLink(for: item.id)
        )
        return try await MacShortcutGenerator.build(spec: spec, hostAppPath: hostAppPath, in: folder)
    }
}
