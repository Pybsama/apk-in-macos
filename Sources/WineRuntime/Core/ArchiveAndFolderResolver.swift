import CryptoKit
import Foundation

/// Resolves dropped game folders and `.zip` archives into a primary launchable `.exe`,
/// automatically handling Japanese (Shift-JIS / CP932) and Chinese (GB18030 / Big5)
/// ZIP filename encodings that macOS Archive Utility corrupts.
public enum ArchiveAndFolderResolver {
    private static let auxiliaryExactNames: Set<String> = [
        "notification_helper.exe",
        "unitycrashhandler32.exe",
        "unitycrashhandler64.exe",
        "crashhandler.exe",
        "dxsetup.exe",
        "dxwebsetup.exe",
        "vcredist_x64.exe",
        "vcredist_x86.exe",
        "vc_redist.x64.exe",
        "vc_redist.x86.exe",
        "config.exe",
        "settings.exe",
        "register.exe",
        "language.exe",
        "helper.exe",
        "nacl64.exe"
    ]

    public static func isSupportedDropURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Skip macOS `.app` bundles if someone accidentally drops one.
            return url.pathExtension.lowercased() != "app"
        }
        let ext = url.pathExtension.lowercased()
        return ext == "exe" || ext == "msi" || ext == "zip"
    }

    public static func extractZipWithSmartEncoding(zipURL: URL, into destRoot: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let rawStem = zipURL.deletingPathExtension().lastPathComponent
        let safeStem = WineEngine.makeAppSlug(name: rawStem, seedPath: zipURL.path)
        let targetDir = destRoot.appendingPathComponent(safeStem, isDirectory: true)
        if fm.fileExists(atPath: targetDir.path) {
            try? fm.removeItem(at: targetDir)
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let pyScript = """
        import os, shutil, sys, zipfile

        zip_path, dest_dir = sys.argv[1], os.path.realpath(sys.argv[2])

        def decode_name(info):
            if info.flag_bits & 0x800:
                return info.filename
            raw = info.filename.encode('cp437', errors='replace')
            for enc in ('utf-8', 'cp932', 'gb18030', 'cp950'):
                try:
                    return raw.decode(enc)
                except UnicodeDecodeError:
                    continue
            return info.filename

        with zipfile.ZipFile(zip_path, 'r') as zf:
            for info in zf.infolist():
                name = decode_name(info).replace('\\\\', '/')
                if not name or name.startswith('__MACOSX/') or name.endswith('/__MACOSX') or os.path.basename(name) == '.DS_Store':
                    continue
                rel = os.path.normpath(name)
                if rel in ('.', '') or rel.startswith('..') or os.path.isabs(rel):
                    raise ValueError('Unsafe path in archive: ' + name)
                out_path = os.path.realpath(os.path.join(dest_dir, rel))
                if not (out_path == dest_dir or out_path.startswith(dest_dir + os.sep)):
                    raise ValueError('Path escapes destination: ' + name)
                if info.is_dir():
                    os.makedirs(out_path, exist_ok=True)
                    continue
                os.makedirs(os.path.dirname(out_path), exist_ok=True)
                with zf.open(info, 'r') as src, open(out_path, 'wb') as dst:
                    shutil.copyfileobj(src, dst, 1024 * 1024)
                mode = (info.external_attr >> 16) & 0o777
                if mode:
                    try:
                        os.chmod(out_path, mode | 0o600)
                    except OSError:
                        pass
        """

        let res = try await ShellCommand.run(
            "/usr/bin/python3",
            args: ["-c", pyScript, zipURL.path, targetDir.path],
            timeout: 300
        )
        guard res.ok else {
            try? fm.removeItem(at: targetDir)
            let msg = (res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw WineRuntimeError.archiveExtractionFailed(msg)
        }

        // Unwrap single top-level wrapper folder when an archive contains only one root directory.
        let topEntries = (try? fm.contentsOfDirectory(
            at: targetDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        if topEntries.count == 1,
           (try? topEntries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return topEntries[0]
        }
        return targetDir
    }

    public static func findPrimaryExecutable(in folder: URL) -> URL? {
        let candidates = collectExecutables(in: folder, depth: 0, maxDepth: 3)
        guard !candidates.isEmpty else { return nil }

        let folderNameLower = folder.lastPathComponent.lowercased()
        let fm = FileManager.default
        var scored: [(score: Int, url: URL)] = []

        for (url, depth) in candidates {
            let fileNameLower = url.lastPathComponent.lowercased()
            if PEInspector.isAuxiliaryUninstallerOrUpdater(fileName: fileNameLower)
                || auxiliaryExactNames.contains(fileNameLower) {
                continue
            }

            let info = PEInspector.inspect(path: url.path, iconCacheDir: nil)
            let dir = url.deletingLastPathComponent()
            let stemLower = url.deletingPathExtension().lastPathComponent.lowercased()

            var score = 0
            if info.recommendedBackend == .nativeNWJS {
                score += 100
            }
            let isUnity = fm.fileExists(atPath: dir.appendingPathComponent("UnityPlayer.dll").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_Data").path)
            let isClassicRPGMaker = fm.fileExists(atPath: dir.appendingPathComponent("Game.ini").path)
            let isRenPy = fm.fileExists(atPath: dir.appendingPathComponent("renpy").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("game").path)
            if isUnity || isClassicRPGMaker || isRenPy {
                score += 85
            }

            if !info.isConsoleSubsystem && info.incompatibilityReason == nil {
                score += 40
            }
            if info.incompatibilityReason != nil {
                score -= 50
            }

            score -= depth * 15
            if stemLower == folderNameLower || stemLower == "game" || stemLower == "nw" {
                score += 20
            }
            scored.append((score, url))
        }

        return scored.max(by: {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.url.path > $1.url.path
        })?.url
    }

    private static func collectExecutables(in folder: URL, depth: Int, maxDepth: Int) -> [(URL, Int)] {
        guard depth <= maxDepth else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(URL, Int)] = []
        for entry in entries {
            let ext = entry.pathExtension.lowercased()
            if ext == "exe" {
                found.append((entry, depth))
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      ext != "app" {
                found.append(contentsOf: collectExecutables(in: entry, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return found
    }
}
