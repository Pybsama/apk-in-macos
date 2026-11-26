import Foundation

public struct SDKPaths: Sendable, Equatable {
    public let sdkRoot: String
    public let adbPath: String
    public let emulatorPath: String
    public let aapt2Path: String?
    public let systemImageRelPath: String
    public let apiLevel: Int
    public let tagId: String
    public let tagDisplay: String
}

public enum SDKError: LocalizedError {
    case missingSDK(String)
    case missingTool(String)
    case missingARM64Image(String)

    public var errorDescription: String? {
        switch self {
        case .missingSDK(let expected):
            return L10n.t("未找到 Android SDK（默认路径：\(expected)）", "Android SDK not found (expected at \(expected))")
        case .missingTool(let name):
            return L10n.t("Android SDK 中缺少必要组件：\(name)", "Android SDK is missing a required component: \(name)")
        case .missingARM64Image(let root):
            return L10n.t("未在 \(root)/system-images 找到官方 ARM64 (arm64-v8a) 系统镜像", "No official ARM64 (arm64-v8a) system image found in \(root)/system-images")
        }
    }
}

public enum SDKEnvironment {
    public static func discover() throws -> SDKPaths {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["ANDROID_SDK_ROOT"],
            env["ANDROID_HOME"],
            "\(NSHomeDirectory())/Library/Android/sdk"
        ].compactMap { $0 }.filter { !$0.isEmpty }

        guard let root = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            throw SDKError.missingSDK("\(NSHomeDirectory())/Library/Android/sdk")
        }

        let adb = "\(root)/platform-tools/adb"
        guard fm.isExecutableFile(atPath: adb) else { throw SDKError.missingTool("platform-tools/adb") }

        let emulator = "\(root)/emulator/emulator"
        guard fm.isExecutableFile(atPath: emulator) else { throw SDKError.missingTool("emulator/emulator") }

        let aapt2 = findLatestAapt2(root: root)
        let img = try findBestARM64Image(root: root)

        return SDKPaths(
            sdkRoot: root,
            adbPath: adb,
            emulatorPath: emulator,
            aapt2Path: aapt2,
            systemImageRelPath: img.relPath,
            apiLevel: img.api,
            tagId: img.tag,
            tagDisplay: img.display
        )
    }

    private static func findLatestAapt2(root: String) -> String? {
        let fm = FileManager.default
        let bt = "\(root)/build-tools"
        guard let versions = try? fm.contentsOfDirectory(atPath: bt) else { return nil }
        for ver in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let path = "\(bt)/\(ver)/aapt2"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func findBestARM64Image(root: String) throws -> (relPath: String, api: Int, tag: String, display: String) {
        let fm = FileManager.default
        let base = "\(root)/system-images"
        guard let apiDirs = try? fm.contentsOfDirectory(atPath: base) else {
            throw SDKError.missingARM64Image(root)
        }

        var best: (score: Int, rel: String, api: Int, tag: String, display: String)?
        for dir in apiDirs where dir.hasPrefix("android-") {
            guard let api = Int(dir.dropFirst("android-".count)) else { continue }
            guard let tags = try? fm.contentsOfDirectory(atPath: "\(base)/\(dir)") else { continue }
            for tag in tags {
                let sysImg = "\(base)/\(dir)/\(tag)/arm64-v8a/system.img"
                guard fm.fileExists(atPath: sysImg) else { continue }
                let (bonus, display): (Int, String) = switch tag {
                case "google_apis": (30, "Google APIs")
                case "default", "aosp_atd": (20, "AOSP")
                case "google_apis_playstore": (10, "Google Play")
                default: (5, tag)
                }
                let score = api * 100 + bonus
                if best == nil || score > best!.score {
                    best = (score, "system-images/\(dir)/\(tag)/arm64-v8a/", api, tag, display)
                }
            }
        }
        guard let chosen = best else { throw SDKError.missingARM64Image(root) }
        return (chosen.rel, chosen.api, chosen.tag, chosen.display)
    }
}
