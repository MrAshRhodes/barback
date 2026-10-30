import AppKit
import BarbackCore

extension StatusIcons {
    /// The Barback icon while its click opens the drop-down panel: the chevron-style glyphs point down (up while the
    /// panel is open). Nil for styles without a directional glyph; those keep their usual images.
    static func dropDownImage(style: ToggleIconStyle, weight: IconWeight, panelOpen: Bool, label: String?) -> NSImage? {
        guard let name = style.dropDownSymbolName(panelOpen: panelOpen) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: togglePointSize, weight: weight.fontWeight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }
}
