import Foundation

public struct OBBPayload: Hashable, Codable, Sendable {
    public let localPath: String
    public let remoteFileName: String

    public init(localPath: String, remoteFileName: String) {
        self.localPath = localPath
        self.remoteFileName = remoteFileName
    }
}

public struct APKPackageInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String { apkPath }
    public let apkPath: String
    public let packageName: String
    public let appName: String
    public let versionName: String
    public let versionCode: String
    public let launchableActivity: String?
    public let nativeABIs: [String]
    public let iconPath: String?
    public let splitAPKPaths: [String]
    public let obbPayloads: [OBBPayload]
    public let tempExtractDir: String?

    public init(
        apkPath: String,
        packageName: String,
        appName: String,
        versionName: String,
        versionCode: String,
        launchableActivity: String?,
        nativeABIs: [String],
        iconPath: String?,
        splitAPKPaths: [String] = [],
        obbPayloads: [OBBPayload] = [],
        tempExtractDir: String? = nil
    ) {
        self.apkPath = apkPath
        self.packageName = packageName
        self.appName = appName
        self.versionName = versionName
        self.versionCode = versionCode
        self.launchableActivity = launchableActivity
        self.nativeABIs = nativeABIs
        self.iconPath = iconPath
        self.splitAPKPaths = splitAPKPaths
        self.obbPayloads = obbPayloads
        self.tempExtractDir = tempExtractDir
    }

    public var isARM64Supported: Bool {
        nativeABIs.isEmpty || nativeABIs.contains("arm64-v8a")
    }

    public var incompatibilityReason: String? {
        guard !isARM64Supported else { return nil }
        let abis = nativeABIs.joined(separator: ", ")
        return L10n.t(
            "仅包含 \(abis) 架构库，当前 Apple Silicon 64 位 ARM64 Android 镜像不支持。",
            "Only contains \(abis) native libraries, which the 64-bit ARM64 Android image on Apple Silicon cannot run."
        )
    }
}

public struct AndroidAppItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { packageName }
    public let packageName: String
    public var appName: String
    public var versionName: String
    public var versionCode: String
    public var launchableActivity: String?
    public var iconPath: String?
    public var shortcutPath: String?
    public var windowWidth: Int
    public var windowHeight: Int
    public var addedAt: Date

    public init(
        packageName: String,
        appName: String,
        versionName: String = "",
        versionCode: String = "",
        launchableActivity: String? = nil,
        iconPath: String? = nil,
        shortcutPath: String? = nil,
        windowWidth: Int = 390,
        windowHeight: Int = 720,
        addedAt: Date = Date()
    ) {
        self.packageName = packageName
        self.appName = appName
        self.versionName = versionName
        self.versionCode = versionCode
        self.launchableActivity = launchableActivity
        self.iconPath = iconPath
        self.shortcutPath = shortcutPath
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.addedAt = addedAt
    }

    public var hasShortcut: Bool {
        guard let p = shortcutPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }
}
