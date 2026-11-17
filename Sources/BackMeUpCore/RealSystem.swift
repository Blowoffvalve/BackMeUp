import Foundation

/// The System port's adapter for the real Mac. It only reads, so far.
///
/// Time Machine's state comes from `/usr/bin/tmutil` run as a subprocess, because its
/// preferences can't be read directly without Full Disk Access.
@MainActor
public final class RealSystem: System {
    public init() {}

    public var now: Date { Date() }

    public func readTimeMachineStatus() async -> TimeMachineStatus {
        guard let result = await Command.run("/usr/bin/tmutil", ["status", "-X"]), result.exitCode == 0 else {
            return .unknown
        }
        return TimeMachineStatus(statusOutput: result.stdout)
    }

    public func readDestinationInfo() async -> DestinationInfo {
        guard let result = await Command.run("/usr/bin/tmutil", ["destinationinfo", "-X"]) else {
            return .unknown
        }
        // tmutil may report "No destinations configured" on standard error, perhaps with a
        // non-zero exit, so the parser sees the output whatever the exit code.
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return DestinationInfo(destinationInfoOutput: output)
    }
}

/// Runs a command off the main thread and collects its output.
enum Command {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Returns nil if the command couldn't be started.
    static func run(_ path: String, _ arguments: [String]) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path, arguments))
            }
        }
    }

    private static func runBlocking(_ path: String, _ arguments: [String]) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read stderr on another thread so a full pipe can't block the process.
        let errorData = ErrorCollector(handle: stderr.fileHandleForReading)
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData.wait(), as: UTF8.self)
        )
    }
}

/// Reads a pipe to its end on a background queue.
private final class ErrorCollector: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
