import Foundation
import Testing
import BackMeUpCore

@Suite("Parsing backup progress from tmutil status -X")
struct ProgressParserTests {
    @Test func copyingWithTimeRemaining() throws {
        let progress = BackupProgress(statusOutput: try fixture("status-running-time-remaining.plist"))

        #expect(progress?.fraction == 0.096572253844453795)
        #expect(progress?.timeRemaining == 9810.0213244780061)
    }

    @Test func copyingWithoutTimeRemaining() throws {
        let progress = BackupProgress(statusOutput: try fixture("status-running-copying.plist"))

        #expect(progress?.fraction == 0.0066898739727356332)
        #expect(progress?.timeRemaining == nil)
    }

    @Test(arguments: ["status-idle.plist", "status-running-mounting.plist"])
    func noProgressYet(fixtureName: String) throws {
        #expect(BackupProgress(statusOutput: try fixture(fixtureName)) == nil)
    }

    @Test(arguments: [
        "",
        "not a plist",
        // A fraction outside 0...1 isn't understood.
        "<plist version=\"1.0\"><dict><key>Running</key><true/><key>Progress</key><dict><key>Percent</key><real>35</real></dict></dict></plist>",
    ])
    func outputWeCannotReadHasNoProgress(output: String) {
        #expect(BackupProgress(statusOutput: output) == nil)
    }
}
