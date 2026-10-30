import CoreGraphics

/// Glyph set for Barback's always-visible toggle item. Every symbol ships with SF Symbols 4 or earlier,
/// so all of them exist on macOS 14.
public enum ToggleIconStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case chevron
    case chevronCircle
    case triangle
    case eye
    case ellipsis
    case lines
    case wineglass
    case mug
    case dot

    public static let `default`: ToggleIconStyle = .chevron

    public var id: String { rawValue }

    /// SF Symbol shown while hidden items are hidden (`revealed == false`) or showing.
    /// Directional glyphs point the way the hidden items will appear or go.
    public func symbolName(revealed: Bool) -> String {
        switch self {
        case .chevron: return revealed ? "chevron.right" : "chevron.left"
        case .chevronCircle: return revealed ? "chevron.right.circle.fill" : "chevron.left.circle"
        case .triangle: return revealed ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill"
        case .eye: return revealed ? "eye" : "eye.slash"
        case .ellipsis: return revealed ? "ellipsis.circle.fill" : "ellipsis.circle"
        case .lines: return revealed ? "line.3.horizontal.circle.fill" : "line.3.horizontal.circle"
        case .wineglass: return revealed ? "wineglass.fill" : "wineglass"
        case .mug: return revealed ? "mug.fill" : "mug"
        case .dot: return revealed ? "circlebadge" : "circlebadge.fill"
        }
    }

    /// Used if a symbol can't be loaded.
    public static func fallbackSymbolName(revealed: Bool) -> String {
        ToggleIconStyle.default.symbolName(revealed: revealed)
    }
}

/// Stroke weight for the toggle icon (SF Symbol weight).
public enum IconWeight: String, CaseIterable, Codable, Sendable, Identifiable {
    case regular
    case medium
    case semibold
    case bold

    public static let `default`: IconWeight = .semibold

    public var id: String { rawValue }
}

/// One filled rounded rectangle of a divider glyph, in a `DividerStyle.canvasSize` canvas (origin bottom-left).
public struct DividerSegment: Equatable, Sendable {
    public var rect: CGRect
    public var cornerRadius: CGFloat

    public init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// Look of a separator or extra divider in the menu bar.
public enum DividerStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// │ thin rounded bar.
    case line
    /// ┊ dotted bar.
    case dashed
    /// • small dot.
    case dot
    /// ‖ two thin bars.
    case doubleLine
    /// ‹ compact chevron (SF Symbol).
    case chevron
    /// Nothing drawn; a narrow gap that can still be ⌘-dragged.
    case none

    public var id: String { rawValue }

    /// Canvas for the drawn glyphs, in points.
    public static let canvasSize = CGSize(width: 8, height: 16)
    /// Width of an invisible divider; narrow, but still wide enough to grab with ⌘-drag.
    public static let invisibleLength: CGFloat = 8

    /// SF Symbol used instead of drawn segments, if any.
    public var symbolName: String? {
        self == .chevron ? "chevron.compact.left" : nil
    }

    /// Status item length while the divider is collapsed (its section showing).
    public var collapsedLength: CGFloat {
        self == .none ? Self.invisibleLength : SectionLayout.separatorLength
    }

    public var isVisible: Bool { self != .none }

    /// Shapes to fill for drawn styles (empty for `chevron` and `none`). All fit inside `canvasSize`.
    public var segments: [DividerSegment] {
        let w = Self.canvasSize.width
        let bar: CGFloat = 1.5
        switch self {
        case .line:
            return [DividerSegment(rect: CGRect(x: (w - bar) / 2, y: 1.5, width: bar, height: 13), cornerRadius: bar / 2)]
        case .dashed:
            return (0..<4).map { i in
                DividerSegment(rect: CGRect(x: (w - bar) / 2, y: 1.5 + CGFloat(i) * 3.5, width: bar, height: 2), cornerRadius: bar / 2)
            }
        case .dot:
            let d: CGFloat = 3.5
            return [DividerSegment(rect: CGRect(x: (w - d) / 2, y: (Self.canvasSize.height - d) / 2, width: d, height: d), cornerRadius: d / 2)]
        case .doubleLine:
            let gap: CGFloat = 1.5
            let x0 = (w - (bar * 2 + gap)) / 2
            return [
                DividerSegment(rect: CGRect(x: x0, y: 2.5, width: bar, height: 11), cornerRadius: bar / 2),
                DividerSegment(rect: CGRect(x: x0 + bar + gap, y: 2.5, width: bar, height: 11), cornerRadius: bar / 2),
            ]
        case .chevron, .none:
            return []
        }
    }
}

/// The appearance part of `BarbackSettings`.
public struct AppearanceSettings: Equatable, Codable, Sendable {
    public var toggleIcon: ToggleIconStyle
    public var iconWeight: IconWeight
    /// Tint the toggle icon with the accent colour while hidden items are showing (colour conveys state).
    public var tintWhenShowing: Bool
    public var hiddenDivider: DividerStyle
    public var alwaysHiddenDivider: DividerStyle
    /// Number of extra decorative dividers (0…`maxExtraDividers`).
    public var extraDividerCount: Int
    public var extraDividerStyle: DividerStyle

    public static let maxExtraDividers = 3

    public init(
        toggleIcon: ToggleIconStyle = .default,
        iconWeight: IconWeight = .default,
        tintWhenShowing: Bool = false,
        hiddenDivider: DividerStyle = .line,
        alwaysHiddenDivider: DividerStyle = .dashed,
        extraDividerCount: Int = 0,
        extraDividerStyle: DividerStyle = .line
    ) {
        self.toggleIcon = toggleIcon
        self.iconWeight = iconWeight
        self.tintWhenShowing = tintWhenShowing
        self.hiddenDivider = hiddenDivider
        self.alwaysHiddenDivider = alwaysHiddenDivider
        self.extraDividerCount = extraDividerCount
        self.extraDividerStyle = extraDividerStyle
    }

    public static let `default` = AppearanceSettings()

    public func sanitized() -> AppearanceSettings {
        var a = self
        a.extraDividerCount = min(max(0, extraDividerCount), Self.maxExtraDividers)
        return a
    }

    /// The named style these settings match, or nil for a custom combination.
    public var style: AppearanceStyle? { AppearanceStyle.matching(self) }

    /// Applies a named style's icon and separators, keeping weight, tint and extra dividers.
    public mutating func apply(_ style: AppearanceStyle) {
        toggleIcon = style.toggleIcon
        hiddenDivider = style.hiddenDivider
        alwaysHiddenDivider = style.alwaysHiddenDivider
    }
}

/// One-click looks ("themes") for Barback's own items. They only change Barback's icons, never the menu bar.
public enum AppearanceStyle: String, CaseIterable, Sendable, Identifiable {
    case classic
    case minimal
    case cocktail
    case eye
    case arrows

    public var id: String { rawValue }

    public var toggleIcon: ToggleIconStyle {
        switch self {
        case .classic: return .chevron
        case .minimal: return .dot
        case .cocktail: return .wineglass
        case .eye: return .eye
        case .arrows: return .triangle
        }
    }

    public var hiddenDivider: DividerStyle {
        switch self {
        case .classic: return .line
        case .minimal: return .none
        case .cocktail: return .dot
        case .eye: return .line
        case .arrows: return .chevron
        }
    }

    public var alwaysHiddenDivider: DividerStyle {
        switch self {
        case .classic: return .dashed
        case .minimal: return .none
        case .cocktail: return .dashed
        case .eye: return .dot
        case .arrows: return .doubleLine
        }
    }

    public static func matching(_ a: AppearanceSettings) -> AppearanceStyle? {
        allCases.first {
            $0.toggleIcon == a.toggleIcon && $0.hiddenDivider == a.hiddenDivider && $0.alwaysHiddenDivider == a.alwaysHiddenDivider
        }
    }
}
