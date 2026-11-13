import Foundation
import Darwin

public struct ProcessOutput: Sendable { public let stdout: Data; public let stderr: Data; public let code: Int32 }
public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval, outputLimit: Int) async throws -> ProcessOutput
}
private final class ProcessControl: @unchecked Sendable {
    let lock = NSLock()
    var process: Process?
    var cancelled = false
    func cancel() { lock.lock(); cancelled = true; if let process, process.isRunning { process.terminate() }; lock.unlock() }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process; try process.run()
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private final class OutputBuffer: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    var exceeded = false
    func append(_ chunk: Data, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        if data.count + chunk.count > limit { exceeded = true }
        data.append(chunk.prefix(max(0, limit - data.count)))
    }
    var tooLarge: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
}
public struct GCXRunner: ProcessRunning {
    public init() {}
    public static func discover(preferred: String = "") -> String? {
        ([preferred, "/opt/homebrew/bin/gcx", "/usr/local/bin/gcx", NSHomeDirectory() + "/.local/bin/gcx"]).first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
    public func run(executable: URL, arguments: [String], timeout: TimeInterval = 30, outputLimit: Int = 16 * 1024 * 1024) async throws -> ProcessOutput {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
              DispatchQueue.global(qos: .userInitiated).async {
               do {
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
                var env = ProcessInfo.processInfo.environment
                // Avoid agent output modes, endpoint overrides, and repository config inherited from a launcher.
                for key in env.keys where key.hasPrefix("GCX_") || key.hasPrefix("GRAFANA_") || key.hasPrefix("CODEX_") || key.hasPrefix("CLAUDE_") { env.removeValue(forKey: key) }
                env["GCX_AGENT_MODE"] = "false"; env["NO_COLOR"] = "1"
                process.environment = env
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
                let out = OutputBuffer(), err = OutputBuffer(), readers = DispatchGroup()
                try control.start(process)
                for (handle, buffer) in [(stdout.fileHandleForReading, out), (stderr.fileHandleForReading, err)] {
                    readers.enter()
                    DispatchQueue.global().async {
                        defer { readers.leave() }
                        while let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty { buffer.append(chunk, limit: outputLimit) }
                    }
                }
                let deadline = Date().addingTimeInterval(timeout)
                var reason: String?
                while process.isRunning {
                    if control.isCancelled || Date() >= deadline || out.tooLarge || err.tooLarge {
                        reason = control.isCancelled ? "Cancelled" : (out.tooLarge || err.tooLarge ? "gcx output exceeded the 16 MB limit. Narrow the time range or query." : "gcx timed out. Check the connection and retry.")
                        process.terminate()
                        let grace = Date().addingTimeInterval(0.5)
                        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                process.waitUntilExit(); readers.wait()
                if control.isCancelled { throw CancellationError() }
                if let reason { throw QueryError.message(reason) }
                if out.tooLarge || err.tooLarge { throw QueryError.message("gcx output exceeded the configured limit.") }
                continuation.resume(returning: ProcessOutput(stdout: out.data, stderr: err.data, code: process.terminationStatus))
               } catch { continuation.resume(throwing: error) }
              }
            }
        }, onCancel: { control.cancel() })
    }
}
