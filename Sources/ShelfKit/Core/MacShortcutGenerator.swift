import Foundation

/// Specification for generating a standalone double-clickable macOS `.app` launcher
/// that opens a specific guest application via its host shelf app's URL scheme.
public struct MacShortcutSpec: Sendable {
    public let identifier: String
    public let displayName: String
    public let versionName: String
    public let versionCode: String
    public let iconPath: String?
    public let bundlePrefix: String
    public let deepLinkURL: String

    public init(
        identifier: String,
        displayName: String,
        versionName: String = "1.0",
        versionCode: String = "1",
        iconPath: String? = nil,
        bundlePrefix: String,
        deepLinkURL: String
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.versionName = versionName
        self.versionCode = versionCode
        self.iconPath = iconPath
        self.bundlePrefix = bundlePrefix
        self.deepLinkURL = deepLinkURL
    }
}

public enum MacShortcutGenerator {
    public static func cleanAppName(_ name: String, fallback: String) -> String {
        let stripped = name
            .replacingOccurrences(of: "[/:\\\\*?\"<>|]", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? fallback : stripped
    }

    public static func build(
        spec: MacShortcutSpec,
        hostAppPath: String,
        in folder: URL
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let displayName = cleanAppName(spec.displayName, fallback: spec.identifier)
        let appURL = folder.appendingPathComponent("\(displayName).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resDir = contents.appendingPathComponent("Resources", isDirectory: true)

        if fm.fileExists(atPath: appURL.path) {
            try fm.removeItem(at: appURL)
        }
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resDir, withIntermediateDirectories: true)

        let icnsURL = resDir.appendingPathComponent("AppIcon.icns")
        try await SquircleIconMaker.buildICNS(from: spec.iconPath, fallbackName: displayName, to: icnsURL)

        let safeID = spec.identifier.lowercased().replacingOccurrences(of: "[^a-z0-9.-]", with: "-", options: .regularExpression)
        let plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "zh_CN",
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "open-app",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": "\(spec.bundlePrefix).\(safeID)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": spec.versionName.isEmpty ? "1.0" : spec.versionName,
            "CFBundleVersion": spec.versionCode.isEmpty ? "1" : spec.versionCode,
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let script = """
        #!/bin/bash
        set -euo pipefail
        HOST_APP=\(shellQuote(hostAppPath))
        LINK=\(shellQuote(spec.deepLinkURL))
        if [[ -d "$HOST_APP" ]]; then
          /usr/bin/open -a "$HOST_APP" "$LINK"
        else
          /usr/bin/open "$LINK"
        fi
        """
        let bin = macOSDir.appendingPathComponent("open-app")
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        _ = try? await ShellCommand.run("/usr/bin/codesign", args: ["--force", "--deep", "--sign", "-", appURL.path], timeout: 20)
        let lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fm.isExecutableFile(atPath: lsreg) {
            _ = try? await ShellCommand.run(lsreg, args: ["-f", appURL.path], timeout: 10)
        }
        return appURL
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
