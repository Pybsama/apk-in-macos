@_exported import ShelfKit
import Foundation

public enum WindowsExecutionBackend: String, Codable, Equatable, Sendable {
    /// Standard Win32 / Win64 executable run through Wine (+ DXVK).
    case wine
    /// NW.js / RPG Maker MV·MZ / HTML5 Windows package run natively via macOS ARM64 NW.js.
    case nativeNWJS
}

/// Per-app Windows ANSI locale (similar to Locale Emulator on Windows), solving mojibake
/// in older non-Unicode RPG Maker XP/VX/VXAce, Wolf RPG, and Kirikiri games.
public enum WindowsAppLocale: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case auto
    case zhCN = "zh_CN.UTF-8"
    case jaJP = "ja_JP.UTF-8"
    case zhTW = "zh_TW.UTF-8"
    case enUS = "en_US.UTF-8"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: return L10n.t("自动检测", "Auto")
        case .zhCN: return L10n.t("简体中文 (GBK)", "Simplified Chinese (GBK)")
        case .jaJP: return L10n.t("日文 (Shift-JIS)", "Japanese (Shift-JIS)")
        case .zhTW: return L10n.t("繁体中文 (Big5)", "Traditional Chinese (Big5)")
        case .enUS: return L10n.t("英文 (US)", "English (US)")
        }
    }
}

public struct WindowsAppItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var appName: String
    public var executablePath: String
    public var workingDirectoryPath: String?
    public var arguments: [String]
    public var backend: WindowsExecutionBackend
    public var locale: WindowsAppLocale
    public var versionName: String
    public var companyName: String?
    public var isConsoleApp: Bool
    public var iconPath: String?
    public var shortcutPath: String?
    public var addedAt: Date

    public init(
        id: String,
        appName: String,
        executablePath: String,
        workingDirectoryPath: String? = nil,
        arguments: [String] = [],
        backend: WindowsExecutionBackend = .wine,
        locale: WindowsAppLocale = .auto,
        versionName: String = "1.0",
        companyName: String? = nil,
        isConsoleApp: Bool = false,
        iconPath: String? = nil,
        shortcutPath: String? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.appName = appName
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
        self.arguments = arguments
        self.backend = backend
        self.locale = locale
        self.versionName = versionName
        self.companyName = companyName
        self.isConsoleApp = isConsoleApp
        self.iconPath = iconPath
        self.shortcutPath = shortcutPath
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, appName, executablePath, workingDirectoryPath, arguments, backend, locale
        case versionName, companyName, isConsoleApp, iconPath, shortcutPath, addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.appName = try c.decode(String.self, forKey: .appName)
        self.executablePath = try c.decode(String.self, forKey: .executablePath)
        self.workingDirectoryPath = try c.decodeIfPresent(String.self, forKey: .workingDirectoryPath)
        self.arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.backend = try c.decodeIfPresent(WindowsExecutionBackend.self, forKey: .backend) ?? .wine
        self.locale = try c.decodeIfPresent(WindowsAppLocale.self, forKey: .locale) ?? .auto
        self.versionName = try c.decodeIfPresent(String.self, forKey: .versionName) ?? "1.0"
        self.companyName = try c.decodeIfPresent(String.self, forKey: .companyName)
        self.isConsoleApp = try c.decodeIfPresent(Bool.self, forKey: .isConsoleApp) ?? false
        self.iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath)
        self.shortcutPath = try c.decodeIfPresent(String.self, forKey: .shortcutPath)
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }
}
