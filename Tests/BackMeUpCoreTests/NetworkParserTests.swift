import Testing
import BackMeUpCore

@Suite("Parsing the routing table (netstat -rn -f inet)")
struct RoutingTableParserTests {
    @Test func onePhysicalDefaultRoute() throws {
        let table = RoutingTable(netstatOutput: try fixture("netstat-wifi.txt"))
        #expect(table.physicalDefaultRoute == DefaultRoute(gateway: "192.0.2.1", interface: "en0"))
    }

    @Test func aVPNDefaultRouteAlongsideIsIgnored() throws {
        let table = RoutingTable(netstatOutput: try fixture("netstat-wifi-and-vpn.txt"))
        #expect(table.physicalDefaultRoute == DefaultRoute(gateway: "192.0.2.1", interface: "en0"))
    }

    @Test func aVPNDefaultRouteListedFirstIsIgnored() throws {
        let table = RoutingTable(netstatOutput: try fixture("netstat-vpn-first.txt"))
        #expect(table.physicalDefaultRoute == DefaultRoute(gateway: "192.0.2.1", interface: "en7"))
    }

    @Test func onlyVPNDefaultRoutesMeanNoNetwork() throws {
        let table = RoutingTable(netstatOutput: try fixture("netstat-vpn-only.txt"))
        #expect(table.physicalDefaultRoute == nil)
    }

    @Test(arguments: ["", "netstat: something went wrong", "Routing tables\n\nInternet:\n"])
    func outputWithNoDefaultRouteHasNone(output: String) {
        #expect(RoutingTable(netstatOutput: output).physicalDefaultRoute == nil)
    }
}

/// Without Local Network permission, macOS hides hardware addresses from the ARP table, so the
/// app reads the router's address from SystemConfiguration's `State:/Network/Service/<id>/IPv4`.
/// These dictionaries copy the real keys (macOS 27.2) with personal values replaced.
@Suite("Reading the router's address from SystemConfiguration")
struct NetworkServiceParserTests {
    static let route = DefaultRoute(gateway: "192.0.2.1", interface: "en0")
    nonisolated(unsafe) static let wifi: [String: Any] = [
        "ARPResolvedHardwareAddress": "02:00:00:00:00:01",
        "ARPResolvedIPAddress": "192.0.2.1",
        "Addresses": ["192.0.2.40"],
        "ConfirmedInterfaceName": "en0",
        "InterfaceName": "en0",
        "NetworkSignature": "IPv4.Router=192.0.2.1;IPv4.RouterHardwareAddress=02:00:00:00:00:01",
        "Router": "192.0.2.1",
    ]
    nonisolated(unsafe) static let vpn: [String: Any] = [
        "Addresses": ["100.64.0.2"],
        "InterfaceName": "utun5",
        "Router": "100.64.0.2",
        "ServerAddress": "100.64.0.1",
    ]

    @Test func theRoutersAddressComesFromTheServiceOnTheRoutesInterface() {
        let address = NetworkServiceState.routerHardwareAddress(services: [Self.vpn, Self.wifi], route: Self.route)
        #expect(address == "02:00:00:00:00:01")
    }

    @Test func theNetworkSignatureIsUsedWhenThereIsNoARPResolvedAddress() {
        var service = Self.wifi
        service["ARPResolvedHardwareAddress"] = nil
        service["NetworkSignature"] = "IPv4.Router=192.0.2.1;IPv4.RouterHardwareAddress=2:0:0:0:0:1"
        #expect(NetworkServiceState.routerHardwareAddress(services: [service], route: Self.route) == "02:00:00:00:00:01")
    }

    @Test func anAddressForAnotherRouterIsNotUsed() {
        var service = Self.wifi
        service["ARPResolvedIPAddress"] = "192.0.2.99"
        service["NetworkSignature"] = "IPv4.Router=192.0.2.99;IPv4.RouterHardwareAddress=02:00:00:00:00:09"
        #expect(NetworkServiceState.routerHardwareAddress(services: [service], route: Self.route) == nil)
    }

    @Test func noServiceOnTheRoutesInterfaceGivesNoAddress() {
        let route = DefaultRoute(gateway: "192.0.2.1", interface: "en7")
        #expect(NetworkServiceState.routerHardwareAddress(services: [Self.vpn, Self.wifi], route: route) == nil)
    }
}

@Suite("Parsing the ARP table (arp -an)")
struct ARPTableParserTests {
    @Test func theRoutersHardwareAddressIsReadWithLeadingZeros() throws {
        let table = ARPTable(arpOutput: try fixture("arp-gateway.txt"))
        #expect(table.hardwareAddress(of: "192.0.2.1", on: "en0") == "02:00:00:00:00:01")
    }

    @Test(arguments: ["arp-gateway-incomplete.txt", "arp-gateway-missing.txt"])
    func aMissingOrIncompleteEntryGivesNoAddress(fixtureName: String) throws {
        let table = ARPTable(arpOutput: try fixture(fixtureName))
        #expect(table.hardwareAddress(of: "192.0.2.1", on: "en0") == nil)
    }

    @Test func theEntryOnTheRoutesInterfaceIsUsed() throws {
        let table = ARPTable(arpOutput: try fixture("arp-wifi-and-ethernet.txt"))
        #expect(table.hardwareAddress(of: "192.0.2.1", on: "en7") == "02:00:00:00:00:01")
        #expect(table.hardwareAddress(of: "192.0.2.1", on: "en0") == "02:00:00:00:00:09")
    }

    @Test func anEntryOnAnotherInterfaceIsNotUsed() throws {
        let table = ARPTable(arpOutput: try fixture("arp-gateway.txt"))
        #expect(table.hardwareAddress(of: "192.0.2.1", on: "en7") == nil)
    }
}
