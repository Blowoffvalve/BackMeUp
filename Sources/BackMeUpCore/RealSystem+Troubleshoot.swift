import Foundation

/// What Troubleshoot reads on the real Mac: whether the backup server answers, Time Machine's own
/// log, and when the Mac started up.
extension RealSystem {
    /// `nc -z` only opens a TCP connection to the SMB port and closes it. `-G` limits the
    /// connection attempt, so an unreachable server costs at most that many seconds.
    public func serverAnswers(host: String) async -> Bool {
        let result = await Command.run("/usr/bin/nc", ["-z", "-G", "5", host, "445"])
        return result?.exitCode == 0
    }

    /// Reads `backupd`'s lines in the unified log with `/usr/bin/log show`, which an ordinary
    /// user can run. Seen on macOS 27.2: when Time Machine had lost track of a network disk, each
    /// failed attempt logged `'/Volumes/.timemachine/…' - no volume mounted at this path`.
    public func timeMachineLostItsMount(from start: Date, to end: Date) async -> Bool? {
        // A little either side, since the log's clock and ours are read at different moments.
        let arguments = [
            "show", "--style", "compact",
            "--start", Self.logDate(start.addingTimeInterval(-2)),
            "--end", Self.logDate(end.addingTimeInterval(2)),
            "--predicate", #"process == "backupd" AND eventMessage CONTAINS "no volume mounted at this path""#,
        ]
        guard let result = await Command.run("/usr/bin/log", arguments), result.exitCode == 0 else { return nil }
        return result.stdout.contains("no volume mounted at this path")
    }

    /// `kern.boottime`: when the Mac last started up.
    public var bootTime: Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// "2026-11-21 12:51:24", in the Mac's time zone, as `log show --start` expects.
    private static func logDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
