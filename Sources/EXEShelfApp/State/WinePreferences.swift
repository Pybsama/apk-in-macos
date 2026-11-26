import Foundation
import Observation
import WineRuntime

@Observable
@MainActor
final class WinePreferences {
    static let shared = WinePreferences()

    var idleSleep: Bool { didSet { WineRuntimeSettings.idleSleepEnabled = idleSleep } }
    var dxvkEnabled: Bool { didSet { WineRuntimeSettings.dxvkEnabled = dxvkEnabled } }
    var retinaMode: Bool { didSet { WineRuntimeSettings.retinaModeEnabled = retinaMode } }

    private init() {
        idleSleep = WineRuntimeSettings.idleSleepEnabled
        dxvkEnabled = WineRuntimeSettings.dxvkEnabled
        retinaMode = WineRuntimeSettings.retinaModeEnabled
    }
}
