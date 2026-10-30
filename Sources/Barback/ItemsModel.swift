import AppKit
import ApplicationServices
import BarbackCore

/// One row in Settings › Items.
struct MenuBarItemRow: Identifiable, Hashable {
    var item: MenuBarItem
    var section: MenuBarSection
    var visibility: ItemVisibility
    var overlapsNotch: Bool
    /// Non-nil for Barback's own status items.
    var barbackRole: String?

    var id: UInt32 { item.windowID }
    var isShown: Bool { visibility == .shown }

    /// On macOS 26 Control Center hosts most items, so its name says nothing about an item's real source.
    var title: String {
        if let barbackRole { return barbackRole }
        if item.isHostedBySystem, item.resolvedName == nil, item.title == nil {
            return String(localized: "Unidentified Item")
        }
        return item.displayName
    }
}

/// On-demand snapshot of the menu bar (refreshed when the Items tab appears or Refresh is clicked; never polled).
@MainActor
final class ItemsModel: ObservableObject {
    @Published private(set) var rows: [MenuBarItemRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var hasNotch = false

    weak var statusBar: StatusBarController?

    var notchRows: [MenuBarItemRow] { rows.filter(\.overlapsNotch) }
    var systemHosted: Bool { rows.contains { $0.item.isHostedBySystem && $0.barbackRole == nil } }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        accessibilityTrusted = AXIsProcessTrusted()

        let screens = ScreenInfo.screensWithMenuBar
        let displays = screens.map {
            MenuBarDisplay(
                frame: ScreenInfo.cgRect(fromAppKit: $0.frame),
                notch: ScreenInfo.notch(for: $0).map(ScreenInfo.cgRect(fromAppKit:))
            )
        }
        let tops = displays.map(\.frame.minY)
        hasNotch = displays.contains { $0.notch != nil }
        let own = statusBar?.ownItems
        let trusted = accessibilityTrusted
        let apps = NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.localizedName ?? "") }

        Task.detached(priority: .userInitiated) {
            let signpost = Log.signposter.beginInterval("Scan items", id: Log.signposter.makeSignpostID())
            let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            let parsed = MenuBarItemParser.parse(raw, menuBarTops: tops)
            let items = trusted
                ? MenuBarItemParser.resolveNames(parsed, using: Self.accessibilityCandidates(apps: apps))
                : parsed
            Log.signposter.endInterval("Scan items", signpost)
            await MainActor.run {
                self.rows = Self.makeRows(items, own: own, displays: displays)
                self.lastRefreshed = Date()
                self.isRefreshing = false
                Log.items.info("Scanned \(items.count) menu bar items")
            }
        }
    }

    private static func makeRows(
        _ items: [MenuBarItem],
        own: StatusBarController.OwnItems?,
        displays: [MenuBarDisplay]
    ) -> [MenuBarItemRow] {
        func matches(_ item: MenuBarItem, _ frame: CGRect?) -> Bool {
            guard let frame else { return false }
            return abs(item.frame.maxX - frame.maxX) <= 1.5 && abs(item.frame.minY - frame.minY) <= 1.5
        }
        return items.compactMap { item in
            var role: String?
            if matches(item, own?.chevron) {
                role = String(localized: "Barback")
            } else if matches(item, own?.hiddenSeparator) {
                role = String(localized: "Barback │ separator")
            } else if matches(item, own?.alwaysHiddenSeparator) {
                role = String(localized: "Barback ┊ separator")
            } else if own?.dividers.contains(where: { matches(item, $0) }) == true {
                role = String(localized: "Barback divider")
            }
            // Each item is compared only with the separators and notch of its own display.
            let placement = ItemClassifier.classify(
                item,
                displays: displays,
                hiddenSeparator: own?.hiddenSeparator,
                alwaysHiddenSeparator: own?.alwaysHiddenSeparator
            )
            return MenuBarItemRow(item: item, section: role == nil ? placement.section : .visible,
                                  visibility: placement.visibility, overlapsNotch: placement.overlapsNotch,
                                  barbackRole: role)
        }
        .reversed() // Right to left, matching how people read the status area.
    }

    /// Reads each app's status items via Accessibility (only when the user has granted access).
    nonisolated private static func accessibilityCandidates(apps: [(pid_t, String)]) -> [(name: String, minX: CGFloat, width: CGFloat)] {
        var result: [(name: String, minX: CGFloat, width: CGFloat)] = []
        for (pid, appName) in apps where pid != getpid() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var barRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barRef) == .success,
                  let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { continue }
            let bar = barRef as! AXUIElement
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for child in children {
                guard let origin = point(child, kAXPositionAttribute), let size = size(child, kAXSizeAttribute) else { continue }
                var name = appName
                if let desc = string(child, kAXDescriptionAttribute) ?? string(child, kAXTitleAttribute),
                   !desc.isEmpty, desc != appName {
                    name = appName.isEmpty ? desc : "\(appName) — \(desc)"
                }
                result.append((name: name, minX: origin.x, width: size.width))
            }
        }
        return result
    }

    nonisolated private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    nonisolated private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &p) ? p : nil
    }

    nonisolated private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &s) ? s : nil
    }
}
