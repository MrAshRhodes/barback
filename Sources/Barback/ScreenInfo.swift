import AppKit
import BarbackCore

/// AppKit adapters around the pure geometry in BarbackCore.
@MainActor
enum ScreenInfo {
    /// Screens that show a menu bar: all of them with "Displays have separate Spaces", otherwise only the main one.
    static var screensWithMenuBar: [NSScreen] {
        if NSScreen.screensHaveSeparateSpaces { return NSScreen.screens }
        return NSScreen.screens.first.map { [$0] } ?? []
    }

    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        MenuBarGeometry.menuBarHeight(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            statusBarThickness: NSStatusBar.system.thickness
        )
    }

    static func notch(for screen: NSScreen) -> CGRect? {
        NotchGeometry.notchRect(
            screenFrame: screen.frame,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    static func isMouseInMenuBar(_ p: CGPoint = NSEvent.mouseLocation) -> Bool {
        screensWithMenuBar.contains {
            MenuBarGeometry.isPoint(p, inMenuBarOf: $0.frame, menuBarHeight: menuBarHeight(for: $0))
        }
    }

    static func isInHoverZone(_ p: CGPoint) -> Bool {
        screensWithMenuBar.contains {
            MenuBarGeometry.isInHoverZone(p, screenFrame: $0.frame, menuBarHeight: menuBarHeight(for: $0), notch: notch(for: $0))
        }
    }

    /// Height of the primary display, used to flip AppKit y into CoreGraphics y.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit rect → CoreGraphics global rect (origin top-left of the primary display).
    static func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// True if another app (or we) currently shows a pop-up menu. One-shot query; only called on timer fire.
    static func isAnyMenuOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return MenuBarItemParser.containsOpenMenu(list)
    }
}
