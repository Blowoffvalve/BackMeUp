import Testing
import BackMeUpCore

@Suite("Parsing tmutil destinationinfo -X")
struct DestinationParserTests {
    @Test func networkDisk() throws {
        let info = DestinationInfo(destinationInfoOutput: try fixture("destinationinfo-network.plist"))
        #expect(info == .configured(Destination(kind: .network, id: "00000000-0000-0000-0000-000000000001")))
    }

    @Test func localDisk() throws {
        let info = DestinationInfo(destinationInfoOutput: try fixture("destinationinfo-local.plist"))
        #expect(info == .configured(Destination(kind: .local, id: "00000000-0000-0000-0000-000000000002", mountPoint: "/Volumes/Backup Disk")))
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
