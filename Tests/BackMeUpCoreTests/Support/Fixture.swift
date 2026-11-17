import Foundation

/// Loads saved command output from `Tests/BackMeUpCoreTests/Fixtures`.
func fixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw FixtureMissing(name: name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

struct FixtureMissing: Error {
    let name: String
}
