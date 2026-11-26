import Foundation

/// User-tunable resource policy for the background Android runtime.
///
/// Defaults are chosen for "light but unnoticeable": the runtime sleeps when nothing is open,
/// unneeded preinstalled Google services are switched off, and Android gets 3 GB instead of 4 GB.
/// Everything is reversible from the shelf's "⋯ → Performance" menu.
public enum RuntimeSettings {
    public static let idleSleepKey = "runtime.idleSleep"
    public static let slimSystemKey = "runtime.slimSystem"
    public static let memoryKey = "runtime.memoryMB"
    public static let quickBootKey = "runtime.quickBoot"

    /// Memory sizes offered in the menu (MB).
    public static let memoryChoices: [Int] = [2048, 3072, 4096]
    public static let defaultMemoryMB = 3072

    /// After the last Android window closes: lower priority after this grace period…
    public static let backgroundAfter: TimeInterval = 30
    /// …and save a snapshot + shut the runtime down after this much total idle time.
    public static let idleSleepAfter: TimeInterval = 300

    /// Preinstalled packages that nothing on a desktop shelf needs. Play services, WebView,
    /// the keyboard, the launcher and Chrome are deliberately kept because apps rely on them.
    public static let slimPackages: [String] = [
        "com.google.android.googlequicksearchbox",
        "com.google.android.as",
        "com.google.android.as.oss",
        "com.google.android.apps.messaging",
        "com.google.android.apps.wellbeing",
        "com.google.android.apps.youtube.music",
        "com.google.android.youtube",
        "com.google.android.videos",
        "com.google.android.apps.photos",
        "com.google.android.apps.maps",
        "com.google.android.apps.docs",
        "com.google.android.feedback",
    ]

    private static var defaults: UserDefaults { .standard }

    public static var idleSleepEnabled: Bool {
        get { defaults.object(forKey: idleSleepKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: idleSleepKey) }
    }

    public static var slimSystemEnabled: Bool {
        get { defaults.object(forKey: slimSystemKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: slimSystemKey) }
    }

    public static var quickBootEnabled: Bool {
        get { defaults.object(forKey: quickBootKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: quickBootKey) }
    }

    public static var memoryMB: Int {
        get {
            let v = defaults.integer(forKey: memoryKey)
            return memoryChoices.contains(v) ? v : defaultMemoryMB
        }
        set { defaults.set(memoryChoices.contains(newValue) ? newValue : defaultMemoryMB, forKey: memoryKey) }
    }
}
