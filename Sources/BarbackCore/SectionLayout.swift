import CoreGraphics

/// Which of Barback's sections are currently revealed.
public enum SectionState: String, Equatable, Sendable {
    /// Hidden and always-hidden sections are collapsed off-screen.
    case hidden
    /// Hidden section revealed; always-hidden still collapsed.
    case shown
    /// Everything revealed, including the always-hidden section.
    case shownAll

    public var isRevealed: Bool { self != .hidden }
}

/// User intents that change the section state.
public enum SectionAction: Sendable {
    case toggle
    case toggleAll
    case show
    case showAll
    case hide
}

/// Where an arbitrary menu bar item sits relative to Barback's separators.
public enum MenuBarSection: String, Equatable, Sendable {
    case visible
    case hidden
    case alwaysHidden
    /// The item is on a display where Barback's separators aren't, so its section can't be told.
    case unknown
}

/// Result of checking the on-screen order of Barback's own status items.
public enum LayoutValidation: Equatable, Sendable {
    /// Always-hidden separator ← hidden separator ← chevron (left to right).
    case valid
    /// The hidden separator is right of the chevron: expanding it would push the chevron off-screen.
    case hiddenSeparatorMisplaced
    /// The always-hidden separator is right of the hidden separator.
    case alwaysHiddenSeparatorMisplaced
    /// Frames are not available yet (items not laid out).
    case unknown

    public var canHideHiddenSection: Bool { self == .valid || self == .alwaysHiddenSeparatorMisplaced }
}

/// Lengths to apply to the two separator status items.
public struct SeparatorLengths: Equatable, Sendable {
    public var hidden: CGFloat
    public var alwaysHidden: CGFloat
    public init(hidden: CGFloat, alwaysHidden: CGFloat) {
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

/// Pure ordering / sizing rules for the separator mechanism.
public enum SectionLayout {
    /// Expanded separator length: wide enough to push everything to its left past the screen edge.
    public static let expandedLength: CGFloat = 10_000
    /// Normal (collapsed) separator length when its section is revealed.
    public static let separatorLength: CGFloat = 14
    /// Points of overlap tolerated when comparing frames.
    public static let tolerance: CGFloat = 1

    /// Validates left-to-right order using window frames (x grows to the right in both AppKit and CG space).
    ///
    /// Uses each separator's *right* edge so it works whether the separator is currently collapsed or expanded
    /// (an expanded separator grows leftwards; its right edge stays put).
    public static func validate(chevron: CGRect?, hiddenSeparator: CGRect?, alwaysHiddenSeparator: CGRect?) -> LayoutValidation {
        guard let chevron, let hiddenSeparator, chevron.width > 0, hiddenSeparator.width > 0 else {
            return .unknown
        }
        if hiddenSeparator.maxX > chevron.minX + tolerance { return .hiddenSeparatorMisplaced }
        if let always = alwaysHiddenSeparator, always.width > 0, always.maxX > hiddenSeparator.minX + tolerance {
            return .alwaysHiddenSeparatorMisplaced
        }
        return .valid
    }

    /// Default collapsed lengths for both separators.
    public static let defaultCollapsed = SeparatorLengths(hidden: separatorLength, alwaysHidden: separatorLength)

    /// Computes separator lengths for a state, never expanding a separator whose position would hide the chevron.
    /// `collapsed` holds each separator's length while its section is showing (depends on its divider style).
    public static func lengths(
        for state: SectionState,
        validation: LayoutValidation,
        alwaysHiddenEnabled: Bool,
        collapsed: SeparatorLengths = defaultCollapsed
    ) -> SeparatorLengths {
        let canHide = validation.canHideHiddenSection
        let alwaysUsable = alwaysHiddenEnabled && validation == .valid
        switch state {
        case .hidden:
            return SeparatorLengths(
                hidden: canHide ? expandedLength : collapsed.hidden,
                alwaysHidden: alwaysUsable ? expandedLength : collapsed.alwaysHidden
            )
        case .shown:
            return SeparatorLengths(hidden: collapsed.hidden, alwaysHidden: alwaysUsable ? expandedLength : collapsed.alwaysHidden)
        case .shownAll:
            return collapsed
        }
    }

    /// State transition for a user action.
    public static func nextState(from current: SectionState, action: SectionAction, alwaysHiddenEnabled: Bool) -> SectionState {
        switch action {
        case .toggle:
            return current == .hidden ? .shown : .hidden
        case .toggleAll:
            guard alwaysHiddenEnabled else { return current == .hidden ? .shown : .hidden }
            return current == .shownAll ? .hidden : .shownAll
        case .show:
            return current == .hidden ? .shown : current
        case .showAll:
            return alwaysHiddenEnabled ? .shownAll : .shown
        case .hide:
            return .hidden
        }
    }

    /// Classifies an item by its left edge relative to the separators' right edges.
    public static func section(
        ofItemMinX minX: CGFloat,
        hiddenSeparatorMaxX: CGFloat?,
        alwaysHiddenSeparatorMaxX: CGFloat?
    ) -> MenuBarSection {
        if let a = alwaysHiddenSeparatorMaxX, minX < a - tolerance { return .alwaysHidden }
        if let h = hiddenSeparatorMaxX, minX < h - tolerance { return .hidden }
        return .visible
    }
}
