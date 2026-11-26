import Foundation

public enum ChannelMode: UInt8, Sendable {
    case isolatedDisplay = 1
    case mainScreen = 2
}

public struct SizePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let width: Int
    public let height: Int

    public var label: String {
        switch id {
        case "standard": return L10n.t("标准竖屏", "Portrait")
        case "compact": return L10n.t("小巧竖屏", "Compact Portrait")
        case "landscape": return L10n.t("横屏窗口", "Landscape")
        default: return L10n.t("宽屏大窗", "Wide")
        }
    }

    public static let all: [SizePreset] = [
        SizePreset(id: "standard", width: 390, height: 720),
        SizePreset(id: "compact", width: 350, height: 640),
        SizePreset(id: "landscape", width: 760, height: 432),
        SizePreset(id: "wide", width: 880, height: 640)
    ]
}

public enum SandboxState: Equatable, Sendable {
    case idle
    case waking
    case ready(androidVersion: String)
    case stopping
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isTransitioning: Bool {
        switch self {
        case .waking, .stopping: return true
        default: return false
        }
    }
}
