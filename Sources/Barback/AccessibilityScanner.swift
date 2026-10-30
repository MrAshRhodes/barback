import AppKit
import ApplicationServices
import BarbackCore

/// A running app, copied off `NSWorkspace` so a scan can run off the main actor.
struct RunningAppInfo: Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String?

    @MainActor
    static func current() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier)
        }
    }
}

/// One scan of the menu bar: the window-list items and, when Accessibility is allowed, the elements behind them.
struct MenuBarScan {
    var items: [MenuBarItem]
    var elements: [(frame: CGRect, element: AXUIElement)]
}

/// Reads status items through the Accessibility API (`AXExtrasMenuBar`). Everything here blocks on other apps,
/// so call it from a background task only.
enum AccessibilityScanner {
    /// Lists the window-list items and resolves them to apps and names when `trusted`.
    nonisolated static func scan(tops: [CGFloat], trusted: Bool, apps: [RunningAppInfo]) -> MenuBarScan {
        let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var items = MenuBarItemParser.parse(raw, menuBarTops: tops)
        // Apps draw their own windows except on macOS 26, where Control Center hosts them all.
        var bundleIDs: [pid_t: String] = [:]
        for app in apps { if let id = app.bundleID { bundleIDs[app.pid] = id } }
        for index in items.indices where !items[index].isHostedBySystem {
            items[index].bundleID = bundleIDs[pid_t(items[index].ownerPID)]
        }
        guard trusted else { return MenuBarScan(items: items, elements: []) }
        let entries = extras(apps: apps)
        items = MenuBarItemParser.resolve(items, using: entries.map(\.item))
        return MenuBarScan(items: items, elements: entries.map { ($0.item.frame, $0.element) })
    }

    /// The status item elements of every other running app.
    nonisolated static func extras(apps: [RunningAppInfo]) -> [(item: AccessibilityItem, element: AXUIElement)] {
        var result: [(item: AccessibilityItem, element: AXUIElement)] = []
        for app in apps where app.pid != getpid() {
            let root = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(root, 0.1)
            guard let bar = element(root, "AXExtrasMenuBar"),
                  let children = value(bar, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                guard let origin = point(child, kAXPositionAttribute), let size = size(child, kAXSizeAttribute) else { continue }
                let description = string(child, kAXDescriptionAttribute) ?? string(child, kAXTitleAttribute)
                result.append((
                    AccessibilityItem(
                        appName: app.name,
                        bundleID: app.bundleID,
                        pid: app.pid,
                        description: description,
                        frame: CGRect(origin: origin, size: size)
                    ),
                    child
                ))
            }
        }
        return result
    }

    /// Presses the element whose frame matches `frame`. An app that opens its menu inside the press may not
    /// answer until the menu closes, so a timeout counts as pressed too.
    nonisolated static func press(itemAt frame: CGRect, in scan: MenuBarScan) -> Bool {
        guard let index = FrameMatcher.bestMatchIndex(for: frame, among: scan.elements.map(\.frame)) else { return false }
        let target = scan.elements[index].element
        AXUIElementSetMessagingTimeout(target, 2)
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        return result == .success || result == .cannotComplete
    }

    // MARK: - Attribute helpers

    nonisolated private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success ? ref : nil
    }

    nonisolated private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let ref = value(el, attr), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    nonisolated private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    nonisolated private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let ref = value(el, attr), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &p) ? p : nil
    }

    nonisolated private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let ref = value(el, attr), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &s) ? s : nil
    }
}
