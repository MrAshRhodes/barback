import AppKit
import ApplicationServices
import BarbackCore

/// Opens a hidden item's own menu from the drop-down panel: after the items have been revealed, finds the item
/// again by its key and presses it through Accessibility.
@MainActor
final class ItemOpener {
    /// Time for the menu bar to lay out after a reveal, and for the one retry if it hadn't yet.
    static let firstDelay: TimeInterval = 0.3
    static let retryDelay: TimeInterval = 0.4

    private var generation = 0

    /// Starts opening `key`. A newer call, or `cancel()`, abandons one that is still waiting.
    func open(key: ItemKey, display: Int?) {
        generation += 1
        attempt(key: key, display: display, retry: false, generation: generation)
    }

    func cancel() { generation += 1 }

    private func attempt(key: ItemKey, display: Int?, retry: Bool, generation: Int) {
        let delay = retry ? Self.retryDelay : Self.firstDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.scanAndPress(key: key, display: display, retry: retry, generation: generation)
        }
    }

    private func scanAndPress(key: ItemKey, display: Int?, retry: Bool, generation: Int) {
        let displays = ItemsModel.currentDisplays()
        let tops = displays.map(\.frame.minY)
        let apps = RunningAppInfo.current()
        Task.detached(priority: .userInitiated) {
            let scan = AccessibilityScanner.scan(tops: tops, trusted: true, apps: apps)
            let pressed = Self.press(key: key, display: display, displays: displays, in: scan)
            await self.finished(pressed: pressed, key: key, display: display, retry: retry, generation: generation)
        }
    }

    /// Presses the item carrying `key` if the scan shows it on screen.
    nonisolated private static func press(key: ItemKey, display: Int?, displays: [MenuBarDisplay], in scan: MenuBarScan) -> Bool {
        guard let item = ItemKeyAssigner.item(for: key, in: scan.items, displays: displays, display: display),
              item.isVisible(onScreens: displays.map(\.frame)) else { return false }
        return AccessibilityScanner.press(itemAt: item.frame, in: scan)
    }

    private func finished(pressed: Bool, key: ItemKey, display: Int?, retry: Bool, generation: Int) {
        guard self.generation == generation else { return }
        if pressed {
            Log.items.info("Opened a menu bar item from the panel")
        } else if !retry {
            attempt(key: key, display: display, retry: true, generation: generation)
        } else {
            Log.items.notice("Could not open the item; it stays revealed")
        }
    }
}
