import Foundation

/// Defensive reader for the undocumented plists that `tmutil -X` and friends print.
/// Every accessor returns nil when a key is missing or has a type we don't expect.
struct PlistDictionary {
    let values: [String: Any]

    init?(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        values = dictionary
    }

    init(_ values: [String: Any]) {
        self.values = values
    }

    /// Accepts `<true/>`/`<false/>` and integers 0/1, which `tmutil` uses interchangeably.
    func bool(_ key: String) -> Bool? {
        switch values[key] {
        case let value as Bool: value
        case let value as NSNumber: value.intValue != 0
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue
    }

    func string(_ key: String) -> String? {
        values[key] as? String
    }

    func dictionary(_ key: String) -> PlistDictionary? {
        (values[key] as? [String: Any]).map(PlistDictionary.init)
    }

    func array(_ key: String) -> [PlistDictionary]? {
        (values[key] as? [Any])?.compactMap { ($0 as? [String: Any]).map(PlistDictionary.init) }
    }
}
