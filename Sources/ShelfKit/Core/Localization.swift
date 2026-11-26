import Foundation
import Observation

/// User-selectable interface language. Stored in UserDefaults so both the app layer
/// and runtime error messages resolve the same language.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese = "zh"
    case english = "en"

    public var id: String { rawValue }

    public static let defaultsKey = "app.language"

    /// Name shown in the language picker (always in its own language so it is recognizable).
    public var pickerTitle: String {
        switch self {
        case .system: return L10n.t("跟随系统", "Follow System")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    public static var stored: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw) ?? .system
    }

    /// Concrete language after resolving `.system` against the macOS preferred languages.
    public var resolvedIsEnglish: Bool {
        switch self {
        case .chinese: return false
        case .english: return true
        case .system:
            let first = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return !first.hasPrefix("zh")
        }
    }
}

public enum L10n {
    /// Returns the Chinese or English variant according to the stored language preference.
    public static func t(_ zh: String, _ en: String) -> String {
        AppLanguage.stored.resolvedIsEnglish ? en : zh
    }
}

/// Observable wrapper around the stored language so every SwiftUI surface
/// (shelf, window bars, menus) re-renders instantly when the user switches.
@Observable
@MainActor
public final class LanguageSettings {
    public static let shared = LanguageSettings()

    public var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: AppLanguage.defaultsKey)
            Self.applySystemMenuLanguage(selection)
        }
    }

    private init() {
        selection = AppLanguage.stored
        Self.applySystemMenuLanguage(selection)
    }

    /// AppKit-provided items (Quit, Hide, Services…) follow `AppleLanguages`, applied from next launch.
    private static func applySystemMenuLanguage(_ lang: AppLanguage) {
        switch lang {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .chinese: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }
}

/// Localized string lookup that also registers an observation dependency on the
/// current language, so views calling it inside `body` refresh on change.
@MainActor
public func tr(_ zh: String, _ en: String) -> String {
    LanguageSettings.shared.selection.resolvedIsEnglish ? en : zh
}
