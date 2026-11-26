import APKRuntime
import Foundation
import Observation

/// Observable mirror of `RuntimeSettings`, so the "⋯ → Performance" menu shows live checkmarks.
@Observable
@MainActor
final class RuntimePreferences {
    static let shared = RuntimePreferences()

    var idleSleep: Bool { didSet { RuntimeSettings.idleSleepEnabled = idleSleep } }
    var slimSystem: Bool { didSet { RuntimeSettings.slimSystemEnabled = slimSystem } }
    var quickBoot: Bool { didSet { RuntimeSettings.quickBootEnabled = quickBoot } }
    var memoryMB: Int { didSet { RuntimeSettings.memoryMB = memoryMB } }

    private init() {
        idleSleep = RuntimeSettings.idleSleepEnabled
        slimSystem = RuntimeSettings.slimSystemEnabled
        quickBoot = RuntimeSettings.quickBootEnabled
        memoryMB = RuntimeSettings.memoryMB
    }
}
