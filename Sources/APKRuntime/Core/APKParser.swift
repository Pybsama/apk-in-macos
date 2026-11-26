import Foundation

public enum APKParseError: LocalizedError {
    case notFound(String)
    case missingAapt2
    case invalidAPK(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return L10n.t("找不到 APK 文件：\(path)", "APK file not found: \(path)")
        case .missingAapt2: return L10n.t("Android SDK 缺少 aapt2，无法识别 APK", "aapt2 is missing from the Android SDK, so the APK cannot be read")
        case .invalidAPK(let msg): return L10n.t("无法解析 APK：\(msg)", "Could not read APK: \(msg)")
        }
    }
}

public enum APKParser {
    public static let supportedExtensions: Set<String> = ["apk", "xapk", "apkm"]

    public struct BadgingIcon: Equatable, Sendable {
        public let density: Int
        public let entryPath: String
    }

    public struct BadgingResult: Equatable, Sendable {
        public let packageName: String
        public let appName: String
        public let versionName: String
        public let versionCode: String
        public let launchableActivity: String?
        public let nativeABIs: [String]
        public let rasterIcons: [BadgingIcon]
    }

    /// Keeps base APKs and ARM64/DPI/locale splits while filtering out incompatible ABI splits
    /// (e.g. `armeabi_v7a`, `x86`, `x86_64`) that fail `adb install-multiple` on an ARM64 emulator.
    public static func filterCompatibleSplitAPKs(_ paths: [String]) -> [String] {
        paths.filter { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name.contains("arm64") { return true }
            if name.contains("armeabi") || name.contains("x86_64") || name.contains("x86") {
                return false
            }
            return true
        }
    }

    public static func inspect(apkPath: String, aapt2Path: String?, iconCacheDir: URL) async throws -> APKPackageInfo {
        guard FileManager.default.fileExists(atPath: apkPath) else {
            throw APKParseError.notFound(apkPath)
        }
        guard let aapt2 = aapt2Path else {
            throw APKParseError.missingAapt2
        }

        let ext = URL(fileURLWithPath: apkPath).pathExtension.lowercased()
        if ext == "xapk" || ext == "apkm" {
            return try await inspectSplitBundle(bundlePath: apkPath, aapt2: aapt2, iconCacheDir: iconCacheDir)
        }

        return try await inspectSingleAPK(apkPath: apkPath, aapt2: aapt2, iconCacheDir: iconCacheDir)
    }

    private static func inspectSingleAPK(apkPath: String, aapt2: String, iconCacheDir: URL) async throws -> APKPackageInfo {
        let res = try await ShellCommand.run(aapt2, args: ["dump", "badging", apkPath], timeout: 30)
        guard res.ok else {
            let msg = res.stderr.isEmpty ? res.stdout : res.stderr
            throw APKParseError.invalidAPK(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let parsed = try parseBadging(res.stdout)
        var chosenEntry = parsed.rasterIcons.max(by: { $0.density < $1.density })?.entryPath
        if chosenEntry == nil {
            chosenEntry = await scanZipForIcon(apkPath: apkPath)
        }

        var savedIconPath: String?
        if let entry = chosenEntry, !entry.lowercased().hasSuffix(".xml") {
            savedIconPath = try await extractIcon(apkPath: apkPath, entry: entry, pkg: parsed.packageName, into: iconCacheDir)
        }

        return APKPackageInfo(
            apkPath: apkPath,
            packageName: parsed.packageName,
            appName: parsed.appName,
            versionName: parsed.versionName,
            versionCode: parsed.versionCode,
            launchableActivity: parsed.launchableActivity,
            nativeABIs: parsed.nativeABIs,
            iconPath: savedIconPath
        )
    }

    private static func inspectSplitBundle(bundlePath: String, aapt2: String, iconCacheDir: URL) async throws -> APKPackageInfo {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory.appendingPathComponent("xapk-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let unzipRes = try await ShellCommand.run("/usr/bin/unzip", args: ["-q", "-o", bundlePath, "-d", extractDir.path], timeout: 120)
        guard unzipRes.ok else {
            try? fm.removeItem(at: extractDir)
            throw APKParseError.invalidAPK(unzipRes.stderr.isEmpty ? unzipRes.stdout : unzipRes.stderr)
        }

        let (allAPKs, obbs) = collectSplitPayloads(in: extractDir)

        let compatible = filterCompatibleSplitAPKs(allAPKs).sorted()
        guard !compatible.isEmpty else {
            try? fm.removeItem(at: extractDir)
            throw APKParseError.invalidAPK(L10n.t("分包中未找到兼容的 ARM64 APK", "No compatible ARM64 APK found inside archive"))
        }

        var basePath: String? = compatible.first(where: { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "base.apk" })
        if basePath == nil {
            for candidate in compatible {
                if let res = try? await ShellCommand.run(aapt2, args: ["dump", "badging", candidate], timeout: 20),
                   res.ok,
                   let parsed = try? parseBadging(res.stdout),
                   parsed.launchableActivity != nil {
                    basePath = candidate
                    break
                }
            }
        }
        let chosenBase = basePath ?? compatible.max(by: {
            let s0 = (try? fm.attributesOfItem(atPath: $0)[.size] as? Int64) ?? 0
            let s1 = (try? fm.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0
            return s0 < s1
        }) ?? compatible[0]

        var info = try await inspectSingleAPK(apkPath: chosenBase, aapt2: aapt2, iconCacheDir: iconCacheDir)
        var resolvedIcon = info.iconPath
        let topIcon = extractDir.appendingPathComponent("icon.png")
        if resolvedIcon == nil, fm.fileExists(atPath: topIcon.path) {
            try? fm.createDirectory(at: iconCacheDir, withIntermediateDirectories: true)
            let safe = info.packageName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            let dst = iconCacheDir.appendingPathComponent("\(safe).png")
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: topIcon, to: dst)) != nil {
                resolvedIcon = dst.path
            }
        }

        info = APKPackageInfo(
            apkPath: info.apkPath,
            packageName: info.packageName,
            appName: info.appName,
            versionName: info.versionName,
            versionCode: info.versionCode,
            launchableActivity: info.launchableActivity,
            nativeABIs: info.nativeABIs,
            iconPath: resolvedIcon,
            splitAPKPaths: compatible,
            obbPayloads: obbs,
            tempExtractDir: extractDir.path
        )
        return info
    }

    private static func collectSplitPayloads(in extractDir: URL) -> (apks: [String], obbs: [OBBPayload]) {
        let fm = FileManager.default
        var allAPKs: [String] = []
        var obbs: [OBBPayload] = []
        if let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let fext = fileURL.pathExtension.lowercased()
                if fext == "apk" {
                    allAPKs.append(fileURL.path)
                } else if fext == "obb" {
                    obbs.append(OBBPayload(localPath: fileURL.path, remoteFileName: fileURL.lastPathComponent))
                }
            }
        }
        return (allAPKs, obbs)
    }

    public static func parseBadging(_ raw: String) throws -> BadgingResult {
        var pkg = ""
        var verCode = ""
        var verName = ""
        var labelDefault = ""
        var labelZhCN = ""
        var labelZh = ""
        var activity: String?
        var abis: [String] = []
        var icons: [BadgingIcon] = []

        for sub in raw.split(whereSeparator: \.isNewline) {
            let line = String(sub).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("package:") {
                pkg = quotedValue(in: line, key: "name") ?? pkg
                verCode = quotedValue(in: line, key: "versionCode") ?? verCode
                verName = quotedValue(in: line, key: "versionName") ?? verName
            } else if line.hasPrefix("application-label-zh-CN:") {
                labelZhCN = colonQuoted(line) ?? labelZhCN
            } else if line.hasPrefix("application-label-zh:") || line.hasPrefix("application-label-zh_CN:") {
                labelZh = colonQuoted(line) ?? labelZh
            } else if line.hasPrefix("application-label:") {
                labelDefault = colonQuoted(line) ?? labelDefault
            } else if line.hasPrefix("launchable-activity:") && activity == nil {
                activity = quotedValue(in: line, key: "name")
            } else if line.hasPrefix("native-code:") {
                abis = allQuotedValues(in: line)
            } else if line.hasPrefix("application-icon-"), let colon = line.firstIndex(of: ":") {
                let dStr = String(line[..<colon]).replacingOccurrences(of: "application-icon-", with: "")
                let density = Int(dStr) ?? 0
                if let path = colonQuoted(line) {
                    let lower = path.lowercased()
                    if lower.hasSuffix(".png") || lower.hasSuffix(".webp") || lower.hasSuffix(".jpg") {
                        icons.append(BadgingIcon(density: density, entryPath: path))
                    }
                }
            } else if line.hasPrefix("application:") {
                if labelDefault.isEmpty, let l = quotedValue(in: line, key: "label") {
                    labelDefault = l
                }
                if let ic = quotedValue(in: line, key: "icon") {
                    let lower = ic.lowercased()
                    if lower.hasSuffix(".png") || lower.hasSuffix(".webp") {
                        icons.append(BadgingIcon(density: 320, entryPath: ic))
                    }
                }
            }
        }

        guard !pkg.isEmpty else {
            throw APKParseError.invalidAPK(L10n.t("缺少有效 package 名称", "missing a valid package name"))
        }
        let name = [labelZhCN, labelZh, labelDefault, pkg]
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? pkg

        return BadgingResult(
            packageName: pkg,
            appName: name,
            versionName: verName,
            versionCode: verCode,
            launchableActivity: activity,
            nativeABIs: abis,
            rasterIcons: icons
        )
    }

    private static func scanZipForIcon(apkPath: String) async -> String? {
        guard let res = try? await ShellCommand.run("/usr/bin/unzip", args: ["-Z1", apkPath], timeout: 15), res.ok else {
            return nil
        }
        let candidates = res.stdout.split(whereSeparator: \.isNewline).map(String.init).filter { path in
            let l = path.lowercased()
            return l.hasPrefix("res/") && (l.hasSuffix(".png") || l.hasSuffix(".webp"))
                && (l.contains("ic_launcher") || l.contains("app_icon") || l.contains("icon"))
        }
        func rank(_ p: String) -> Int {
            let l = p.lowercased()
            var s = 0
            if l.contains("xxxhdpi") { s += 640 }
            else if l.contains("xxhdpi") { s += 480 }
            else if l.contains("xhdpi") { s += 320 }
            else if l.contains("hdpi") { s += 240 }
            if l.contains("ic_launcher.png") || l.contains("ic_launcher.webp") { s += 200 }
            if l.contains("foreground") { s -= 150 }
            if l.contains("background") { s -= 200 }
            return s
        }
        return candidates.max(by: { rank($0) < rank($1) })
    }

    private static func extractIcon(apkPath: String, entry: String, pkg: String, into dir: URL) async throws -> String? {
        let raw = try await ShellCommand.runRaw("/usr/bin/unzip", args: ["-p", apkPath, entry], timeout: 15)
        guard raw.exitCode == 0, !raw.stdout.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = (entry as NSString).pathExtension.lowercased()
        let safe = pkg.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let out = dir.appendingPathComponent("\(safe).\(ext.isEmpty ? "png" : ext)")
        try raw.stdout.write(to: out)
        return out.path
    }

    private static func quotedValue(in line: String, key: String) -> String? {
        let needle = "\(key)='"
        guard let r = line.range(of: needle) else { return nil }
        let tail = line[r.upperBound...]
        guard let end = tail.firstIndex(of: "'") else { return nil }
        return String(tail[..<end])
    }

    private static func colonQuoted(_ line: String) -> String? {
        guard let c = line.firstIndex(of: ":") else { return nil }
        let rest = line[line.index(after: c)...]
        guard let q1 = rest.firstIndex(of: "'") else { return nil }
        let after = rest[rest.index(after: q1)...]
        guard let q2 = after.firstIndex(of: "'") else { return nil }
        return String(after[..<q2])
    }

    private static func allQuotedValues(in line: String) -> [String] {
        var out: [String] = []
        var idx = line.startIndex
        while idx < line.endIndex {
            guard let q1 = line[idx...].firstIndex(of: "'") else { break }
            let next = line.index(after: q1)
            guard next < line.endIndex, let q2 = line[next...].firstIndex(of: "'") else { break }
            out.append(String(line[next..<q2]))
            idx = line.index(after: q2)
        }
        return out
    }
}
