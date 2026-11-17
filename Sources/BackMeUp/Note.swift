import AppKit

extension NSTextField {
    /// A small grey note explaining a setting, wrapped to fit the Settings window.
    static func note(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 420
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }
}
