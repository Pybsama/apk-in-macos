import Foundation

public enum WineSandboxState: Equatable, Sendable {
    case idle
    case downloadingRuntime(progressText: String)
    case initializingBottle
    case ready(wineVersion: String)
    case stopping
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isTransitioning: Bool {
        switch self {
        case .downloadingRuntime, .initializingBottle, .stopping:
            return true
        default:
            return false
        }
    }
}

public enum WineInputKind: String, Codable, Equatable, Sendable {
    case portableExe
    case installerExe
    case msiInstaller
}

public struct PEExecutableInfo: Equatable, Sendable {
    public let sourcePath: String
    public let displayName: String
    public let versionName: String
    public let companyName: String?
    public let architecture: String
    public let isConsoleSubsystem: Bool
    public let inputKind: WineInputKind
    public let recommendedBackend: WindowsExecutionBackend
    public let recommendedLocale: WindowsAppLocale
    public let recommendedWorkingDir: String?
    public let recommendedArguments: [String]
    public let iconPath: String?
    public let incompatibilityReason: String?

    public init(
        sourcePath: String,
        displayName: String,
        versionName: String,
        companyName: String? = nil,
        architecture: String,
        isConsoleSubsystem: Bool = false,
        inputKind: WineInputKind = .portableExe,
        recommendedBackend: WindowsExecutionBackend = .wine,
        recommendedLocale: WindowsAppLocale = .auto,
        recommendedWorkingDir: String? = nil,
        recommendedArguments: [String] = [],
        iconPath: String? = nil,
        incompatibilityReason: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.displayName = displayName
        self.versionName = versionName
        self.companyName = companyName
        self.architecture = architecture
        self.isConsoleSubsystem = isConsoleSubsystem
        self.inputKind = inputKind
        self.recommendedBackend = recommendedBackend
        self.recommendedLocale = recommendedLocale
        self.recommendedWorkingDir = recommendedWorkingDir
        self.recommendedArguments = recommendedArguments
        self.iconPath = iconPath
        self.incompatibilityReason = incompatibilityReason
    }
}

public enum WineRuntimeError: LocalizedError {
    case rosettaRequired
    case wineNotFound
    case nwjsNotFound
    case downloadFailed(String)
    case checksumMismatch
    case extractionFailed(String)
    case prefixInitFailed(String)
    case executableMissing(String)
    case noExecutableInFolder(String)
    case archiveExtractionFailed(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rosettaRequired:
            return L10n.t(
                "需要安装 Rosetta 2 才能运行 Windows 程序（终端执行：softwareupdate --install-rosetta）",
                "Rosetta 2 is required to run Windows apps (run: softwareupdate --install-rosetta)"
            )
        case .wineNotFound:
            return L10n.t("未找到可用的 Wine 运行时", "Wine runtime could not be found")
        case .nwjsNotFound:
            return L10n.t("未找到原生 NW.js 运行时", "Native NW.js runtime could not be found")
        case .downloadFailed(let msg):
            return L10n.t("下载运行时失败：\(msg)", "Failed to download runtime: \(msg)")
        case .checksumMismatch:
            return L10n.t("下载的运行时安装包校验不通过，请重试", "Downloaded runtime archive failed SHA-256 verification; please retry")
        case .extractionFailed(let msg):
            return L10n.t("解压运行时失败：\(msg)", "Failed to extract runtime: \(msg)")
        case .prefixInitFailed(let msg):
            return L10n.t("初始化 Windows 环境失败：\(msg)", "Failed to initialize Windows bottle: \(msg)")
        case .executableMissing(let path):
            return L10n.t("找不到可执行文件：\(path)", "Executable file not found: \(path)")
        case .noExecutableInFolder(let name):
            return L10n.t("在「\(name)」中未找到可运行的 .exe 主程序", "No runnable .exe found inside \"\(name)\"")
        case .archiveExtractionFailed(let msg):
            return L10n.t("解压压缩包失败：\(msg)", "Failed to extract ZIP archive: \(msg)")
        case .launchFailed(let msg):
            return L10n.t("启动程序失败：\(msg)", "Failed to launch app: \(msg)")
        }
    }
}
