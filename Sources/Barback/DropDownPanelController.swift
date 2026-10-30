import AppKit
import BarbackCore
import Combine
import SwiftUI

/// Shows the drop-down panel under the Barback icon and carries out what is chosen in it.
///
/// The panel is a borderless window, not a popover: its right edge lines up with the icon's right edge and its top
/// hangs just below the menu bar on the icon's own screen (see `DropDownPlacement`). While it is open, clicks
/// elsewhere, Esc, a Space or app switch and display changes close it; the monitors and observers that watch for
/// those exist only for as long as it is open.
@MainActor
final class DropDownPanelController: NSObject {
    /// What the header and padding take; the rest of the screen's height goes to the scrolling boxes.
    private static let chromeHeight: CGFloat = 78
    private static let minContentHeight: CGFloat = 120

    private let appModel: AppModel
    private let items: ItemsModel
    private let panelModel = DropDownPanelModel()
    private let opener = ItemOpener()
    private var window: DropDownPanelWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitors: [Any] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var lastFrame: NSRect?
    private var fitPending = false
    private var isOpeningItem = false {
        didSet {
            if oldValue != isOpeningItem { onOpeningChange(isOpeningItem) }
        }
    }

    /// The button the panel hangs from.
    var anchor: () -> NSStatusBarButton? = { nil }
    /// Reveals items in the menu bar (`.show`, or `.showAll` for the always-hidden section).
    var reveal: (SectionAction) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onVisibilityChange: (Bool) -> Void = { _ in }
    var onOpeningChange: (Bool) -> Void = { _ in }

    var isShown: Bool { window != nil }

    init(model: AppModel, items: ItemsModel) {
        self.appModel = model
        self.items = items
        super.init()
        panelModel.onOpen = { [weak self] in self?.open($0) }
        panelModel.onOpenSettings = { [weak self] in
            self?.close()
            self?.onOpenSettings()
        }
        panelModel.onEditPanel = { [weak self] id in
            self?.appModel.selectedPanelID = id
            self?.close()
            self?.onOpenSettings()
        }
        panelModel.onAllowAccessibility = { [weak self] in self?.items.requestAccessibility() }
        panelModel.onRefresh = { [weak self] in
            self?.panelModel.errorMessage = nil
            self?.items.refresh()
        }
        panelModel.onReveal = { [weak self] in
            guard let self else { return }
            let needsAlwaysHidden = self.panelModel.boxes.flatMap(\.items).contains { $0.revealAction == .showAll }
                || (self.appModel.settings.alwaysHiddenEnabled
                    && self.panelModel.boxes.contains { $0.unavailableCount > 0 })
            self.close()
            self.reveal(needsAlwaysHidden ? .showAll : .show)
        }
    }

    // MARK: - Showing

    /// Opens the panel, or closes it if it is open.
    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
        opener.cancel()
        isOpeningItem = false
        guard window == nil, let button = anchor(), let buttonWindow = button.window, buttonWindow.screen != nil else { return }
        // Refresh only now; the panel never scans in the background.
        items.refresh()
        startObserving()
        panelModel.chrome = DropDownPanelChrome.current()
        rebuild()
        updateContentLimit()

        let panel = DropDownPanelWindow(
            model: panelModel,
            chrome: panelModel.chrome,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        panel.onCancel = { [weak self] in self?.close() }
        panel.onContentSizeChange = { [weak self] in self?.scheduleFit() }
        guard let frame = targetFrame(for: panel) else {
            cancellables.removeAll()
            return
        }
        window = panel
        lastFrame = frame
        installDismissal()
        panel.present(at: frame, animated: true)
        onVisibilityChange(true)
    }

    func close(animated: Bool = true) {
        opener.cancel()
        isOpeningItem = false
        guard let panel = window else { return }
        window = nil
        lastFrame = nil
        removeDismissal()
        cancellables.removeAll()
        panel.onCancel = {}
        panel.onContentSizeChange = {}
        panel.dismiss(animated: animated) {}
        onVisibilityChange(false)
    }

    // MARK: - Placement

    /// Follows the content when it grows or shrinks (a scan finishing, the layout changing), keeping the panel
    /// under the icon.
    private func scheduleFit() {
        guard window != nil, !fitPending else { return }
        fitPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitPending = false
            guard let panel = self.window else { return }
            self.updateContentLimit()
            guard let frame = self.targetFrame(for: panel) else {
                self.close()
                return
            }
            // Resizing makes the content report its size again; only a real change needs acting on.
            guard frame != self.lastFrame else { return }
            self.lastFrame = frame
            panel.resize(to: frame)
        }
    }

    /// Lets the boxes scroll sooner on a screen too short for the panel at full height.
    private func updateContentLimit() {
        guard let region = anchorRegion() else { return }
        let room = DropDownPlacement.maxHeight(anchor: region.anchor, visible: region.visible)
        let limit = min(DropDownPanelView.defaultMaxContentHeight, max(Self.minContentHeight, room - Self.chromeHeight))
        if abs(panelModel.maxContentHeight - limit) > 0.5 { panelModel.maxContentHeight = limit }
    }

    private func targetFrame(for panel: DropDownPanelWindow) -> NSRect? {
        guard let region = anchorRegion() else { return nil }
        return DropDownPlacement.frame(size: panel.contentFittingSize, anchor: region.anchor, visible: region.visible)
    }

    /// The icon's frame and the usable area of the screen it is on.
    private func anchorRegion() -> (anchor: NSRect, visible: NSRect)? {
        guard let window = anchor()?.window, let screen = window.screen else { return nil }
        return (window.frame, screen.visibleFrame)
    }

    // MARK: - Dismissal

    private func installDismissal() {
        removeDismissal()
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.localMouseDown(event) }
            return event
        }) {
            eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }) {
            eventMonitors.append(monitor)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }))
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            // Barback itself being activated (by an alert, say) is not a reason to close.
            if pid != ProcessInfo.processInfo.processIdentifier {
                MainActor.assumeIsolated { self?.close() }
            }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }))
        observers.append((center, center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.items.refreshAccessibilityStatus() }
        }))
    }

    private func removeDismissal() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }

    /// A click in one of Barback's own windows. Clicks in the panel stay; a plain click on the icon is left for
    /// `toggle()`, so the same click doesn't close the panel here and open it again there.
    private func localMouseDown(_ event: NSEvent) {
        guard let panel = window, event.window !== panel else { return }
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
           let iconWindow = anchor()?.window, event.window === iconWindow {
            return
        }
        close()
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let panel = window, event.window === panel, event.keyCode == 53 else { return false }
        close()
        return true
    }

    // MARK: - Content

    private func startObserving() {
        cancellables.removeAll()
        Publishers.CombineLatest4(items.$rows, items.$isRefreshing, items.$accessibilityTrusted, appModel.$settings)
            // Published emits before its storage changes; read derived candidates on the next main turn.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown else { return }
                self.rebuild()
                self.scheduleFit()
            }
            .store(in: &cancellables)
    }

    private func rebuild() {
        let settings = appModel.settings
        let candidates = items.panelCandidates
            .filter { $0.section != .alwaysHidden || settings.alwaysHiddenEnabled }
            .map(DropDownPanelItem.init)
        panelModel.boxes = DropDownPanelBox.make(
            items: candidates, groups: settings.groups, defaultLayout: settings.dropDownLayout
        )
        panelModel.isLoading = items.isRefreshing
        panelModel.canOpenItems = items.accessibilityTrusted
        panelModel.unidentifiedItemCount = items.unidentifiedPanelItemCount
    }

    // MARK: - Actions

    private func open(_ item: DropDownPanelItem) {
        guard AXIsProcessTrusted() else {
            items.refreshAccessibilityStatus()
            panelModel.canOpenItems = false
            panelModel.errorMessage = String(localized: "Allow Accessibility before opening an item, or choose Show in Menu Bar.")
            scheduleFit()
            return
        }
        panelModel.errorMessage = nil
        close()
        if let action = item.revealAction { reveal(action) }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Revealing synchronously closes the panel again; start the pending state only after that returns.
        isOpeningItem = true
        opener.open(key: item.key, display: item.display) { [weak self] result in
            guard let self else { return }
            self.isOpeningItem = false
            if case .failure(let error) = result {
                self.panelModel.errorMessage = String(localized: "\(item.title): \(error.localizedDescription)")
                // Don't steal focus if the user switched apps while the item was being found.
                if error != .uncertain, NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground {
                    self.show()
                }
            }
        }
    }
}
