import Foundation

/// User-tunable preferences for the Windows runtime.
public enum WineRuntimeSettings {
    public static let idleSleepKey = "wine.idleSleep"
    public static let retinaModeKey = "wine.retinaModeV2"
    public static let dxvkKey = "wine.dxvkEnabled"

    /// Shut down `wineserver` after all Windows processes have exited for this long.
    public static let idleSleepAfter: TimeInterval = 120

    private static var defaults: UserDefaults { .standard }

    public static var idleSleepEnabled: Bool {
        get { defaults.object(forKey: idleSleepKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: idleSleepKey) }
    }

    /// Defaults to `false` because Wine's experimental `RetinaMode="Y"` halves Win32 client
    /// coordinates and breaks child-HWND compositing in Direct3D / Chromium apps.
    public static var retinaModeEnabled: Bool {
        get { defaults.object(forKey: retinaModeKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: retinaModeKey) }
    }

    /// Hardware Direct3D 10/11 → Vulkan → MoltenVK (Metal) acceleration via DXVK-macOS.
    public static var dxvkEnabled: Bool {
        get { defaults.object(forKey: dxvkKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: dxvkKey) }
    }
}
