import AppKit

/// Appearance-aware colors for the editor chrome.
///
/// The default AppKit semantic grays (`.secondaryLabelColor`,
/// `.tertiaryLabelColor`, `.separatorColor`) read as washed-out on a white
/// background, which made light mode look plain. These colors keep the existing
/// dark-mode look (they resolve to the same semantic colors there) but use
/// noticeably darker, higher-contrast values in light mode.
enum Palette {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Parameter name labels (previously `.secondaryLabelColor`).
    static let parameterName = dynamic(light: NSColor(white: 0.20, alpha: 1),
                                       dark: .secondaryLabelColor)

    /// Small uppercase section titles (previously `.tertiaryLabelColor`).
    static let sectionTitle = dynamic(light: NSColor(white: 0.28, alpha: 1),
                                      dark: .tertiaryLabelColor)

    /// Unit suffixes, captions, and other secondary text.
    static let secondaryText = dynamic(light: NSColor(white: 0.34, alpha: 1),
                                       dark: .secondaryLabelColor)

    /// Faint helper text (placeholders, empty states) — previously
    /// `.tertiaryLabelColor`.
    static let tertiaryText = dynamic(light: NSColor(white: 0.45, alpha: 1),
                                      dark: .tertiaryLabelColor)

    /// Control tints (section dice, small glyph buttons).
    static let controlGlyph = dynamic(light: NSColor(white: 0.32, alpha: 1),
                                      dark: .secondaryLabelColor)

    /// Card border, more defined on white (previously `.separatorColor`).
    static let cardBorder = dynamic(light: NSColor(white: 0.75, alpha: 1),
                                    dark: .separatorColor)
}
