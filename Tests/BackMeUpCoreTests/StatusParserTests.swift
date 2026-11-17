import Testing
import BackMeUpCore

@Suite("Parsing tmutil status -X")
struct StatusParserTests {
    @Test func idleMac() throws {
        #expect(TimeMachineStatus(statusOutput: try fixture("status-idle.plist")) == .idle)
    }

    @Test func runningBackup() throws {
        #expect(TimeMachineStatus(statusOutput: try fixture("status-running.plist")) == .running)
    }

    @Test(arguments: [
        "",
        "tmutil: status requires Full Disk Access",
        "<plist version=\"1.0\"><dict><key>ClientID</key><string>com.apple.backupd</string></dict></plist>",
    ])
    func outputWeCannotReadIsUnknown(output: String) {
        #expect(TimeMachineStatus(statusOutput: output) == .unknown)
    }
}
