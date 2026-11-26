import Foundation

public struct ShellOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ShellError: LocalizedError {
    case failedToLaunch(String, String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .failedToLaunch(let bin, let err): return L10n.t("无法执行 \(bin)：\(err)", "Could not run \(bin): \(err)")
        case .timedOut(let bin): return L10n.t("执行超时：\(bin)", "Timed out: \(bin)")
        }
    }
}

public enum ShellCommand {
    public static func run(
        _ executable: String,
        args: [String] = [],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        timeout: TimeInterval? = 60
    ) async throws -> ShellOutput {
        let (code, data, err) = try await runRaw(executable, args: args, env: env, cwd: cwd, timeout: timeout)
        return ShellOutput(
            exitCode: code,
            stdout: String(data: data, encoding: .utf8) ?? "",
            stderr: err
        )
    }

    public static func runRaw(
        _ executable: String,
        args: [String] = [],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        timeout: TimeInterval? = 30
    ) async throws -> (exitCode: Int32, stdout: Data, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                if let cwd {
                    proc.currentDirectoryURL = cwd
                }
                if let env {
                    var merged = ProcessInfo.processInfo.environment
                    for (k, v) in env { merged[k] = v }
                    proc.environment = merged
                }

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: ShellError.failedToLaunch(executable, error.localizedDescription))
                    return
                }

                var timedOut = false
                var timer: DispatchSourceTimer?
                if let timeout, timeout > 0 {
                    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    t.schedule(deadline: .now() + timeout)
                    t.setEventHandler {
                        if proc.isRunning {
                            timedOut = true
                            proc.terminate()
                        }
                    }
                    t.resume()
                    timer = t
                }

                proc.waitUntilExit()
                timer?.cancel()
                group.wait()

                if timedOut {
                    cont.resume(throwing: ShellError.timedOut(executable))
                    return
                }

                let errStr = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus, outData, errStr))
            }
        }
    }
}
