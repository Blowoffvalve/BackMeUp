import Foundation

/// The network the Mac is on, as far as BackMeUp can tell without sending anything.
public enum NetworkReading: Equatable, Sendable {
    /// On a network whose router has this hardware address. The same router seen over Wi-Fi or
    /// Ethernet has the same address. `wifiName` is nil without Location permission, or on Ethernet.
    case router(address: String, wifiName: String?)
    /// There's a default route on a physical interface, but the router's hardware address isn't
    /// in the ARP table (yet).
    case routerAddressUnknown
    /// No default route on a physical interface: offline, or only a VPN or tunnel.
    case none
}

/// A network the user has allowed backups on. Recognised by its router's hardware address, which
/// is never shown; the label is what the user sees.
public struct ChosenNetwork: Codable, Equatable, Sendable {
    public var routerAddress: String
    public var label: String

    public init(routerAddress: String, label: String) {
        self.routerAddress = routerAddress
        self.label = label
    }
}

/// Which networks a network disk may back up on.
public struct NetworkSettings: Codable, Equatable, Sendable {
    public var chosen: [ChosenNetwork]
    /// When on, network disks back up on any network.
    public var allNetworks: Bool

    public init(chosen: [ChosenNetwork] = [], allNetworks: Bool = false) {
        self.chosen = chosen
        self.allNetworks = allNetworks
    }

    /// The chosen network with this router, if any.
    public func network(routerAddress: String) -> ChosenNetwork? {
        chosen.first { $0.routerAddress == routerAddress }
    }

    /// Why a network disk can't back up on this network, or nil if it can.
    func skipReason(on reading: NetworkReading) -> SkipReason? {
        if allNetworks { return nil }
        switch reading {
        case let .router(address, _):
            return network(routerAddress: address) == nil ? .notOnChosenNetwork : nil
        case .routerAddressUnknown:
            return .networkUnidentified
        case .none:
            return .notOnChosenNetwork
        }
    }
}
