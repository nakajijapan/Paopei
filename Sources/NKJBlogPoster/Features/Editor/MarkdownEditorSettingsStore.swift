import AppKit
import Foundation

/// Persists display-only preferences for the Markdown editor.
struct MarkdownEditorSettingsStore: @unchecked Sendable {
    /// A 15-point default keeps long-form Japanese Markdown readable in the
    /// editor while retaining a compact option for dense workspaces.
    static let defaultFontSize: CGFloat = 15
    static let availableFontSizes: [CGFloat] = [11, NSFont.systemFontSize, defaultFontSize, 17, 19, 21]

    private let defaults: UserDefaults
    private let fontSizeKey: String

    init(
        defaults: UserDefaults = .standard,
        fontSizeKey: String = "markdownEditorFontSize"
    ) {
        self.defaults = defaults
        self.fontSizeKey = fontSizeKey
    }

    func fontSize() -> CGFloat {
        guard let storedValue = defaults.object(forKey: fontSizeKey) as? NSNumber else {
            return Self.defaultFontSize
        }
        let storedSize = CGFloat(truncating: storedValue)
        return Self.availableFontSizes.contains(storedSize) ? storedSize : Self.defaultFontSize
    }

    func saveFontSize(_ fontSize: CGFloat) {
        let value = Self.availableFontSizes.contains(fontSize) ? fontSize : Self.defaultFontSize
        defaults.set(Double(value), forKey: fontSizeKey)
    }
}
