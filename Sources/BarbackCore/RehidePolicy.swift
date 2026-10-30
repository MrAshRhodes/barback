import CoreGraphics
import Foundation

/// Snapshot of everything the auto-rehide timer needs to decide.
public struct RehideContext: Equatable, Sendable {
    public var state: SectionState
    public var autoRehideSeconds: Int
    public var mouseInMenuBar: Bool
    public var menuOpen: Bool

    public init(state: SectionState, autoRehideSeconds: Int, mouseInMenuBar: Bool, menuOpen: Bool) {
        self.state = state
        self.autoRehideSeconds = autoRehideSeconds
        self.mouseInMenuBar = mouseInMenuBar
        self.menuOpen = menuOpen
    }
}

public enum RehideDecision: Equatable, Sendable {
    /// Nothing to do (already hidden, or auto-rehide disabled).
    case none
    case rehideNow
    /// Check again after this many seconds (one-shot timer, not a polling loop).
    case postpone(TimeInterval)
}

public enum RehidePolicy {
    /// Delay before re-checking when the user is still interacting with the menu bar.
    public static let postponeInterval: TimeInterval = 2

    /// Delay for the first one-shot timer after revealing items; nil = never rehide.
    public static func initialDelay(autoRehideSeconds: Int) -> TimeInterval? {
        autoRehideSeconds > 0 ? TimeInterval(autoRehideSeconds) : nil
    }

    public static func decide(_ ctx: RehideContext) -> RehideDecision {
        guard ctx.state.isRevealed, ctx.autoRehideSeconds > 0 else { return .none }
        if ctx.mouseInMenuBar || ctx.menuOpen {
            return .postpone(min(postponeInterval, TimeInterval(ctx.autoRehideSeconds)))
        }
        return .rehideNow
    }

    /// "Hide again when switching apps". Clicking a revealed item often activates its app, so nothing hides
    /// while the pointer is in the menu bar or a menu is open, or when Barback itself became active.
    public static func shouldRehideOnAppSwitch(
        enabled: Bool,
        state: SectionState,
        activatedBarback: Bool,
        mouseInMenuBar: Bool,
        menuOpen: Bool
    ) -> Bool {
        enabled && state.isRevealed && !activatedBarback && !mouseInMenuBar && !menuOpen
    }
}

/// Timing and decisions for the optional "show on hover" feature.
public enum HoverPolicy {
    /// Minimum spacing between pointer checks (coalesces mouse-moved events to ≤ 20 Hz).
    public static let throttle: TimeInterval = 0.05
    /// How long the pointer must rest in the status area before hidden items are revealed.
    public static let dwell: TimeInterval = 0.2
    /// Grace period after the pointer leaves the menu bar before hover-revealed items hide again
    /// (the same 0.4 s `MouseExitDelay` Bartender uses, so a brief overshoot doesn't hide items).
    public static let exitDelay: TimeInterval = 0.4

    /// How long to wait before re-checking a hover exit that was deferred because a menu was open
    /// (one-shot, only while hover-revealed items are showing and a menu is open).
    public static let menuOpenRetryInterval: TimeInterval = 1
    /// Delay before re-checking after Barback's own menu closes, so its window has left the screen.
    public static let menuCloseRetryDelay: TimeInterval = 0.15

    /// Whether items revealed by hovering should hide once the exit delay has elapsed.
    /// Items revealed by a click, the hotkey or the menu are left to the normal auto-rehide timer.
    public static func shouldHideAfterExit(
        state: SectionState,
        revealedByHover: Bool,
        mouseInMenuBar: Bool,
        menuOpen: Bool
    ) -> Bool {
        exitDecision(state: state, revealedByHover: revealedByHover, mouseInMenuBar: mouseInMenuBar, menuOpen: menuOpen) == .hide
    }

    /// What to do when the pointer has left the menu bar. A hover exit that arrives while a menu is open is
    /// retried later (whatever the auto-rehide setting), so hover-revealed items never get stuck on screen.
    /// When the pointer is back in the menu bar nothing is pending: leaving again produces a new exit.
    public static func exitDecision(
        state: SectionState,
        revealedByHover: Bool,
        mouseInMenuBar: Bool,
        menuOpen: Bool
    ) -> HoverExitDecision {
        guard state == .shown, revealedByHover, !mouseInMenuBar else { return .none }
        return menuOpen ? .retry(after: menuOpenRetryInterval) : .hide
    }
}

public enum HoverExitDecision: Equatable, Sendable {
    case none
    case hide
    /// Re-check after this many seconds (one-shot).
    case retry(after: TimeInterval)
}

/// Coalesces high-frequency pointer events to at most one check per `interval` without ever losing the
/// latest position: an event that arrives inside the window schedules a single trailing check.
public struct HoverThrottle: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Check the pointer now.
        case processNow
        /// Schedule one trailing check after this many seconds.
        case scheduleTrailing(after: TimeInterval)
        /// A trailing check is already scheduled; it will read the latest position.
        case trailingPending
    }

    public let interval: TimeInterval
    public private(set) var lastProcessed: TimeInterval?
    public private(set) var trailingScheduled = false

    public init(interval: TimeInterval = HoverPolicy.throttle) {
        self.interval = interval
    }

    public mutating func eventArrived(at now: TimeInterval) -> Decision {
        guard let last = lastProcessed, now - last < interval else {
            lastProcessed = now
            return .processNow
        }
        if trailingScheduled { return .trailingPending }
        trailingScheduled = true
        return .scheduleTrailing(after: max(0, interval - (now - last)))
    }

    /// Call when the trailing check runs.
    public mutating func trailingFired(at now: TimeInterval) {
        trailingScheduled = false
        lastProcessed = now
    }

    public mutating func reset() {
        lastProcessed = nil
        trailingScheduled = false
    }
}

/// Menu bar geometry in AppKit screen coordinates (origin bottom-left, y grows upwards).
public enum MenuBarGeometry {
    /// Effective menu bar height for a screen. Falls back to the status bar thickness when the menu bar is
    /// auto-hidden (visibleFrame reaches the top) or the screen has no menu bar reservation.
    public static func menuBarHeight(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        statusBarThickness: CGFloat
    ) -> CGFloat {
        max(screenFrame.maxY - visibleFrame.maxY, safeAreaTop, statusBarThickness)
    }

    /// True if `point` lies within the top `menuBarHeight` points of `screenFrame` (edges inclusive).
    public static func isPoint(_ point: CGPoint, inMenuBarOf screenFrame: CGRect, menuBarHeight: CGFloat) -> Bool {
        guard menuBarHeight > 0 else { return false }
        return point.x >= screenFrame.minX && point.x <= screenFrame.maxX
            && point.y <= screenFrame.maxY && point.y >= screenFrame.maxY - menuBarHeight
    }

    /// Hover-to-show trigger zone: inside the menu bar, in the status-item half of the screen
    /// (right of the notch when there is one, otherwise the right half), and never over the notch itself.
    public static func isInHoverZone(
        _ point: CGPoint,
        screenFrame: CGRect,
        menuBarHeight: CGFloat,
        notch: CGRect?
    ) -> Bool {
        guard isPoint(point, inMenuBarOf: screenFrame, menuBarHeight: menuBarHeight) else { return false }
        if let notch, notch.width > 0 {
            return point.x > notch.maxX
        }
        return point.x >= screenFrame.midX
    }
}
