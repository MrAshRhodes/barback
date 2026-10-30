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

    /// AX elements are confined to the worker's serial queue, including the scan that creates them.
    private struct Target: @unchecked Sendable {
        let frame: CGRect
        let scan: MenuBarScan
    }

    private let worker = ItemOpenWorker<Target>(
        firstDelay: firstDelay,
        retryDelay: retryDelay,
        isTrusted: { AXIsProcessTrusted() },
        press: { target in
            guard AXIsProcessTrusted() else { return .failure(.permissionRequired) }
            guard let result = AccessibilityScanner.pressResult(itemAt: target.frame, in: target.scan) else {
                return .failure(.unavailable)
            }
            switch result {
            case .success: return .success(())
            case .apiDisabled: return .failure(.permissionRequired)
            case .cannotComplete: return .failure(.uncertain)
            default: return .failure(.couldNotOpen)
            }
        }
    )

    /// A newer call or cancellation abandons scans that have not committed their press yet.
    func open(key: ItemKey, display: Int?, completion: @escaping (Result<Void, ItemOpenError>) -> Void = { _ in }) {
        let displays = ItemsModel.currentDisplays()
        let tops = displays.map(\.frame.minY)
        let apps = RunningAppInfo.current()
        worker.open(scan: {
            let scan = AccessibilityScanner.scan(tops: tops, trusted: true, apps: apps)
            let keys = ItemKeyAssigner.panelKeys(for: scan.items, displays: displays)
            guard let item = scan.items.first(where: {
                keys[$0.windowID] == key
                    && (display == nil || ItemClassifier.displayIndex(for: $0.frame, in: displays) == display)
                    && $0.isVisible(onScreens: displays.map(\.frame))
            }),
                  FrameMatcher.bestMatchIndex(for: item.frame, among: scan.elements.map(\.frame)) != nil else { return nil }
            return Target(frame: item.frame, scan: scan)
        }) { result in
            switch result {
            case .success: Log.items.info("Opened a menu bar item from the panel")
            case .failure(let error): Log.items.notice("Could not confirm item opening: \(error.localizedDescription, privacy: .public)")
            }
            completion(result)
        }
    }

    func cancel() { worker.cancel() }
}
