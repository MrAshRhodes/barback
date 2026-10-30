import AppKit
import ApplicationServices
import BarbackCore

/// One row in Settings › Items, and one candidate for the drop-down panel.
struct MenuBarItemRow: Identifiable, Hashable {
    var item: MenuBarItem
    var section: MenuBarSection
    var visibility: ItemVisibility
    var overlapsNotch: Bool
    /// Non-nil for Barback's own status items.
    var barbackRole: String?
    /// Identity that survives relaunches; what groups store.
    var key: ItemKey
    /// Index of the display the item is on (into the scan's displays); nil when it can't be told.
    var display: Int?

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

    /// The name shown in the drop-down panel.
    var panelTitle: String {
        if barbackRole == nil, item.isSystemItem, item.detail == nil, item.resolvedName == nil, item.title == nil {
            return String(localized: "Unidentified Item")
        }
        return barbackRole ?? item.panelName
    }
}

/// On-demand snapshot of the menu bar (refreshed when the Items tab appears, the drop-down panel opens or Refresh is
/// clicked; never polled).
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

    /// Re-reads whether Accessibility is allowed, e.g. after the user comes back from System Settings.
    func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
    }

    /// Displays that show a menu bar, in CoreGraphics coordinates.
    static func currentDisplays() -> [MenuBarDisplay] {
        ScreenInfo.screensWithMenuBar.map {
            MenuBarDisplay(
                frame: ScreenInfo.cgRect(fromAppKit: $0.frame),
                notch: ScreenInfo.notch(for: $0).map(ScreenInfo.cgRect(fromAppKit:))
            )
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        accessibilityTrusted = AXIsProcessTrusted()

        let displays = Self.currentDisplays()
        let tops = displays.map(\.frame.minY)
        hasNotch = displays.contains { $0.notch != nil }
        let own = statusBar?.ownItems
        let trusted = accessibilityTrusted
        let apps = RunningAppInfo.current()

        Task.detached(priority: .userInitiated) {
            let signpost = Log.signposter.beginInterval("Scan items", id: Log.signposter.makeSignpostID())
            let items = AccessibilityScanner.scan(tops: tops, trusted: trusted, apps: apps).items
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
        let keys = ItemKeyAssigner.keys(for: items, displays: displays)
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
                                  barbackRole: role,
                                  key: keys[item.windowID] ?? ItemKey(owner: item.ownerName),
                                  display: placement.display)
        }
        .reversed() // Right to left, matching how people read the status area.
    }
}
