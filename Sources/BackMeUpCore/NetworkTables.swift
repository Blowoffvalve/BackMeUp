import Foundation

/// A default route: the router's IP address and the interface it's reached through.
public struct DefaultRoute: Equatable, Sendable {
    public var gateway: String
    public var interface: String

    public init(gateway: String, interface: String) {
        self.gateway = gateway
        self.interface = interface
    }
}

/// The IPv4 routing table, parsed from `netstat -rn -f inet`. The format isn't documented, so
/// anything unexpected is skipped rather than guessed at.
public struct RoutingTable: Equatable, Sendable {
    /// Every default route with an IP gateway, in the order `netstat` lists them.
    public var defaultRoutes: [DefaultRoute]

    public init(netstatOutput: String) {
        defaultRoutes = netstatOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // Destination, Gateway, Flags, Netif, [Expire]
            guard fields.count >= 4, fields[0] == "default", Self.isIPv4Address(fields[1]) else { return nil }
            return DefaultRoute(gateway: fields[1], interface: fields[3])
        }
    }

    /// The first default route on a physical interface (Wi-Fi, Ethernet, a USB or Thunderbolt
    /// adapter). VPNs and tunnels (`utun`, `ipsec`, `ppp` and so on) never count as a network.
    public var physicalDefaultRoute: DefaultRoute? {
        defaultRoutes.first { Self.isPhysical(interface: $0.interface) }
    }

    /// An allow-list, so an interface type we don't know is never mistaken for a home network.
    static func isPhysical(interface: String) -> Bool {
        let digits = interface.drop { $0.isLetter }
        let prefix = interface.prefix(interface.count - digits.count)
        return ["en", "bridge"].contains(prefix) && !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func isIPv4Address(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }
}

/// SystemConfiguration's per-service IPv4 state (`State:/Network/Service/<id>/IPv4`), which
/// configd fills in for each connected network. Unlike the ARP table, macOS doesn't hide the
/// router's hardware address here from apps without Local Network permission. Undocumented keys,
/// so anything missing or inconsistent gives nil.
public enum NetworkServiceState {
    /// The hardware address of `route`'s router, from the service on the route's interface:
    /// `ARPResolvedHardwareAddress`, or else `IPv4.RouterHardwareAddress` in `NetworkSignature`,
    /// each only when it belongs to the route's gateway.
    public static func routerHardwareAddress(services: [[String: Any]], route: DefaultRoute) -> String? {
        guard let service = services.first(where: { $0["InterfaceName"] as? String == route.interface }) else {
            return nil
        }
        if service["ARPResolvedIPAddress"] as? String == route.gateway,
           let text = service["ARPResolvedHardwareAddress"] as? String,
           let address = ARPTable.normalised(hardwareAddress: text) {
            return address
        }
        // "IPv4.Router=192.0.2.1;IPv4.RouterHardwareAddress=02:00:00:00:00:01"
        guard let signature = service["NetworkSignature"] as? String else { return nil }
        var fields: [String: String] = [:]
        for pair in signature.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard fields["IPv4.Router"] == route.gateway, let text = fields["IPv4.RouterHardwareAddress"] else { return nil }
        return ARPTable.normalised(hardwareAddress: text)
    }
}

/// The ARP table, parsed from `arp -an`. Reading it sends nothing on the network.
public struct ARPTable: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var ip: String
        var hardwareAddress: String
        var interface: String
    }

    var entries: [Entry]

    public init(arpOutput: String) {
        // "? (192.0.2.1) at 2:0:0:0:0:1 on en0 ifscope [ethernet]"
        entries = arpOutput.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 6, fields[2] == "at", fields[4] == "on",
                  fields[1].hasPrefix("("), fields[1].hasSuffix(")"),
                  let address = Self.normalised(hardwareAddress: fields[3])
            else { return nil }
            return Entry(ip: String(fields[1].dropFirst().dropLast()), hardwareAddress: address, interface: fields[5])
        }
    }

    /// The hardware address of `ip` as seen on `interface`, in lowercase with two digits per byte,
    /// or nil if there's no complete entry for it.
    public func hardwareAddress(of ip: String, on interface: String) -> String? {
        entries.first { $0.ip == ip && $0.interface == interface }?.hardwareAddress
    }

    /// `arp` drops leading zeros ("2:0:0:0:0:a"). Returns nil for "(incomplete)" and anything
    /// else that isn't six hex bytes.
    static func normalised(hardwareAddress text: String) -> String? {
        let bytes = text.split(separator: ":", omittingEmptySubsequences: false)
        guard bytes.count == 6 else { return nil }
        var result: [String] = []
        for byte in bytes {
            guard (1...2).contains(byte.count), let value = UInt8(byte, radix: 16) else { return nil }
            result.append(String(format: "%02x", value))
        }
        return result.joined(separator: ":")
    }
}
