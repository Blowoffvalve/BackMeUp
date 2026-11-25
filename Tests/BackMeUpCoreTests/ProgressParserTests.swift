import Foundation
import Testing
import BackMeUpCore

@Suite("Parsing backup progress from tmutil status -X")
struct ProgressParserTests {
    // Time Machine's menu showed "20.8% done" for this output: the Copying phase fills the last
    // 90% of its progress bar (FractionOfProgressBar 0.9), so it shows 10% + 0.9 x Percent.
    @Test func matchesWhatTimeMachineShows() throws {
        let progress = try #require(BackupProgress(statusOutput: try fixture("status-running-time-machine-shows-20.8.plist")))

        #expect(abs(progress.fraction - 0.2077) < 0.0001)
        #expect(progress.percentText == "20.8%")
    }

    @Test func copyingWithTimeRemaining() throws {
        let progress = BackupProgress(statusOutput: try fixture("status-running-time-remaining.plist"))

        #expect(abs(progress!.fraction - (0.1 + 0.9 * 0.096572253844453795)) < 1e-9)
        #expect(progress?.timeRemaining == 9810.0213244780061)
    }

    @Test func copyingWithoutTimeRemaining() throws {
        let progress = BackupProgress(statusOutput: try fixture("status-running-copying.plist"))

        #expect(abs(progress!.fraction - (0.1 + 0.9 * 0.0066898739727356332)) < 1e-9)
        #expect(progress?.timeRemaining == nil)
    }

    @Test func copyingGivesTheBackupsTotal() throws {
        let progress = BackupProgress(statusOutput: try fixture("status-running-copying.plist"))

        #expect(progress?.totalBytes == 251_554_357_248)
    }

    /// The format is undocumented: a missing or non-positive `totalBytes` means no total, never zero.
    @Test(arguments: [
        "<plist version=\"1.0\"><dict><key>Running</key><true/><key>Progress</key><dict><key>Percent</key><real>0.35</real></dict></dict></plist>",
        "<plist version=\"1.0\"><dict><key>Running</key><true/><key>Progress</key><dict><key>Percent</key><real>0.35</real><key>totalBytes</key><integer>0</integer></dict></dict></plist>",
        "<plist version=\"1.0\"><dict><key>Running</key><true/><key>Progress</key><dict><key>Percent</key><real>0.35</real><key>totalBytes</key><integer>-1</integer></dict></dict></plist>",
        "<plist version=\"1.0\"><dict><key>Running</key><true/><key>Percent</key><real>0.35</real></dict></plist>",
    ])
    func withoutAPositiveTotalThereIsNoTotal(output: String) {
        let progress = BackupProgress(statusOutput: output)

        #expect(progress != nil)
        #expect(progress?.totalBytes == nil)
    }

    @Test func withoutFractionOfProgressBarPercentIsUsedAsIs() {
        let output = "<plist version=\"1.0\"><dict><key>Running</key><true/><key>Progress</key><dict><key>Percent</key><real>0.35</real></dict></dict></plist>"

        #expect(BackupProgress(statusOutput: output)?.fraction == 0.35)
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
