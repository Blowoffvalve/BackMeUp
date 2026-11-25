import Foundation

/// How the menu writes a size in bytes. Pure, like `MenuText`.
enum SizeText {
    /// "251.55 GB", "840 MB": decimal units, as Finder shows file sizes, in a fixed locale so the
    /// text is the same everywhere.
    static func describe(bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US_POSIX")))
    }
}
