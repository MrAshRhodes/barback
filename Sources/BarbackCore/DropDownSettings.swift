import Foundation

/// What a plain click on the Barback icon does. Option-click always toggles every section, whichever is chosen.
public enum ClickAction: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Slide the hidden items into the menu bar (the original behaviour).
    case revealStrip
    /// Open a drop-down panel under the icon listing the hidden items.
    case dropDown

    public static let `default`: ClickAction = .revealStrip

    public var id: String { rawValue }
}

/// How the drop-down panel lays out each box.
public enum DropDownLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case list
    case grid

    public static let `default`: DropDownLayout = .list

    public var id: String { rawValue }
}

/// Pure rules for what the drop-down panel lists.
public enum DropDownContent {
    public enum Box: Equatable, Sendable {
        /// The hidden section: organised into the user's groups.
        case hidden
        /// The always-hidden section: one box of its own.
        case alwaysHidden
    }

    /// The box an item belongs in, or nil when the panel shouldn't list it: Barback's own items, items macOS
    /// isn't drawing (turned off in System Settings, so Barback isn't hiding them), items that sit on a display
    /// without Barback's separators, and always-hidden items while that section is turned off.
    public static func box(
        section: MenuBarSection,
        visibility: ItemVisibility,
        isBarbackItem: Bool,
        alwaysHiddenEnabled: Bool
    ) -> Box? {
        guard !isBarbackItem, visibility != .notDrawn else { return nil }
        switch section {
        case .hidden: return .hidden
        case .alwaysHidden: return alwaysHiddenEnabled ? .alwaysHidden : nil
        case .visible, .unknown: return nil
        }
    }

    /// The reveal needed to get at an item in `box` (the always-hidden section needs everything shown).
    public static func revealAction(for box: Box) -> SectionAction {
        box == .alwaysHidden ? .showAll : .show
    }

    /// Symbol for a system item that has no app icon of its own.
    public static let genericSystemSymbol = "menubar.rectangle"

    private static let systemSymbols: [String: String] = [
        "wi-fi": "wifi",
        "battery": "battery.100",
        "sound": "speaker.wave.2",
        "focus": "moon",
        "clock": "clock",
        "control center": "switch.2",
        "spotlight": "magnifyingglass",
        "siri": "waveform",
        "display": "display",
        "now playing": "play.circle",
        "screen mirroring": "airplayvideo",
        "vpn": "network.badge.shield.half.filled",
        "user switcher": "person.crop.circle",
        "keyboard brightness": "light.max",
        "input menu": "keyboard",
    ]

    /// Every symbol `systemSymbol(forDetail:)` can return.
    public static var systemSymbolNames: [String] { [genericSystemSymbol] + Array(systemSymbols.values) }

    /// A fitting symbol for a system item from its Accessibility title (English titles; any other title gets the
    /// generic symbol).
    public static func systemSymbol(forDetail detail: String?) -> String {
        guard let detail else { return genericSystemSymbol }
        return systemSymbols[detail.trimmingCharacters(in: .whitespaces).lowercased()] ?? genericSystemSymbol
    }
}

extension ToggleIconStyle {
    /// Glyph for the Barback icon while the click action opens a panel below it. Only directional styles have one
    /// (a left-pointing chevron makes no sense for a drop-down); others keep their usual hidden/showing pair.
    public func dropDownSymbolName(panelOpen: Bool) -> String? {
        switch self {
        case .chevron: return panelOpen ? "chevron.up" : "chevron.down"
        case .chevronCircle: return panelOpen ? "chevron.up.circle.fill" : "chevron.down.circle"
        case .triangle: return panelOpen ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"
        default: return nil
        }
    }
}
