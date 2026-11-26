import CryptoKit
import Foundation

/// On-demand downloader and installer for the official macOS Wine Stable runtime
/// (LGPL, published by the WineHQ macOS package maintainer at Gcenx/macOS_Wine_builds).
/// Supports multi-connection HTTP Range acceleration with cryptographic SHA-256 verification.
public enum WineDownloader {
    public static let releaseVersion = "11.0"
    public static let archiveURL = URL(
        string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz"
    )!
    public static let candidateURLs: [URL] = [
        archiveURL,
        URL(string: "https://gh-proxy.com/https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
        URL(string: "https://ghfast.top/https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!
    ]
    public static let expectedSHA256 = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"

    // Native Apple Silicon NW.js runtime (MIT) for zero-overhead RPG Maker / NW.js games
    public static let nwjsVersion = "0.90.0"
    public static let nwjsCandidateURLs: [URL] = [
        URL(string: "https://cdn.npmmirror.com/binaries/nwjs/v0.90.0/nwjs-v0.90.0-osx-arm64.zip")!,
        URL(string: "https://dl.nwjs.io/v0.90.0/nwjs-v0.90.0-osx-arm64.zip")!
    ]
    public static let nwjsExpectedSHA256 = "71feb1eff04f81e4401b40dec527a220b94dc65e0cdfea04047365999e537a83"

    // DXVK-macOS (zlib/MIT) for Direct3D 10/11 -> MoltenVK (Metal) hardware GPU acceleration
    public static let dxvkCandidateURLs: [URL] = [
        URL(string: "https://gh-proxy.com/https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!,
        URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")!
    ]
    public static let dxvkExpectedSHA256 = "acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477"

    public static func installNWJSRuntime(
        into nwjsDir: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: nwjsDir, withIntermediateDirectories: true)

        onProgress(L10n.t("正在下载原生游戏引擎…", "Downloading native game engine…"))
        let downloaded = try await downloadFromURLList(
            nwjsCandidateURLs,
            envOverrideKey: "NWJS_ARCHIVE_URL",
            labelZh: "下载原生引擎",
            labelEn: "Downloading engine",
            onProgress: onProgress
        )
        defer { try? fm.removeItem(at: downloaded) }

        onProgress(L10n.t("正在校验安装包…", "Verifying archive…"))
        let actualHash = try sha256Hex(of: downloaded)
        guard actualHash.lowercased() == nwjsExpectedSHA256.lowercased() else {
            throw WineRuntimeError.checksumMismatch
        }

        onProgress(L10n.t("正在解压原生引擎…", "Extracting native engine…"))
        let dittoRes = try await ShellCommand.run(
            "/usr/bin/ditto",
            args: ["-x", "-k", downloaded.path, nwjsDir.path],
            timeout: 180
        )
        guard dittoRes.ok else {
            throw WineRuntimeError.extractionFailed(dittoRes.stderr.isEmpty ? dittoRes.stdout : dittoRes.stderr)
        }

        _ = try? await ShellCommand.run("/bin/chmod", args: ["-R", "u+rwX", nwjsDir.path], timeout: 20)
        _ = try? await ShellCommand.run("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", nwjsDir.path], timeout: 20)
    }

    /// Downloads and installs DXVK-macOS (`d3d11.dll`, `d3d10core.dll`) into `drive_c/windows`.
    /// Best-effort: returns `true` when installed so `WineEngine` can enable native DLL overrides.
    public static func installDXVKIfPossible(into driveCDir: URL) async -> Bool {
        let fm = FileManager.default
        let sys64 = driveCDir.appendingPathComponent("windows/system32", isDirectory: true)
        let sys32 = driveCDir.appendingPathComponent("windows/syswow64", isDirectory: true)
        let marker = driveCDir.appendingPathComponent("windows/.dxvk-macos-1.10.3")
        if fm.fileExists(atPath: marker.path) { return true }

        guard let archive = try? await downloadFromURLList(
            dxvkCandidateURLs,
            envOverrideKey: "DXVK_ARCHIVE_URL",
            labelZh: "下载 DXVK",
            labelEn: "Downloading DXVK",
            onProgress: { _ in }
        ) else { return false }
        defer { try? fm.removeItem(at: archive) }

        guard let hash = try? sha256Hex(of: archive),
              hash.lowercased() == dxvkExpectedSHA256.lowercased() else { return false }

        let tmpExtract = fm.temporaryDirectory.appendingPathComponent("dxvk-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpExtract) }

        guard let res = try? await ShellCommand.run("/usr/bin/tar", args: ["-xzf", archive.path, "-C", tmpExtract.path], timeout: 60),
              res.ok else { return false }

        let unpacked = tmpExtract.appendingPathComponent("dxvk-macOS-async-v1.10.3-20230507-repack", isDirectory: true)
        for dll in ["d3d11.dll", "d3d10core.dll"] {
            let src64 = unpacked.appendingPathComponent("x64/\(dll)")
            let dst64 = sys64.appendingPathComponent(dll)
            if fm.fileExists(atPath: src64.path), fm.fileExists(atPath: sys64.path) {
                try? fm.removeItem(at: dst64)
                try? fm.copyItem(at: src64, to: dst64)
            }
            let src32 = unpacked.appendingPathComponent("x32/\(dll)")
            let dst32 = sys32.appendingPathComponent(dll)
            if fm.fileExists(atPath: src32.path), fm.fileExists(atPath: sys32.path) {
                try? fm.removeItem(at: dst32)
                try? fm.copyItem(at: src32, to: dst32)
            }
        }
        try? Data("ok\n".utf8).write(to: marker, options: .atomic)
        return true
    }

    public static let vcRedistURL = URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!

    /// Downloads Microsoft's official Visual C++ Redistributable (x64) installer on demand.
    public static func downloadVCRedistX64(
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        onProgress(L10n.t("正在下载 VC++ 运行库…", "Downloading VC++ Runtime…"))
        return try await downloadFromURLList(
            [vcRedistURL],
            envOverrideKey: "VC_REDIST_URL",
            labelZh: "下载 VC++ 运行库",
            labelEn: "Downloading VC++ Runtime",
            onProgress: onProgress
        )
    }

    public static func installWineRuntime(
        into runtimeDir: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)

        let tmpArchive = runtimeDir.appendingPathComponent("wine-stable-\(releaseVersion).tar.xz.part")
        defer { try? fm.removeItem(at: tmpArchive) }

        onProgress(L10n.t("正在下载 Wine \(releaseVersion)…", "Downloading Wine \(releaseVersion)…"))

        let downloadedURL = try await downloadFromCandidates(onProgress: onProgress)
        defer { try? fm.removeItem(at: downloadedURL) }

        if fm.fileExists(atPath: tmpArchive.path) {
            try? fm.removeItem(at: tmpArchive)
        }
        try fm.moveItem(at: downloadedURL, to: tmpArchive)

        onProgress(L10n.t("正在校验安装包…", "Verifying archive…"))
        let actualHash = try sha256Hex(of: tmpArchive)
        guard actualHash.lowercased() == expectedSHA256.lowercased() else {
            throw WineRuntimeError.checksumMismatch
        }

        onProgress(L10n.t("正在解压 Wine 运行时…", "Extracting Wine runtime…"))
        let tarRes = try await ShellCommand.run(
            "/usr/bin/tar",
            args: ["-xf", tmpArchive.path, "-C", runtimeDir.path],
            timeout: 300
        )
        guard tarRes.ok else {
            throw WineRuntimeError.extractionFailed(tarRes.stderr.isEmpty ? tarRes.stdout : tarRes.stderr)
        }

        // Clear quarantine inside our own Application Support directory so macOS doesn't
        // block LGPL Wine dylibs with modal Gatekeeper popups on first launch.
        _ = try? await ShellCommand.run(
            "/usr/bin/xattr",
            args: ["-dr", "com.apple.quarantine", runtimeDir.path],
            timeout: 30
        )
    }

    private static func downloadFromCandidates(
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        try await downloadFromURLList(
            candidateURLs,
            envOverrideKey: "WINE_ARCHIVE_URL",
            labelZh: "下载 Wine",
            labelEn: "Downloading Wine",
            onProgress: onProgress
        )
    }

    private static func downloadFromURLList(
        _ defaults: [URL],
        envOverrideKey: String,
        labelZh: String,
        labelEn: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        var urls: [URL] = []
        if let custom = ProcessInfo.processInfo.environment[envOverrideKey],
           let customURL = URL(string: custom) {
            urls.append(customURL)
        }
        urls.append(contentsOf: defaults)

        var lastError: Error = WineRuntimeError.downloadFailed("No URLs")
        for url in urls {
            do {
                if url.isFileURL {
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent("rt-local-\(UUID().uuidString)")
                    try FileManager.default.copyItem(at: url, to: copy)
                    return copy
                }
                if let parallelURL = try? await downloadParallelRanges(
                    from: url,
                    segments: 8,
                    labelZh: labelZh,
                    labelEn: labelEn,
                    onProgress: onProgress
                ) {
                    return parallelURL
                }
                return try await downloadSingleStream(from: url, labelZh: labelZh, labelEn: labelEn, onProgress: onProgress)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Probes byte-range support via a 1-byte Range GET (`bytes=0-0`), then downloads in parallel chunks.
    private static func downloadParallelRanges(
        from url: URL,
        segments: Int,
        labelZh: String,
        labelEn: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL? {
        var probe = URLRequest(url: url, timeoutInterval: 15)
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await URLSession.shared.data(for: probe)
        guard let http = resp as? HTTPURLResponse,
              http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let slashIdx = contentRange.lastIndex(of: "/"),
              let totalBytes = Int64(contentRange[contentRange.index(after: slashIdx)...].trimmingCharacters(in: .whitespaces)),
              totalBytes > 4 * 1_048_576 else {
            return nil
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("wine-parts-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let tracker = ParallelProgressTracker(totalBytes: totalBytes, labelZh: labelZh, labelEn: labelEn, onProgress: onProgress)
        let chunkSize = (totalBytes + Int64(segments) - 1) / Int64(segments)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<segments {
                let start = Int64(idx) * chunkSize
                let end = min(totalBytes - 1, Int64(idx + 1) * chunkSize - 1)
                if start > end { continue }
                let partURL = workDir.appendingPathComponent(String(format: "part.%02d", idx))
                group.addTask {
                    try await downloadRangeSegment(
                        from: url,
                        start: start,
                        end: end,
                        destination: partURL,
                        segmentIndex: idx,
                        tracker: tracker
                    )
                }
            }
            try await group.waitForAll()
        }

        let merged = fm.temporaryDirectory.appendingPathComponent("wine-merged-\(UUID().uuidString).tar.xz")
        fm.createFile(atPath: merged.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: merged)
        defer { try? outHandle.close() }

        for idx in 0..<segments {
            let partURL = workDir.appendingPathComponent(String(format: "part.%02d", idx))
            guard fm.fileExists(atPath: partURL.path) else { continue }
            let inHandle = try FileHandle(forReadingFrom: partURL)
            while autoreleasepool(invoking: {
                guard let buf = try? inHandle.read(upToCount: 1_048_576), !buf.isEmpty else { return false }
                try? outHandle.write(contentsOf: buf)
                return true
            }) {}
            try? inHandle.close()
        }
        return merged
    }

    private static func downloadRangeSegment(
        from url: URL,
        start: Int64,
        end: Int64,
        destination: URL,
        segmentIndex: Int,
        tracker: ParallelProgressTracker
    ) async throws {
        let expectedLen = end - start + 1
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = SegmentDownloadDelegate(
                destination: destination,
                expectedLength: expectedLen,
                segmentIndex: segmentIndex,
                tracker: tracker,
                continuation: cont
            )
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 45
            cfg.timeoutIntervalForResource = 900
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            session.downloadTask(with: req).resume()
            session.finishTasksAndInvalidate()
        }
    }

    private static func downloadSingleStream(
        from url: URL,
        labelZh: String,
        labelEn: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let delegate = SingleStreamDownloadDelegate(labelZh: labelZh, labelEn: labelEn, onProgress: onProgress, continuation: cont)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 1800
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: fileURL)
        defer { try? fh.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            guard let chunk = try? fh.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ParallelProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var perSegment: [Int: Int64] = [:]
    private var lastPercent = -1
    private let totalBytes: Int64
    private let labelZh: String
    private let labelEn: String
    private let onProgress: @Sendable (String) -> Void

    init(totalBytes: Int64, labelZh: String, labelEn: String, onProgress: @escaping @Sendable (String) -> Void) {
        self.totalBytes = totalBytes
        self.labelZh = labelZh
        self.labelEn = labelEn
        self.onProgress = onProgress
    }

    func update(segment: Int, written: Int64) {
        lock.lock()
        perSegment[segment] = written
        let sum = perSegment.values.reduce(0, +)
        let pct = min(100, Int((Double(sum) / Double(totalBytes)) * 100.0))
        let report = (pct != lastPercent)
        if report { lastPercent = pct }
        lock.unlock()

        if report {
            let doneMB = Int(sum / 1_048_576)
            let totalMB = Int(totalBytes / 1_048_576)
            onProgress(L10n.t(
                "\(labelZh) · \(pct)% (\(doneMB)/\(totalMB) MB)",
                "\(labelEn) · \(pct)% (\(doneMB)/\(totalMB) MB)"
            ))
        }
    }
}

private final class SegmentDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedLength: Int64
    private let segmentIndex: Int
    private let tracker: ParallelProgressTracker
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(
        destination: URL,
        expectedLength: Int64,
        segmentIndex: Int,
        tracker: ParallelProgressTracker,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.expectedLength = expectedLength
        self.segmentIndex = segmentIndex
        self.tracker = tracker
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        tracker.update(segment: segmentIndex, written: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 206 else {
                throw WineRuntimeError.downloadFailed("Segment did not return HTTP 206")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
            guard size == expectedLength else {
                throw WineRuntimeError.downloadFailed("Segment truncated (\(size)/\(expectedLength))")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

private final class SingleStreamDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let labelZh: String
    private let labelEn: String
    private let onProgress: @Sendable (String) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()
    private var lastReportedPercent = -1

    init(
        labelZh: String,
        labelEn: String,
        onProgress: @escaping @Sendable (String) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.labelZh = labelZh
        self.labelEn = labelEn
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) * 100.0)
        lock.lock()
        let shouldReport = (pct != lastReportedPercent)
        if shouldReport { lastReportedPercent = pct }
        lock.unlock()

        if shouldReport {
            let doneMB = Int(totalBytesWritten / 1_048_576)
            let totalMB = Int(totalBytesExpectedToWrite / 1_048_576)
            onProgress(L10n.t(
                "\(labelZh) · \(pct)% (\(doneMB)/\(totalMB) MB)",
                "\(labelEn) · \(pct)% (\(doneMB)/\(totalMB) MB)"
            ))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        let stableCopy = fm.temporaryDirectory.appendingPathComponent("wine-dl-\(UUID().uuidString).tar.xz")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WineRuntimeError.downloadFailed("HTTP \(http.statusCode)")
            }
            try fm.moveItem(at: location, to: stableCopy)
            finish(.success(stableCopy))
        } catch {
            finish(.failure(WineRuntimeError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(WineRuntimeError.downloadFailed(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
