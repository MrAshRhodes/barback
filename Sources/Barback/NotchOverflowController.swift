import AppKit
import ApplicationServices
import BarbackCore
import Combine

/// Shares the drop-down's identity rules and app icons, but keeps mirrored copies on the requested display.
@MainActor
enum NotchOverflowContent {
    static func candidates(rows: [MenuBarItemRow], display: Int, alwaysHiddenEnabled: Bool) -> [DropDownPanelItem] {
        let displays = Dictionary(rows.map { ($0.id, $0.display) }, uniquingKeysWith: { first, _ in first })
        let keys = ItemKeyAssigner.panelKeys(for: rows.map(\.item)) { displays[$0.windowID] ?? nil }
        return rows.filter {
            $0.barbackRole == nil && $0.display == display && $0.visibility != .notDrawn
                && ($0.section != .alwaysHidden || alwaysHiddenEnabled)
        }.sorted { $0.item.frame.maxX > $1.item.frame.maxX }.compactMap { row in
            guard let key = keys[row.id] else { return nil }
            var safe = row
            safe.key = key
            return DropDownPanelItem(row: safe)
        }
    }

    static func fit(items: ItemsModel, state: SectionState) -> [NotchFit.Result] {
        guard items.lastRefreshed != nil, !items.snapshotContextIsStale, items.scanError == nil else { return [] }
        return NotchFit.evaluate(
            items: items.rows.filter { $0.barbackRole == nil }.map {
                .init(id: $0.id, frame: $0.item.frame, display: $0.display,
                      section: $0.section, isOnScreen: $0.item.isOnScreen)
            },
            displays: items.snapshotDisplays, state: state
        )
    }

    static func warning(results: [NotchFit.Result], names: [String]) -> String? {
        let warnings = results.filter { $0.unreachableCount > 0 }.map { result in
            let name = names.indices.contains(result.display) ? names[result.display] : String(localized: "Display \(result.display + 1)")
            return String(localized: "\(name): \(result.unreachableCount) observed menu bar items do not fit to the right of the notch.")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }
}

/// Where the strip opens: a notched display (AppKit coordinates) and the panel's frame on it.
struct NotchOverflowPlacement: Equatable {
    let screenFrame: CGRect
    let panelFrame: CGRect

    /// Prefers the notched display the status item is on.
    @MainActor
    static func measured(near anchor: NSStatusBarButton?) -> NotchOverflowPlacement? {
        let screens = ScreenInfo.screensWithMenuBar.filter { ScreenInfo.notch(for: $0) != nil }
        let screen = screens.first { $0 == anchor?.window?.screen } ?? screens.first
        guard let screen, let notch = ScreenInfo.notch(for: screen),
              let frame = NotchFit.panelFrame(screen: screen.frame, visible: screen.visibleFrame, notch: notch) else {
            return nil
        }
        return NotchOverflowPlacement(screenFrame: screen.frame, panelFrame: frame)
    }
}

/// No scan, event monitor or permission prompt is installed merely by constructing this controller.
@MainActor
final class NotchOverflowController: ObservableObject {
    @Published private(set) var hasNotchedDisplay: Bool
    @Published private(set) var warning: String?
    @Published private(set) var explanation: String?
    @Published private(set) var isShown = false

    private let model: AppModel
    private let items: ItemsModel
    private let opener = ItemOpener()
    private let isTrusted: () -> Bool
    private let requestTrust: () -> Bool
    private let hasNotch: @MainActor () -> Bool
    private let placement: @MainActor (NSStatusBarButton?) -> NotchOverflowPlacement?
    private let present: @MainActor (NotchOverflowWindow) -> Void
    private let refresh: () -> Void
    private var window: NotchOverflowWindow?
    private var targetScreenFrame: CGRect?
    private var subscriptions = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isOpening = false
    private var lastAnnouncedWarning: String?
    private var lastFitStatus: String?

    var anchor: () -> NSStatusBarButton? = { nil }
    var sectionState: () -> SectionState = { .hidden }
    var reveal: (SectionAction) -> Void = { _ in }
    var onInteractionChange: () -> Void = {}
    var onWarningChange: () -> Void = {}
    var onConfirmedOpen: (ItemKey) -> Void = { _ in }
    var isInteracting: Bool { isShown || isOpening }
    var fitStatus: String? {
        guard hasNotchedDisplay, sectionState().isRevealed else { return nil }
        if items.lastRefreshed == nil || items.snapshotContextIsStale || items.scanError != nil {
            return String(localized: "Notch fit is unknown. Refresh Items after revealing the strip to measure it.")
        }
        return warning
    }

    init(
        model: AppModel, items: ItemsModel,
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        requestTrust: @escaping () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        hasNotch: @escaping @MainActor () -> Bool = { NSScreen.screens.contains { ScreenInfo.notch(for: $0) != nil } },
        placement: @escaping @MainActor (NSStatusBarButton?) -> NotchOverflowPlacement? = {
            NotchOverflowPlacement.measured(near: $0)
        },
        present: @escaping @MainActor (NotchOverflowWindow) -> Void = {
            $0.orderFrontRegardless()
            $0.makeKey()
        },
        refresh: (() -> Void)? = nil
    ) {
        self.model = model
        self.items = items
        self.isTrusted = isTrusted
        self.requestTrust = requestTrust
        self.hasNotch = hasNotch
        self.placement = placement
        self.present = present
        self.refresh = refresh ?? { [weak items] in items?.refresh() }
        hasNotchedDisplay = hasNotch()
        opener.onConfirmedOpen = { [weak self] in self?.onConfirmedOpen($0) }
        // Consume snapshots other features already obtained. In particular, warning-only mode never scans.
        items.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.snapshotDidChange() }
            .store(in: &subscriptions)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            model.settings.notchOverflowEnabled = false
            explanation = nil
            close()
            return
        }
        guard hasNotchedDisplay else { return }
        guard isTrusted() || requestTrust() else {
            disableForPermission()
            return
        }
        explanation = nil
        model.settings.notchOverflowEnabled = true
        items.refreshAccessibilityStatus()
        show()
    }

    /// Settings imported or restored at launch may enable this feature, but never authorize a new prompt.
    func settingsDidChange() {
        guard model.settings.notchOverflowEnabled else {
            close()
            return
        }
        guard hasNotchedDisplay else {
            close()
            return
        }
        guard isTrusted() else {
            disableForPermission()
            return
        }
        rebuild()
    }

    /// Reuses StatusBarController's existing display/layout notifications.
    func environmentDidChange() {
        hasNotchedDisplay = hasNotch()
        if let frame = targetScreenFrame,
           !ScreenInfo.screensWithMenuBar.contains(where: { $0.frame == frame && ScreenInfo.notch(for: $0) != nil }) {
            close()
        }
        if !hasNotchedDisplay { close() }
        snapshotDidChange()
    }

    func sectionDidChange(allowOpen: Bool = true) {
        snapshotDidChange()
        if !sectionState().isRevealed {
            close()
        } else if model.settings.notchOverflowEnabled, !isOpening, allowOpen {
            if isShown {
                if !items.isRefreshing { refresh() }
            } else {
                show()
            }
        }
    }

    func show() {
        guard model.settings.notchOverflowEnabled, hasNotchedDisplay else { return }
        guard isTrusted() else {
            disableForPermission()
            return
        }
        if let window {
            window.makeKey()
            return
        }
        guard let target = placement(anchor()) else {
            explanation = String(localized: "A notched display must have a menu bar and enough room beside the notch. Use the regular drop-down panel when that area isn’t available.")
            return
        }
        opener.cancel()
        isOpening = false
        targetScreenFrame = target.screenFrame
        let panel = NotchOverflowWindow()
        panel.onClose = { [weak self] in self?.close() }
        panel.onRefresh = { [weak self] in
            guard let self, self.model.settings.notchOverflowEnabled else { return }
            self.explanation = nil
            self.refresh()
        }
        panel.onOpen = { [weak self] in self?.open($0) }
        panel.setFrame(target.panelFrame, display: false)
        window = panel
        isShown = true
        onInteractionChange()
        rebuild()
        installDismissal()
        present(panel)
        if !items.isRefreshing { refresh() }
    }

    func close() {
        let wasInteracting = isInteracting
        opener.cancel()
        isOpening = false
        tearDownWindow()
        if wasInteracting { onInteractionChange() }
    }

    private func tearDownWindow() {
        window?.orderOut(nil)
        window = nil
        targetScreenFrame = nil
        isShown = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func disableForPermission() {
        close()
        if model.settings.notchOverflowEnabled { model.settings.notchOverflowEnabled = false }
        explanation = String(localized: "Notch overflow is off because Accessibility wasn’t allowed. Allow Barback in System Settings › Privacy & Security › Accessibility, then turn this on again. Screen Recording is never needed.")
        announce(explanation!)
    }

    private func snapshotDidChange() {
        let next = hasNotchedDisplay
            ? NotchOverflowContent.warning(
                results: NotchOverflowContent.fit(items: items, state: sectionState()),
                names: items.snapshotDisplayNames
            ) : nil
        if warning != next { warning = next }
        let status = fitStatus
        if lastFitStatus != status {
            lastFitStatus = status
            onWarningChange()
        }
        if let next, next != lastAnnouncedWarning {
            announce(next)
            lastAnnouncedWarning = next
        } else if !sectionState().isRevealed {
            lastAnnouncedWarning = nil
        }
        if isShown, !isTrusted() {
            disableForPermission()
            return
        }
        rebuild()
    }

    private func rebuild() {
        guard let window, let frame = targetScreenFrame else { return }
        let cgFrame = ScreenInfo.cgRect(fromAppKit: frame)
        let display = items.snapshotDisplays.firstIndex { $0.frame == cgFrame && $0.notch != nil }
        let fresh = !items.snapshotContextIsStale && items.scanError == nil && !items.isRefreshing
        let candidates = display.map {
            NotchOverflowContent.candidates(
                rows: items.rows, display: $0, alwaysHiddenEnabled: model.settings.alwaysHiddenEnabled
            )
        } ?? []
        let rows = items.rows.filter { $0.barbackRole == nil && $0.display == display }
        let unavailable = max(0, rows.filter {
            $0.section != .alwaysHidden || model.settings.alwaysHiddenEnabled
        }.count - candidates.count)
        let status: String
        if let explanation {
            status = explanation
        } else if items.isRefreshing {
            status = String(localized: "Refreshing this display’s items…")
        } else if let error = items.scanError {
            status = error
        } else if !fresh || display == nil {
            status = String(localized: "The menu bar changed. Refresh before opening an item.")
        } else if candidates.isEmpty {
            status = String(localized: "No safely identified items are available on this display. macOS may not expose items hidden by the notch. Open the app directly or try the regular drop-down panel.")
        } else {
            status = String(localized: "\(candidates.count) identified items. \(unavailable) unavailable or unidentified. App icons, not captured menu bar pixels.")
        }
        let name = display.flatMap { items.snapshotDisplayNames.indices.contains($0) ? items.snapshotDisplayNames[$0] : nil }
        window.update(
            items: candidates, title: name ?? String(localized: "Notch overflow"),
            status: status, canOpen: fresh && display != nil && items.accessibilityTrusted,
            refreshing: items.isRefreshing
        )
    }

    func open(_ item: DropDownPanelItem) {
        guard model.settings.notchOverflowEnabled, isShown, !items.isRefreshing,
              !items.snapshotContextIsStale, items.scanError == nil,
              ItemsModel.currentDisplays() == items.snapshotDisplays,
              let display = item.display,
              NotchOverflowContent.candidates(
                rows: items.rows, display: display, alwaysHiddenEnabled: model.settings.alwaysHiddenEnabled
              ).contains(where: { $0.id == item.id && $0.key == item.key }) else {
            explanation = String(localized: "This item’s identity or display changed. Refresh and try again.")
            rebuild()
            return
        }
        guard isTrusted() else {
            disableForPermission()
            return
        }
        // Mark the opening before the strip goes away, so `isInteracting` never drops (and the revealed section
        // never gets a rehide or hover exit) between dismissing the strip and pressing the item.
        opener.cancel()
        isOpening = true
        tearDownWindow()
        onInteractionChange()
        if let action = item.revealAction { reveal(action) }
        opener.open(key: item.key, display: display) { [weak self] result in
            guard let self else { return }
            self.isOpening = false
            self.onInteractionChange()
            if case .failure(let error) = result {
                self.explanation = String(localized: "\(item.title): \(error.localizedDescription) Open the app directly if macOS cannot expose its menu bar item.")
                self.announce(self.explanation!)
                // An uncertain press may already have opened a menu: never steal focus or retry it.
                if error == .permissionRequired { self.disableForPermission() }
            }
        }
    }

    private func installDismissal() {
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.window { self.close() }
            }
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let window = self?.window, event.window === window else { return false }
                return window.handlePagingKey(event)
            }
            return handled ? nil : event
        }) { monitors.append(monitor) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                guard pid != ProcessInfo.processInfo.processIdentifier else { return }
                MainActor.assumeIsolated { self?.close() }
            }))
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
