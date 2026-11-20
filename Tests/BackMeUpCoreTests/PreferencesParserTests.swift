import Foundation
import Testing
import BackMeUpCore

@Suite("Parsing defaults read /Library/Preferences/com.apple.TimeMachine")
struct PreferencesParserTests {
    static let destinationID = "00000000-0000-0000-0000-000000000001"

    @Test func realOutputWithANetworkDisk() throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: try fixture("defaults-timemachine-network.txt")))
        #expect(preferences.autoBackup == false)
        let destination = try #require(preferences.destination(id: Self.destinationID))
        #expect(destination.encryption == .encrypted)
        #expect(destination.result == 0)
    }

    @Test(arguments: [
        ("AutoBackup = 1;", true as Bool?),
        ("AutoBackup = 0;", false),
        ("AutoBackup = maybe;", nil),
        ("", nil),
    ])
    func autoBackup(line: String, expected: Bool?) throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: "{ \(line) PreferencesVersion = 6; }"))
        #expect(preferences.autoBackup == expected)
    }

    @Test(arguments: [
        ("LastKnownEncryptionState = Encrypted;", EncryptionState.encrypted),
        ("LastKnownEncryptionState = NotEncrypted;", .notEncrypted),
        ("LastKnownEncryptionState = Scrambled;", .unknown),
        ("", .unknown),
    ])
    func encryptionState(line: String, expected: EncryptionState) throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: Self.oneDestination(line)))
        #expect(preferences.destination(id: "ID-1")?.encryption == expected)
    }

    @Test(arguments: [
        ("RESULT = 0;", 0 as Int?),
        ("RESULT = 19;", 19),
        ("RESULT = \"oops\";", nil),
        ("", nil),
    ])
    func result(line: String, expected: Int?) throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: Self.oneDestination(line)))
        #expect(preferences.destination(id: "ID-1")?.result == expected)
    }

    @Test func theLatestSnapshotComesFromTheRealOutput() throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: try fixture("defaults-timemachine-network.txt")))
        // The newest of SnapshotDates: 2026-01-03 05:46:51 +0000.
        #expect(preferences.destination(id: Self.destinationID)?.latestSnapshot == Date(timeIntervalSince1970: 1_767_419_211))
    }

    @Test(arguments: [
        // Newest first or last, it's the newest that counts.
        (#"SnapshotDates = ("2026-01-02 00:00:00 +0000", "2026-01-01 00:00:00 +0000");"#, 1_767_312_000 as Double?),
        (#"SnapshotDates = ("2026-01-01 00:00:00 +0000", "not a date", "2026-01-02 00:00:00 +0000");"#, 1_767_312_000),
        // Another time zone.
        (#"SnapshotDates = ("2026-01-02 01:00:00 +0100");"#, 1_767_312_000),
        (#"SnapshotDates = ();"#, nil),
        (#"SnapshotDates = "2026-01-02 00:00:00 +0000";"#, nil),
        ("", nil),
    ])
    func latestSnapshot(line: String, expected: Double?) throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: Self.oneDestination(line)))
        #expect(preferences.destination(id: "ID-1")?.latestSnapshot == expected.map(Date.init(timeIntervalSince1970:)))
    }

    @Test func aDestinationThatIsNotThereIsNil() throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: Self.oneDestination("RESULT = 0;")))
        #expect(preferences.destination(id: "ID-2") == nil)
    }

    @Test func noDestinationsAtAll() throws {
        let preferences = try #require(TimeMachinePreferences(defaultsOutput: "{ AutoBackup = 1; }"))
        #expect(preferences.destination(id: "ID-1") == nil)
    }

    @Test(arguments: [
        "",
        "Domain /Library/Preferences/com.apple.TimeMachine does not exist",
        "{ AutoBackup = ",
    ])
    func outputWeCannotReadIsNil(output: String) {
        #expect(TimeMachinePreferences(defaultsOutput: output) == nil)
    }

    static func oneDestination(_ line: String) -> String {
        """
        {
            AutoBackup = 0;
            Destinations = (
                {
                    DestinationID = "ID-1";
                    \(line)
                }
            );
        }
        """
    }
}
