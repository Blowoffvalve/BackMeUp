import AppKit
import Foundation
import os

/// The log for the real Mac: a plain-text file the user can open with Show Log, and the unified
/// log (Console.app, subsystem `io.github.blowoffvalve.BackMeUp`).
extension RealSystem {
    private static let logger = Logger(subsystem: "io.github.blowoffvalve.BackMeUp", category: "BackMeUp")

    /// `~/Library/Logs/BackMeUp/BackMeUp.log`, and the previous one as `BackMeUp.1.log`.
    static let logFile = LogFile(
        directory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/BackMeUp", directoryHint: .isDirectory)
    )

    public func log(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        Self.logFile.append(message, at: now)
    }

    /// Opens the log in the app that opens `.log` files (normally Console). Creates an empty
    /// log first if nothing has been logged yet.
    public func openLog() -> Bool {
        guard let url = Self.logFile.createIfMissing() else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Deletes the log folder, old log included.
    public func deleteLog() {
        Self.logFile.delete()
    }
}

/// A plain-text log file with simple size-based rotation: once the file reaches
/// `maximumBytes`, it's renamed to `<name>.1.log` (replacing an older one) and a new file starts.
/// So at most about twice `maximumBytes` is kept. Write failures are ignored: the log must never
/// stop a backup.
struct LogFile: Sendable {
    let directory: URL
    var name = "BackMeUp"
    var maximumBytes = 512 * 1024

    var url: URL { directory.appending(path: "\(name).log") }
    var previousURL: URL { directory.appending(path: "\(name).1.log") }

    /// Appends "2026-01-01 14:02:00 +0000  message" as one line.
    func append(_ message: String, at date: Date) {
        let line = "\(Self.timestamp(date))  \(message.replacingOccurrences(of: "\n", with: " "))\n"
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int, size >= maximumBytes {
            try? fileManager.removeItem(at: previousURL)
            try? fileManager.moveItem(at: url, to: previousURL)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            fileManager.createFile(atPath: url.path, contents: Data(line.utf8))
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// The log's URL, after creating an empty log if there isn't one. nil if it can't be made.
    func createIfMissing() -> URL? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return url }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return fileManager.createFile(atPath: url.path, contents: nil) ? url : nil
    }

    func delete() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
