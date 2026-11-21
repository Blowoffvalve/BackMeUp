import Testing
import BackMeUpCore

@Suite("Parsing tmutil destinationinfo -X")
struct DestinationParserTests {
    @Test func networkDisk() throws {
        let info = DestinationInfo(destinationInfoOutput: try fixture("destinationinfo-network.plist"))
        #expect(info == .configured(Destination(kind: .network, id: "00000000-0000-0000-0000-000000000001", name: "TimeMachine", serverHost: "backup-server")))
    }

    @Test func localDisk() throws {
        let info = DestinationInfo(destinationInfoOutput: try fixture("destinationinfo-local.plist"))
        #expect(info == .configured(Destination(kind: .local, id: "00000000-0000-0000-0000-000000000002", name: "Backup Disk", mountPoint: "/Volumes/Backup Disk")))
    }

    @Test func twoDisksAreAllReturnedInTimeMachinesOrder() throws {
        let info = DestinationInfo(destinationInfoOutput: try fixture("destinationinfo-two-disks.plist"))
        #expect(info == .several([
            Destination(kind: .local, id: "00000000-0000-0000-0000-000000000002", name: "Backup Disk", mountPoint: "/Volumes/Backup Disk"),
            Destination(kind: .network, id: "00000000-0000-0000-0000-000000000001", name: "TimeMachine", serverHost: "backup-server"),
        ]))
    }

    static let networkDisk = Destination(kind: .network, id: "00000000-0000-0000-0000-000000000001", name: "TimeMachine", serverHost: "backup-server")
    static let usbDiskID = "<key>ID</key>\n\t\t\t<string>00000000-0000-0000-0000-000000000002</string>"
    static let networkDiskID = "<key>ID</key>\n\t\t\t<string>00000000-0000-0000-0000-000000000001</string>"

    /// The two-disk fixture with `edits` (text, replacement) made to it.
    func twoDisks(_ edits: [(String, String)]) throws -> DestinationInfo {
        var output = try fixture("destinationinfo-two-disks.plist")
        for (text, replacement) in edits {
            #expect(output.contains(text))
            output = output.replacingOccurrences(of: text, with: replacement)
        }
        return DestinationInfo(destinationInfoOutput: output)
    }

    @Test func aDiskOfAnUnknownKindIsLeftOutAndTheOtherIsTheOneDisk() throws {
        let info = try twoDisks([("<string>Local</string>", "<string>Cloud</string>")])
        #expect(info == .configured(Self.networkDisk))
    }

    @Test func whenNoDiskIsOfAKnownKindTheReadingIsUnknown() throws {
        let info = try twoDisks([("<string>Local</string>", "<string>Cloud</string>"), ("<string>Network</string>", "<string>Cloud</string>")])
        #expect(info == .unknown)
    }

    @Test func aDiskWithoutAnIDCannotBeChosenSoTheOtherIsTheOneDisk() throws {
        let info = try twoDisks([(Self.usbDiskID, "")])
        #expect(info == .configured(Self.networkDisk))
    }

    @Test func whenNoneOfSeveralDisksHasAnIDTheReadingIsUnknown() throws {
        let info = try twoDisks([(Self.usbDiskID, ""), (Self.networkDiskID, "")])
        #expect(info == .unknown)
    }

    @Test func theOnlyDiskIsUsedEvenWithoutAnID() throws {
        let output = try fixture("destinationinfo-network.plist")
            .replacingOccurrences(of: Self.networkDiskID, with: "")
        #expect(DestinationInfo(destinationInfoOutput: output) == .configured(Destination(kind: .network, id: nil, name: "TimeMachine", serverHost: "backup-server")))
    }

    @Test func theServerIsTheHostInTheNetworkDisksURL() throws {
        let info = DestinationInfo(destinationInfoOutput: try fixture("destinationinfo-network.plist"))
        #expect(info.disks.first?.serverHost == "backup-server")
    }

    @Test(arguments: [
        ("smb://backup-user@backup-server/TimeMachine", "backup-server"),
        ("smb://backup-server.local/Share%20Name", "backup-server.local"),
        ("afp://user@192.0.2.10/Backups", "192.0.2.10"),
        ("smb:///NoHost", nil),
        ("not a url", nil),
    ] as [(String, String?)])
    func aNetworkDisksServerComesFromItsURL(url: String, host: String?) throws {
        let output = try fixture("destinationinfo-network.plist")
            .replacingOccurrences(of: "smb://backup-user@backup-server/TimeMachine", with: url)
        #expect(DestinationInfo(destinationInfoOutput: output).disks.first?.serverHost == host)
    }

    @Test func aNetworkDiskWithoutAURLHasNoServer() throws {
        let output = try fixture("destinationinfo-network.plist")
            .replacingOccurrences(of: "<key>URL</key>\n\t\t\t<string>smb://backup-user@backup-server/TimeMachine</string>", with: "")
        #expect(output.contains("URL") == false)
        #expect(DestinationInfo(destinationInfoOutput: output).disks.first?.serverHost == nil)
    }

    @Test(arguments: ["destinationinfo-none.plist", "destinationinfo-none.txt"])
    func noDestination(fixtureName: String) throws {
        #expect(DestinationInfo(destinationInfoOutput: try fixture(fixtureName)) == .notSetUp)
    }

    @Test(arguments: [
        "",
        "tmutil: something went wrong",
        // A destination of a kind we don't know: can't tell, rather than guessing.
        "<plist version=\"1.0\"><dict><key>Destinations</key><array><dict><key>Kind</key><string>Cloud</string></dict></array></dict></plist>",
    ])
    func outputWeCannotReadIsUnknown(output: String) {
        #expect(DestinationInfo(destinationInfoOutput: output) == .unknown)
    }
}
