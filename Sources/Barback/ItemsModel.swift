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
    /// Scan identity; panel candidates replace positional keys with safe selectors.
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
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var hasNotch = false

    private let scansEnabled: Bool
    private var refreshPending = false
    weak var statusBar: StatusBarController?

    init() {
        accessibilityTrusted = AXIsProcessTrusted()
        scansEnabled = true
    }

    /// An immutable menu-bar snapshot for previews and native UI tests, without scans or permission prompts.
    init(snapshot rows: [MenuBarItemRow], accessibilityTrusted: Bool = true) {
        self.rows = rows
        self.accessibilityTrusted = accessibilityTrusted
        scansEnabled = false
        hasNotch = rows.contains(where: \.overlapsNotch)
    }

    var notchRows: [MenuBarItemRow] { rows.filter(\.overlapsNotch) }
    var systemHosted: Bool { rows.contains { $0.item.isHostedBySystem && $0.barbackRole == nil } }
    var panelCandidates: [MenuBarItemRow] { Self.panelCandidates(from: rows) }
    var unidentifiedPanelItemCount: Int {
        let keys = Self.panelKeys(from: rows)
        return rows.filter { $0.barbackRole == nil && $0.visibility != .notDrawn && keys[$0.id] == nil }.count
    }

    static func panelCandidates(from rows: [MenuBarItemRow]) -> [MenuBarItemRow] {
        let keys = panelKeys(from: rows)
        var seen = Set<ItemKey>()
        // Prefer a drawn copy, so a mirrored off-screen copy does not request an unnecessary reveal.
        let ordered = rows.filter(\.isShown) + rows.filter { !$0.isShown }
        return ordered.compactMap { row in
            guard row.barbackRole == nil, row.visibility != .notDrawn,
                  let key = keys[row.id], seen.insert(key).inserted else { return nil }
            var row = row
            row.key = key
            return row
        }
    }

    private static func panelKeys(from rows: [MenuBarItemRow]) -> [UInt32: ItemKey] {
        let displays = rows.reduce(into: [UInt32: Int]()) { $0[$1.id] = $1.display }
        return ItemKeyAssigner.panelKeys(for: rows.map(\.item)) { displays[$0.windowID] }
    }

    func requestAccessibility() {
        guard scansEnabled else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        updateAccessibilityStatus(AXIsProcessTrustedWithOptions(options))
    }

    /// Re-reads whether Accessibility is allowed, e.g. after the user comes back from System Settings.
    func refreshAccessibilityStatus() {
        guard scansEnabled else { return }
        updateAccessibilityStatus(AXIsProcessTrusted())
    }

    private func updateAccessibilityStatus(_ trusted: Bool) {
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        refresh()
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
        guard scansEnabled else { return }
        guard !isRefreshing else {
            refreshPending = true
            return
        }
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
                let currentTrust = AXIsProcessTrusted()
                self.accessibilityTrusted = currentTrust
                if currentTrust == trusted {
                    self.rows = Self.makeRows(items, own: own, displays: displays)
                    self.lastRefreshed = Date()
                    Log.items.info("Scanned \(items.count) menu bar items")
                } else {
                    self.refreshPending = true
                }
                self.isRefreshing = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
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
            } else if item.ownerPID == getpid() || item.sourcePID == getpid() {
                role = String(localized: "Barback")
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
