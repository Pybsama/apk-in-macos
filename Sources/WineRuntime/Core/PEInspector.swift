import AppKit
import CryptoKit
import Foundation

/// Pure-Swift offline inspector for Windows `.exe` (PE32 / PE32+) and `.msi` packages.
/// Extracts architecture, subsystem, version metadata, installer hints, and embedded `.rsrc` icons
/// without spawning Wine.
public enum PEInspector {
    public static func inspect(path: String, iconCacheDir: URL? = nil) -> PEExecutableInfo {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let fallbackName = prettifyStem(url.deletingPathExtension().lastPathComponent)

        if ext == "msi" {
            return PEExecutableInfo(
                sourcePath: path,
                displayName: fallbackName,
                versionName: "1.0",
                architecture: "msi",
                isConsoleSubsystem: false,
                inputKind: .msiInstaller,
                iconPath: nil,
                incompatibilityReason: nil
            )
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 64 else {
            return PEExecutableInfo(
                sourcePath: path,
                displayName: fallbackName,
                versionName: "1.0",
                architecture: "unknown",
                incompatibilityReason: L10n.t("无法读取该文件", "Could not read file")
            )
        }

        var info = inspectData(data, sourcePath: path, fallbackName: fallbackName, iconCacheDir: iconCacheDir)
        if info.incompatibilityReason == nil, info.inputKind == .portableExe {
            info = enrichForAppFrameworks(info, exeURL: url, iconCacheDir: iconCacheDir)
        }
        return info
    }

    /// Detects NW.js (RPG Maker MV/MZ, TyranoBuilder, Construct, HTML5 games) and Electron/CEF
    /// frameworks living alongside the `.exe`, upgrading all NW.js-family games to the native
    /// Apple Silicon NW.js backend (60 FPS Metal + native CoreText CJK + native macOS input)
    /// and adding `--in-process-gpu` flags for Win32 Electron/CEF apps under Wine.
    public static func enrichForAppFrameworks(
        _ base: PEExecutableInfo,
        exeURL: URL,
        iconCacheDir: URL?
    ) -> PEExecutableInfo {
        let fm = FileManager.default
        let dir = exeURL.deletingLastPathComponent()

        // NW.js markers cover both modern NW.js (nw.dll / nw_elf.dll) and legacy NW.js 0.12
        // used by older RPG Maker MV / TyranoBuilder / Construct releases (nw.pak / nw_100_percent.pak).
        let companyLower = (base.companyName ?? "").lowercased()
        let nameLower = base.displayName.lowercased()
        let exeLower = exeURL.lastPathComponent.lowercased()
        let hasNWMarker = fm.fileExists(atPath: dir.appendingPathComponent("nw.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("nw_elf.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("nw.pak").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("nw_100_percent.pak").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("www/js/rpg_core.js").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("js/rmmz_core.js").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("tyrano/tyrano.js").path)
            || exeLower == "nw.exe"
            || companyLower.contains("nw.js")
            || companyLower.contains("node-webkit")
            || nameLower == "nwjs"

        // Locate package.json in root folder or `www/package.json`
        let pkgRoots = [dir, dir.appendingPathComponent("www", isDirectory: true)]
        if hasNWMarker,
           let matchedRoot = pkgRoots.first(where: { root in
               let pkg = root.appendingPathComponent("package.json")
               guard let d = try? Data(contentsOf: pkg),
                     let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
               return obj["main"] is String
           }),
           let pkgData = try? Data(contentsOf: matchedRoot.appendingPathComponent("package.json")),
           let json = (try? JSONSerialization.jsonObject(with: pkgData)) as? [String: Any] {
            let winDict = json["window"] as? [String: Any]

            let folderTitle = prettifyGameFolderName(dir.lastPathComponent)
            let pkgTitle = (winDict?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosenName: String
            if !folderTitle.isEmpty && !["downloads", "desktop", "documents", "www", "game"].contains(folderTitle.lowercased()) {
                chosenName = folderTitle
            } else if let pkgTitle, !pkgTitle.isEmpty {
                chosenName = pkgTitle
            } else if let pkgName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !pkgName.isEmpty {
                chosenName = pkgName
            } else {
                chosenName = base.displayName
            }

            var resolvedIcon = base.iconPath
            var iconCandidates: [URL] = []
            if let relIcon = winDict?["icon"] as? String, !relIcon.isEmpty {
                iconCandidates.append(matchedRoot.appendingPathComponent(relIcon))
                iconCandidates.append(dir.appendingPathComponent(relIcon))
            }
            iconCandidates.append(contentsOf: [
                dir.appendingPathComponent("www/icon/icon.png"),
                dir.appendingPathComponent("icon/icon.png"),
                dir.appendingPathComponent("icons/icon-256.png"),
                dir.appendingPathComponent("data/others/icon.png")
            ])

            if let foundIcon = iconCandidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                if let iconCacheDir {
                    try? fm.createDirectory(at: iconCacheDir, withIntermediateDirectories: true)
                    let digest = SHA256.hash(data: Data(foundIcon.path.utf8))
                        .prefix(8).map { String(format: "%02x", $0) }.joined()
                    let cached = iconCacheDir.appendingPathComponent("nw-\(digest).png")
                    try? fm.removeItem(at: cached)
                    if (try? fm.copyItem(at: foundIcon, to: cached)) != nil {
                        resolvedIcon = cached.path
                    } else {
                        resolvedIcon = foundIcon.path
                    }
                } else {
                    resolvedIcon = foundIcon.path
                }
            }

            return PEExecutableInfo(
                sourcePath: base.sourcePath,
                displayName: chosenName,
                versionName: base.versionName,
                companyName: base.companyName,
                architecture: base.architecture,
                isConsoleSubsystem: false,
                inputKind: .portableExe,
                recommendedBackend: .nativeNWJS,
                recommendedWorkingDir: matchedRoot.path,
                recommendedArguments: [],
                iconPath: resolvedIcon,
                incompatibilityReason: nil
            )
        }

        // Non-NW.js Chromium / Electron / CEF Win32 app: pass --in-process-gpu so winemac.drv
        // keeps the GPU surface inside the top-level HWND process instead of a blank frame.
        let isChromiumFamily = fm.fileExists(atPath: dir.appendingPathComponent("chrome_elf.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("libcef.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("resources/app.asar").path)
            || (fm.fileExists(atPath: dir.appendingPathComponent("libGLESv2.dll").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("resources.pak").path))

        if isChromiumFamily {
            var resolvedName = base.displayName
            if resolvedName.lowercased() == "electron" || resolvedName.lowercased() == "game" {
                let appPkg = dir.appendingPathComponent("resources/app/package.json")
                if let d = try? Data(contentsOf: appPkg),
                   let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   let prod = (obj["productName"] as? String ?? obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !prod.isEmpty {
                    resolvedName = prod
                } else {
                    let folder = prettifyGameFolderName(dir.lastPathComponent)
                    if !folder.isEmpty { resolvedName = folder }
                }
            }

            return PEExecutableInfo(
                sourcePath: base.sourcePath,
                displayName: resolvedName,
                versionName: base.versionName,
                companyName: base.companyName,
                architecture: base.architecture,
                isConsoleSubsystem: base.isConsoleSubsystem,
                inputKind: base.inputKind,
                recommendedBackend: .wine,
                recommendedWorkingDir: dir.path,
                recommendedArguments: ["--in-process-gpu", "--use-gl=swiftshader", "--disable-gpu-compositing", "--no-sandbox"],
                iconPath: base.iconPath,
                incompatibilityReason: nil
            )
        }

        // Unity Engine RPG / 2D·3D games: force Direct3D 11 so DXVK -> MoltenVK (Metal) handles
        // rendering cleanly instead of Unity trying unsupported DX12 on open-source Wine.
        let stem = exeURL.deletingPathExtension().lastPathComponent
        let isUnity = fm.fileExists(atPath: dir.appendingPathComponent("UnityPlayer.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("\(stem)_Data").path)
        if isUnity {
            let resolvedName = preferFolderIfGeneric(base.displayName, folderName: dir.lastPathComponent)
            return PEExecutableInfo(
                sourcePath: base.sourcePath,
                displayName: resolvedName,
                versionName: base.versionName,
                companyName: base.companyName,
                architecture: base.architecture,
                isConsoleSubsystem: base.isConsoleSubsystem,
                inputKind: base.inputKind,
                recommendedBackend: .wine,
                recommendedLocale: detectJapaneseHint(in: dir, title: resolvedName) ? .jaJP : .auto,
                recommendedWorkingDir: dir.path,
                recommendedArguments: ["-force-d3d11"],
                iconPath: base.iconPath,
                incompatibilityReason: nil
            )
        }

        // Classic RPG Maker XP / VX / VX Ace (Game.ini + RGSS*.dll), Wolf RPG, Kirikiri/KAG:
        // extract true game title from Game.ini and auto-select Japanese (Shift-JIS) locale when needed.
        let dirItems = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let hasRGSS = dirItems.contains { $0.lowercased().hasPrefix("rgss") && $0.lowercased().hasSuffix(".dll") }
        let gameIniURL = dir.appendingPathComponent("Game.ini")
        let hasWolfOrKrkr = fm.fileExists(atPath: dir.appendingPathComponent("GuruGuruSMF4.dll").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("Data.wolf").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("data.xp3").path)

        if (hasRGSS && fm.fileExists(atPath: gameIniURL.path)) || hasWolfOrKrkr {
            let iniTitle = parseGameIniTitle(at: gameIniURL)
            let chosenTitle: String
            if let iniTitle, !iniTitle.isEmpty {
                chosenTitle = iniTitle
            } else {
                chosenTitle = preferFolderIfGeneric(base.displayName, folderName: dir.lastPathComponent)
            }
            let isJP = detectJapaneseHint(in: dir, title: chosenTitle)
                || dirItems.contains { $0.lowercased().hasPrefix("rgss10") && $0.lowercased().hasSuffix("j.dll") }
            return PEExecutableInfo(
                sourcePath: base.sourcePath,
                displayName: chosenTitle,
                versionName: base.versionName,
                companyName: base.companyName,
                architecture: base.architecture,
                isConsoleSubsystem: base.isConsoleSubsystem,
                inputKind: base.inputKind,
                recommendedBackend: .wine,
                recommendedLocale: isJP ? .jaJP : .auto,
                recommendedWorkingDir: dir.path,
                recommendedArguments: [],
                iconPath: base.iconPath,
                incompatibilityReason: nil
            )
        }

        // Ren'Py Visual Novel / RPG: clean name and preserve folder working directory
        if fm.fileExists(atPath: dir.appendingPathComponent("renpy").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("game").path) {
            let resolvedName = preferFolderIfGeneric(base.displayName, folderName: dir.lastPathComponent)
            return PEExecutableInfo(
                sourcePath: base.sourcePath,
                displayName: resolvedName,
                versionName: base.versionName,
                companyName: base.companyName,
                architecture: base.architecture,
                isConsoleSubsystem: false,
                inputKind: base.inputKind,
                recommendedBackend: .wine,
                recommendedLocale: detectJapaneseHint(in: dir, title: resolvedName) ? .jaJP : .auto,
                recommendedWorkingDir: dir.path,
                recommendedArguments: [],
                iconPath: base.iconPath,
                incompatibilityReason: nil
            )
        }

        return base
    }

    private static func preferFolderIfGeneric(_ name: String, folderName: String) -> String {
        let genericNames: Set<String> = ["game", "player", "launcher", "start", "run", "nwjs", "electron"]
        if genericNames.contains(name.lowercased()) {
            let cleaned = prettifyGameFolderName(folderName)
            if !cleaned.isEmpty && !["downloads", "desktop", "documents"].contains(cleaned.lowercased()) {
                return cleaned
            }
        }
        return name
    }

    private static func parseGameIniTitle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .shiftJIS)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("title=") {
                let val = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    /// Detects Hiragana or Katakana characters in title or immediate directory names to
    /// automatically choose Japanese Shift-JIS locale (`ja_JP.UTF-8`) for untranslated JP RPGs.
    private static func detectJapaneseHint(in dir: URL, title: String) -> Bool {
        func hasKana(_ s: String) -> Bool {
            for scalar in s.unicodeScalars {
                if (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value) {
                    return true
                }
            }
            return false
        }
        if hasKana(title) || hasKana(dir.lastPathComponent) { return true }
        return false
    }

    private static func prettifyGameFolderName(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: "(?i)\\s*[-_(\\[]*\\s*(windows|win64|win32|pc|x64|x86)\\s*[)\\]]*$",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func inspectData(
        _ data: Data,
        sourcePath: String,
        fallbackName: String,
        iconCacheDir: URL? = nil
    ) -> PEExecutableInfo {
        let r = ByteReader(data)
        guard r.u16(0) == 0x5A4D, let peOffsetU32 = r.u32(0x3C) else {
            return PEExecutableInfo(
                sourcePath: sourcePath,
                displayName: fallbackName,
                versionName: "1.0",
                architecture: "unknown",
                incompatibilityReason: L10n.t("不是有效的 Windows 可执行文件", "Not a valid Windows executable")
            )
        }

        let peOffset = Int(peOffsetU32)
        guard r.u32(peOffset) == 0x0000_4550 else {
            return PEExecutableInfo(
                sourcePath: sourcePath,
                displayName: fallbackName,
                versionName: "1.0",
                architecture: "dos16",
                incompatibilityReason: L10n.t("不支持 16 位 DOS / 旧版 Windows 程序", "16-bit DOS / legacy Windows executables are not supported")
            )
        }

        let coff = peOffset + 4
        guard let machine = r.u16(coff),
              let numSections = r.u16(coff + 2),
              let optHeaderSize = r.u16(coff + 16) else {
            return PEExecutableInfo(
                sourcePath: sourcePath,
                displayName: fallbackName,
                versionName: "1.0",
                architecture: "unknown",
                incompatibilityReason: L10n.t("PE 文件头已损坏", "Corrupted PE header")
            )
        }

        let arch: String
        var incompatibility: String?
        switch machine {
        case 0x8664: arch = "x86_64"
        case 0x014C: arch = "x86"
        case 0xAA64:
            arch = "arm64"
            incompatibility = L10n.t(
                "当前 Wine 运行时仅支持 x86 / x64 Windows 程序（此文件为 Windows ARM64）",
                "Current Wine runtime supports x86/x64 Windows apps (this binary is Windows ARM64)"
            )
        default:
            arch = String(format: "0x%04X", machine)
        }

        let opt = coff + 20
        let magic = r.u16(opt) ?? 0
        let subsystem = r.u16(opt + 68) ?? 2
        let isConsole = (subsystem == 3)

        let ddBase: Int?
        if magic == 0x010B {
            ddBase = opt + 96
        } else if magic == 0x020B {
            ddBase = opt + 112
        } else {
            ddBase = nil
        }

        var sections: [PESection] = []
        let secStart = opt + Int(optHeaderSize)
        for i in 0..<min(Int(numSections), 96) {
            let s = secStart + i * 40
            guard let vSize = r.u32(s + 8),
                  let vAddr = r.u32(s + 12),
                  let rawSize = r.u32(s + 16),
                  let rawPtr = r.u32(s + 20) else { break }
            sections.append(PESection(virtualSize: vSize, virtualAddress: vAddr, rawSize: rawSize, rawPointer: rawPtr))
        }

        var versionStrings: [String: String] = [:]
        var manifestText = ""
        var savedIconPath: String?

        if let ddBase,
           let rsrcRVA = r.u32(ddBase + 2 * 8),
           let rsrcSize = r.u32(ddBase + 2 * 8 + 4),
           rsrcRVA > 0, rsrcSize > 0,
           let rsrcBase = rvaToOffset(rsrcRVA, sections: sections, fileSize: data.count) {
            let resources = parseResources(reader: r, rsrcBase: rsrcBase, sections: sections)

            if let verBlob = resources.versionBlobs.first {
                versionStrings = parseVersionInfo(verBlob)
            }
            if let manBlob = resources.manifestBlobs.first,
               let text = String(data: manBlob, encoding: .utf8) {
                manifestText = text
            }
            if let iconCacheDir,
               let icoData = buildICOData(groupBlobs: resources.groupIconBlobs, iconsById: resources.iconsById) {
                savedIconPath = renderICOToPNG(icoData: icoData, sourcePath: sourcePath, cacheDir: iconCacheDir)
            }
        }

        let isInstaller = detectInstaller(
            fileName: URL(fileURLWithPath: sourcePath).lastPathComponent,
            versionStrings: versionStrings,
            manifest: manifestText
        )

        let chosenName = chooseDisplayName(
            fallback: fallbackName,
            versionStrings: versionStrings,
            isInstaller: isInstaller
        )
        let version = cleanVersion(versionStrings["ProductVersion"] ?? versionStrings["FileVersion"] ?? "1.0")
        let company = versionStrings["CompanyName"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        return PEExecutableInfo(
            sourcePath: sourcePath,
            displayName: chosenName,
            versionName: version,
            companyName: (company?.isEmpty == true) ? nil : company,
            architecture: arch,
            isConsoleSubsystem: isConsole,
            inputKind: isInstaller ? .installerExe : .portableExe,
            iconPath: savedIconPath,
            incompatibilityReason: incompatibility
        )
    }

    // MARK: - Installer & Name Heuristics

    public static func detectInstaller(
        fileName: String,
        versionStrings: [String: String],
        manifest: String
    ) -> Bool {
        let lowerName = fileName.lowercased()
        let stem = URL(fileURLWithPath: lowerName).deletingPathExtension().lastPathComponent
        let namePatterns = [
            "(^|[-_. ])(setup|install|installer|autorun)($|[-_. 0-9])",
            "-setup$", "_setup$", "setup$"
        ]
        for pat in namePatterns {
            if stem.range(of: pat, options: .regularExpression) != nil {
                return true
            }
        }

        let haystack = [
            manifest,
            versionStrings["Comments"] ?? "",
            versionStrings["FileDescription"] ?? "",
            versionStrings["ProductName"] ?? "",
            versionStrings["InternalName"] ?? ""
        ].joined(separator: "\n").lowercased()

        let markers = [
            "inno setup",
            "nullsoft install system",
            "nsis",
            "installshield",
            "wix burn",
            "windows installer",
            "self-extracting",
            "7z setup sfx"
        ]
        return markers.contains { haystack.contains($0) }
    }

    public static func isAuxiliaryUninstallerOrUpdater(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let skipPrefixes = ["unins", "uninstall", "updater", "update", "crashpad", "crashreporter", "vc_redist", "dxsetup"]
        return skipPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func chooseDisplayName(
        fallback: String,
        versionStrings: [String: String],
        isInstaller: Bool
    ) -> String {
        let candidates = [
            versionStrings["ProductName"],
            versionStrings["FileDescription"]
        ]
        for raw in candidates {
            guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { continue }
            if isInstaller {
                s = s.replacingOccurrences(of: "(?i)\\s*(setup|installer|installation wizard)$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let generic = [
                "setup", "installer", "application", "bootstrapper", "7z setup sfx",
                "wine", "microsoft® windows® operating system", "windows® operating system"
            ]
            if !s.isEmpty && !generic.contains(s.lowercased()) {
                return s
            }
        }
        return fallback
    }

    private static func prettifyStem(_ stem: String) -> String {
        let cleaned = stem
            .replacingOccurrences(of: "(?i)[-_.]?(setup|installer|win64|win32|x64|x86|amd64|portable)$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[_]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? stem : cleaned
    }

    private static func cleanVersion(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: ", ", with: ".")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "1.0" : normalized
    }

    // MARK: - Resource Tree Walking

    private struct PESection {
        let virtualSize: UInt32
        let virtualAddress: UInt32
        let rawSize: UInt32
        let rawPointer: UInt32
    }

    private struct ExtractedResources {
        var iconsById: [Int: Data] = [:]
        var groupIconBlobs: [Data] = []
        var versionBlobs: [Data] = []
        var manifestBlobs: [Data] = []
    }

    private static func rvaToOffset(_ rva: UInt32, sections: [PESection], fileSize: Int) -> Int? {
        for s in sections {
            let span = max(s.virtualSize, s.rawSize)
            if rva >= s.virtualAddress && rva < s.virtualAddress &+ span {
                let delta = rva - s.virtualAddress
                guard delta < s.rawSize else { return nil }
                let fileOff = Int(s.rawPointer) + Int(delta)
                return (fileOff >= 0 && fileOff < fileSize) ? fileOff : nil
            }
        }
        return nil
    }

    private static func parseResources(reader r: ByteReader, rsrcBase: Int, sections: [PESection]) -> ExtractedResources {
        var out = ExtractedResources()
        // Level 1: Resource Types (3 = RT_ICON, 14 = RT_GROUP_ICON, 16 = RT_VERSION, 24 = RT_MANIFEST)
        for typeEntry in directoryEntries(reader: r, rsrcBase: rsrcBase, dirOffset: 0) {
            guard typeEntry.isSubdir, !typeEntry.isNamed else { continue }
            let typeId = typeEntry.id
            guard typeId == 3 || typeId == 14 || typeId == 16 || typeId == 24 else { continue }

            // Level 2: Resource Name / Integer ID
            for nameEntry in directoryEntries(reader: r, rsrcBase: rsrcBase, dirOffset: typeEntry.targetOffset) {
                if nameEntry.isSubdir {
                    // Level 3: Language
                    for langEntry in directoryEntries(reader: r, rsrcBase: rsrcBase, dirOffset: nameEntry.targetOffset) where !langEntry.isSubdir {
                        guard let blob = readDataEntry(reader: r, rsrcBase: rsrcBase, dataEntryOffset: langEntry.targetOffset, sections: sections) else { continue }
                        storeResource(typeId: typeId, nameId: nameEntry.id, blob: blob, into: &out)
                        break // first language variant per ID is sufficient
                    }
                } else if let blob = readDataEntry(reader: r, rsrcBase: rsrcBase, dataEntryOffset: nameEntry.targetOffset, sections: sections) {
                    storeResource(typeId: typeId, nameId: nameEntry.id, blob: blob, into: &out)
                }
            }
        }
        return out
    }

    private static func storeResource(typeId: Int, nameId: Int, blob: Data, into out: inout ExtractedResources) {
        switch typeId {
        case 3:
            if out.iconsById[nameId] == nil { out.iconsById[nameId] = blob }
        case 14:
            out.groupIconBlobs.append(blob)
        case 16:
            out.versionBlobs.append(blob)
        case 24:
            out.manifestBlobs.append(blob)
        default:
            break
        }
    }

    private struct DirEntry {
        let isNamed: Bool
        let id: Int
        let isSubdir: Bool
        let targetOffset: Int
    }

    private static func directoryEntries(reader r: ByteReader, rsrcBase: Int, dirOffset: Int) -> [DirEntry] {
        let base = rsrcBase + dirOffset
        guard let named = r.u16(base + 12), let ids = r.u16(base + 14) else { return [] }
        let count = min(Int(named) + Int(ids), 256)
        var list: [DirEntry] = []
        for i in 0..<count {
            let e = base + 16 + i * 8
            guard let nameOrId = r.u32(e), let offset = r.u32(e + 4) else { break }
            list.append(DirEntry(
                isNamed: (nameOrId & 0x8000_0000) != 0,
                id: Int(nameOrId & 0xFFFF),
                isSubdir: (offset & 0x8000_0000) != 0,
                targetOffset: Int(offset & 0x7FFF_FFFF)
            ))
        }
        return list
    }

    private static func readDataEntry(reader r: ByteReader, rsrcBase: Int, dataEntryOffset: Int, sections: [PESection]) -> Data? {
        let de = rsrcBase + dataEntryOffset
        guard let dataRVA = r.u32(de), let size = r.u32(de + 4),
              size > 0, size <= 16 * 1024 * 1024,
              let fileOff = rvaToOffset(dataRVA, sections: sections, fileSize: r.count) else {
            return nil
        }
        return r.slice(fileOff, Int(size))
    }

    // MARK: - Reconstruct .ICO and Render PNG

    public static func buildICOData(groupBlobs: [Data], iconsById: [Int: Data]) -> Data? {
        for grp in groupBlobs {
            let gr = ByteReader(grp)
            guard gr.u16(0) == 0, gr.u16(2) == 1, let countU16 = gr.u16(4), countU16 > 0 else { continue }
            let count = min(Int(countU16), 64)

            struct Frame {
                let header8: Data
                let payload: Data
            }
            var frames: [Frame] = []
            for i in 0..<count {
                let entryOff = 6 + i * 14
                guard let header8 = gr.slice(entryOff, 8),
                      let iconId = gr.u16(entryOff + 12),
                      let payload = iconsById[Int(iconId)], !payload.isEmpty else { continue }
                frames.append(Frame(header8: header8, payload: payload))
            }
            guard !frames.isEmpty else { continue }

            var ico = Data()
            ico.append(contentsOf: [0, 0, 1, 0])
            ico.appendU16LE(UInt16(frames.count))

            var dataOffset = 6 + frames.count * 16
            for f in frames {
                ico.append(f.header8)
                ico.appendU32LE(UInt32(f.payload.count))
                ico.appendU32LE(UInt32(dataOffset))
                dataOffset += f.payload.count
            }
            for f in frames {
                ico.append(f.payload)
            }
            return ico
        }

        // Fallback: wrap largest standalone RT_ICON if present
        if let best = iconsById.values.max(by: { $0.count < $1.count }), !best.isEmpty {
            var ico = Data([0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 32, 0])
            ico.appendU32LE(UInt32(best.count))
            ico.appendU32LE(22)
            ico.append(best)
            return ico
        }
        return nil
    }

    private static func renderICOToPNG(icoData: Data, sourcePath: String, cacheDir: URL) -> String? {
        guard let img = NSImage(data: icoData) else { return nil }
        let bestRep = img.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }
        let targetPx = 256
        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetPx, pixelsHigh: targetPx,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        outRep.size = NSSize(width: targetPx, height: targetPx)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: targetPx, height: targetPx)
        if let bestRep {
            bestRep.draw(in: rect)
        } else {
            img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = outRep.representation(using: .png, properties: [:]) else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(sourcePath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let dst = cacheDir.appendingPathComponent("exe-\(digest).png")
        try? png.write(to: dst, options: .atomic)
        return dst.path
    }

    // MARK: - VS_VERSIONINFO UTF-16LE StringTable Parser

    public static func parseVersionInfo(_ blob: Data) -> [String: String] {
        var result: [String: String] = [:]
        let r = ByteReader(blob)

        func walkNode(at start: Int, limit: Int, parentKey: String) {
            let aligned = (start + 3) & ~3
            guard aligned + 6 <= limit,
                  let lengthU16 = r.u16(aligned),
                  let valLenU16 = r.u16(aligned + 2),
                  let wType = r.u16(aligned + 4) else { return }
            let length = Int(lengthU16)
            guard length >= 6 else { return }
            let nodeEnd = min(aligned + length, limit)

            let (key, afterKey) = r.utf16ZString(at: aligned + 6, limit: nodeEnd)
            let valAligned = (afterKey + 3) & ~3
            let valBytes = (wType == 1) ? Int(valLenU16) * 2 : Int(valLenU16)
            let childrenStart = (valAligned + valBytes + 3) & ~3

            if parentKey == "StringTable", wType == 1, valBytes > 0, valAligned < nodeEnd {
                let (val, _) = r.utf16ZString(at: valAligned, limit: min(valAligned + valBytes, nodeEnd))
                if !key.isEmpty && !val.isEmpty && result[key] == nil {
                    result[key] = val
                }
            }

            let nextParent: String
            if key == "StringFileInfo" {
                nextParent = "StringFileInfo"
            } else if parentKey == "StringFileInfo" {
                nextParent = "StringTable"
            } else {
                nextParent = key
            }

            var cursor = childrenStart
            while cursor + 6 <= nodeEnd {
                let curAligned = (cursor + 3) & ~3
                guard let childLen = r.u16(curAligned), childLen >= 6 else { break }
                walkNode(at: curAligned, limit: nodeEnd, parentKey: nextParent)
                cursor = curAligned + Int(childLen)
            }
        }

        walkNode(at: 0, limit: blob.count, parentKey: "")
        return result
    }
}

// MARK: - Safe Little-Endian Reader & Writer

private struct ByteReader {
    let bytes: [UInt8]
    var count: Int { bytes.count }

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else { return nil }
        return Data(bytes[offset..<(offset + length)])
    }

    func utf16ZString(at offset: Int, limit: Int) -> (String, Int) {
        var units: [UInt16] = []
        var p = offset
        while p + 2 <= limit && p + 2 <= bytes.count {
            let u = UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8)
            p += 2
            if u == 0 { break }
            units.append(u)
        }
        return (String(utf16CodeUnits: units, count: units.count), p)
    }
}

private extension Data {
    mutating func appendU16LE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendU32LE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
