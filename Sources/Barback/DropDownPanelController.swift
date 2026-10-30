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
    /// Persisted once the user dismisses the "allow Accessibility" footer.
    static let accessibilityHintDismissedKey = "hasDismissedPanelAccessibilityHint"

    /// What the header and padding take; the rest of the screen's height goes to the scrolling boxes.
    private static let chromeHeight: CGFloat = 66
    private static let hintHeight: CGFloat = 110
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

    /// The button the panel hangs from.
    var anchor: () -> NSStatusBarButton? = { nil }
    /// Reveals items in the menu bar (`.show`, or `.showAll` for the always-hidden section).
    var reveal: (SectionAction) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onVisibilityChange: (Bool) -> Void = { _ in }

    var isShown: Bool { window != nil }

    init(model: AppModel, items: ItemsModel) {
        self.appModel = model
        self.items = items
        super.init()
        panelModel.onOpen = { [weak self] in self?.open($0) }
        panelModel.onMove = { [weak self] in self?.move($0, to: $1) }
        panelModel.onNewGroup = { [weak self] in self?.promptForNewGroup(for: $0) }
        panelModel.onSetLayout = { [weak self] in self?.appModel.settings.dropDownLayout = $0 }
        panelModel.onOpenSettings = { [weak self] in
            self?.close()
            self?.onOpenSettings()
        }
        panelModel.onAllowAccessibility = { [weak self] in self?.items.requestAccessibility() }
        panelModel.onDismissAccessibilityHint = { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.accessibilityHintDismissedKey)
            self?.rebuild()
            self?.scheduleFit()
        }
    }

    // MARK: - Showing

    /// Opens the panel, or closes it if it is open.
    func toggle() {
        if isShown { close() } else { show() }
    }

    func show() {
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
        let chrome = Self.chromeHeight + (panelModel.showsAccessibilityHint ? Self.hintHeight : 0)
        let limit = min(DropDownPanelView.defaultMaxContentHeight, max(Self.minContentHeight, room - chrome))
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
            .sink { [weak self] rows, refreshing, trusted, settings in
                self?.apply(rows: rows, isRefreshing: refreshing, trusted: trusted, settings: settings)
            }
            .store(in: &cancellables)
    }

    private func rebuild() {
        apply(rows: items.rows, isRefreshing: items.isRefreshing, trusted: items.accessibilityTrusted, settings: appModel.settings)
    }

    private func apply(rows: [MenuBarItemRow], isRefreshing: Bool, trusted: Bool, settings: BarbackSettings) {
        var hidden: [DropDownPanelItem] = []
        var alwaysHidden: [DropDownPanelItem] = []
        for row in rows {
            guard let box = DropDownContent.box(
                section: row.section,
                visibility: row.visibility,
                isBarbackItem: row.barbackRole != nil,
                alwaysHiddenEnabled: settings.alwaysHiddenEnabled
            ) else { continue }
            let item = DropDownPanelItem(
                id: row.id,
                key: row.key,
                title: row.panelTitle,
                icon: ItemIcons.image(for: row.item),
                fallbackSymbol: ItemIcons.symbol(for: row.item),
                display: row.display,
                box: box
            )
            if box == .alwaysHidden { alwaysHidden.append(item) } else { hidden.append(item) }
        }
        panelModel.boxes = DropDownPanelBox.make(hidden: hidden, alwaysHidden: alwaysHidden, groups: settings.groups)
        panelModel.layout = settings.dropDownLayout
        panelModel.groups = settings.groups
        panelModel.canAddGroup = settings.groups.count < ItemGroups.maxGroups
        panelModel.isLoading = isRefreshing
        panelModel.showsAccessibilityHint = !trusted && !UserDefaults.standard.bool(forKey: Self.accessibilityHintDismissedKey)
    }

    // MARK: - Actions

    /// Reveals the item's section and, with Accessibility, presses the item so its own menu opens. Without it the
    /// items are simply revealed in the menu bar.
    private func open(_ item: DropDownPanelItem) {
        close()
        let trusted = AXIsProcessTrusted()
        reveal(DropDownContent.revealAction(for: item.box))
        guard trusted else { return }
        opener.open(key: item.key, display: item.display)
    }

    private func move(_ item: DropDownPanelItem, to groupID: UUID?) {
        var groups = appModel.settings.groups
        guard ItemGroups.assign(item.key, to: groupID, in: &groups) else { return }
        appModel.settings.groups = groups
    }

    private func promptForNewGroup(for item: DropDownPanelItem) {
        close(animated: false)
        // Let the context menu finish closing before a modal alert takes over.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "New Group")
            alert.informativeText = String(localized: "Name the group for “\(item.title)”. You can change its name and symbol in Settings › Panel.")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = String(localized: "Group name")
            field.setAccessibilityLabel(String(localized: "Group name"))
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Create"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                var groups = self.appModel.settings.groups
                if let id = ItemGroups.add(name: field.stringValue, to: &groups) {
                    ItemGroups.assign(item.key, to: id, in: &groups)
                    self.appModel.settings.groups = groups
                }
            }
            self.show()
        }
    }
}
