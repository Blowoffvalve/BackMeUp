import Testing
import BackMeUpCore

@Suite("Parsing tmutil status -X")
struct StatusParserTests {
    @Test func idleMac() throws {
        #expect(TimeMachineStatus(statusOutput: try fixture("status-idle.plist")) == .idle)
    }

    @Test(arguments: ["status-running-mounting.plist", "status-running-copying.plist"])
    func runningBackupNamesItsDisk(fixtureName: String) throws {
        #expect(TimeMachineStatus(statusOutput: try fixture(fixtureName)) == .running(destinationID: "00000000-0000-0000-0000-000000000001"))
    }

    @Test func aRunningBackupWithoutADestinationIDStillCounts() {
        let output = "<plist version=\"1.0\"><dict><key>Running</key><true/></dict></plist>"
        #expect(TimeMachineStatus(statusOutput: output) == .running(destinationID: nil))
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
