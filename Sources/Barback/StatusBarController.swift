import AppKit
import BarbackCore

/// Owns Barback's status items and implements the separator-expansion hiding mechanism.
///
/// Left to right in the menu bar: `[always-hidden items] ┊ [hidden items] │ [visible items] ‹chevron›`.
/// Hiding sets a separator's length to `SectionLayout.expandedLength`, pushing everything left of it off-screen.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private enum AutosaveName {
        static let chevron = "barback.chevron"
        static let hidden = "barback.hiddenSeparator"
        static let alwaysHidden = "barback.alwaysHiddenSeparator"
        static func divider(_ index: Int) -> String { "barback.divider.\(index)" }
    }

    /// Set once the welcome tip has been shown, so it appears only on first launch.
    private static let welcomeTipShownKey = "hasShownWelcomeTip"

    private let model: AppModel
    private let chevron: NSStatusItem
    private let hiddenSeparator: NSStatusItem
    private var alwaysHiddenSeparator: NSStatusItem?
    /// Optional decorative dividers the user can ⌘-drag anywhere (not used for hiding).
    private var extraDividers: [NSStatusItem] = []
    private let menu = NSMenu()

    private(set) var state: SectionState = .shown
    private var validation: LayoutValidation = .unknown
    private var rehideTimer: Timer?
    private var menuIsOpen = false
    /// True while the current reveal came from hovering, so leaving the menu bar hides the items again.
    private var revealedByHover = false
    /// Pending hover exit that was deferred because a menu was open.
    private var hoverExitRetry: Timer?
    private var observers: [NSObjectProtocol] = []
    private var appSwitchObserver: NSObjectProtocol?
    /// True once the user (click, hotkey, URL) has acted, so the delayed launch-time hide doesn't undo it.
    private var userActed = false
    private var welcomePopover: NSPopover?
    private let panel: DropDownPanelController

    var onOpenSettings: (() -> Void)?
    var onOpenPanelSettings: (() -> Void)?
    var onShowAbout: (() -> Void)?

    init(model: AppModel, items: ItemsModel) {
        self.model = model
        panel = DropDownPanelController(model: model, items: items)
        Self.seedPositionIfNeeded(AutosaveName.chevron, relativeTo: nil)
        Self.seedPositionIfNeeded(AutosaveName.hidden, relativeTo: AutosaveName.chevron)

        // Created right-to-left: the chevron first so new items land to its left.
        chevron = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        chevron.autosaveName = AutosaveName.chevron
        chevron.isVisible = true
        hiddenSeparator = NSStatusBar.system.statusItem(withLength: SectionLayout.separatorLength)
        hiddenSeparator.autosaveName = AutosaveName.hidden
        hiddenSeparator.isVisible = true
        super.init()

        panel.anchor = { [weak self] in self?.chevron.button }
        panel.reveal = { [weak self] action in self?.perform(action, userInitiated: true) }
        panel.onOpenSettings = { [weak self] in self?.onOpenPanelSettings?() }
        panel.onVisibilityChange = { [weak self] _ in self?.updateChevronAppearance() }

        configure(chevron.button)
        configureSeparator(hiddenSeparator, alwaysHidden: false)
        if model.settings.alwaysHiddenEnabled { createAlwaysHiddenSeparator() }
        syncExtraDividers()

        menu.delegate = self
        menu.autoenablesItems = false
        apply()
        observeEnvironment()
        updateAppSwitchObserver()

        // Hide once the items have been laid out, so the order check sees real frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.userActed else { return }
            self.perform(.hide, userInitiated: false)
        }
    }

    // MARK: - Public API

    /// - Parameter announce: post a VoiceOver announcement of the result (for actions without visible focus,
    ///   such as the hotkey and URL commands).
    func perform(_ action: SectionAction, userInitiated: Bool, announce: Bool = false) {
        let signpost = Log.signposter.beginInterval("Toggle", id: Log.signposter.makeSignpostID())
        defer {
            Log.signposter.endInterval("Toggle", signpost)
            if announce { announceState() }
        }
        if userInitiated { userActed = true }
        revealedByHover = false
        cancelHoverExitRetry()
        let next = SectionLayout.nextState(from: state, action: action, alwaysHiddenEnabled: model.settings.alwaysHiddenEnabled)
        revalidate()
        if next == .hidden, !validation.canHideHiddenSection {
            Log.statusBar.notice("Not hiding: separator order is \(String(describing: self.validation), privacy: .public)")
            if state == .hidden { state = .shown }
            cancelRehide()
            apply()
            if userInitiated, validation == .hiddenSeparatorMisplaced { presentMisorderAlert() }
            return
        }
        state = next
        apply()
        if state.isRevealed {
            // Everything the panel lists is on show now.
            panel.close()
            scheduleRehide()
        } else {
            cancelRehide()
        }
        Log.statusBar.debug("State → \(self.state.rawValue, privacy: .public)")
    }

    /// What a plain click on the icon does, and the global hotkey with it: reveal the items in the menu bar, or with the
    /// drop-down click action open the panel (a click while the items are revealed hides them again).
    func performPrimaryAction(announce: Bool = false) {
        guard model.settings.clickAction == .dropDown, !state.isRevealed else {
            panel.close()
            perform(.toggle, userInitiated: true, announce: announce)
            return
        }
        userActed = true
        revealedByHover = false
        cancelHoverExitRetry()
        panel.toggle()
        if announce {
            post(panel.isShown ? String(localized: "Hidden items panel opened") : String(localized: "Hidden items panel closed"))
        }
    }

    /// Opens the panel from the menu, whatever the click action.
    func showDropDownPanel() {
        userActed = true
        if !panel.isShown { panel.show() }
    }

    private func announceState() {
        let message: String
        switch state {
        case .hidden: message = String(localized: "Menu bar items hidden")
        case .shown: message = String(localized: "Hidden menu bar items shown")
        case .shownAll: message = String(localized: "All menu bar items shown")
        }
        post(message)
    }

    private func post(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// Called when settings change.
    func settingsDidChange(from old: BarbackSettings, to new: BarbackSettings) {
        if old.appearance != new.appearance {
            refreshImages()
            syncExtraDividers()
            apply()
        }
        if old.rehideOnAppSwitch != new.rehideOnAppSwitch { updateAppSwitchObserver() }
        if old.alwaysHiddenEnabled != new.alwaysHiddenEnabled {
            if new.alwaysHiddenEnabled {
                createAlwaysHiddenSeparator()
            } else {
                removeAlwaysHiddenSeparator()
                if state == .shownAll { state = .shown }
            }
            apply()
            // Re-check order after the new item has been laid out.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.revalidate()
                self.apply()
            }
        }
        if old.autoRehideSeconds != new.autoRehideSeconds {
            if state.isRevealed { scheduleRehide() } else { cancelRehide() }
        }
        if old.hotkey != new.hotkey { rebuildMenu() }
        if old.clickAction != new.clickAction {
            panel.close()
            updateChevronAppearance()
            rebuildMenu()
        }
    }

    /// Hover-to-show entry point.
    func revealFromHover() {
        guard state == .hidden else {
            if state.isRevealed { scheduleRehide() }
            return
        }
        perform(.show, userInitiated: false)
        revealedByHover = state == .shown
    }

    /// Hover-to-show exit: hide hover-revealed items once the pointer has left the menu bar.
    /// If a menu is open the exit stays pending and is retried (one-shot) and again when Barback's menu closes.
    func hoverDidExit() {
        cancelHoverExitRetry()
        guard revealedByHover else { return }
        let decision = HoverPolicy.exitDecision(
            state: state,
            revealedByHover: revealedByHover,
            mouseInMenuBar: ScreenInfo.isMouseInMenuBar(),
            menuOpen: menuIsOpen || model.isRecordingHotkey || ScreenInfo.isAnyMenuOpen()
        )
        switch decision {
        case .none: break
        case .hide: perform(.hide, userInitiated: false)
        case .retry(let seconds): scheduleHoverExitRetry(after: seconds)
        }
    }

    private func scheduleHoverExitRetry(after seconds: TimeInterval) {
        cancelHoverExitRetry()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hoverExitRetry = nil
                self?.hoverDidExit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverExitRetry = timer
    }

    private func cancelHoverExitRetry() {
        hoverExitRetry?.invalidate()
        hoverExitRetry = nil
    }

    /// Frames (CoreGraphics coordinates) of Barback's own items, for the Items tab.
    struct OwnItems {
        var chevron: CGRect?
        var hiddenSeparator: CGRect?
        var alwaysHiddenSeparator: CGRect?
        var dividers: [CGRect] = []
    }

    var ownItems: OwnItems {
        OwnItems(
            chevron: Self.frame(of: chevron).map(ScreenInfo.cgRect(fromAppKit:)),
            hiddenSeparator: Self.frame(of: hiddenSeparator).map(ScreenInfo.cgRect(fromAppKit:)),
            alwaysHiddenSeparator: alwaysHiddenSeparator.flatMap(Self.frame(of:)).map(ScreenInfo.cgRect(fromAppKit:)),
            dividers: extraDividers.compactMap(Self.frame(of:)).map(ScreenInfo.cgRect(fromAppKit:))
        )
    }

    // MARK: - Rehide on app switch

    private func updateAppSwitchObserver() {
        let center = NSWorkspace.shared.notificationCenter
        if model.settings.rehideOnAppSwitch {
            guard appSwitchObserver == nil else { return }
            appSwitchObserver = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { self?.appDidActivate(pid: pid) }
            }
        } else if let observer = appSwitchObserver {
            center.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    private func appDidActivate(pid: pid_t?) {
        guard state.isRevealed else { return }
        let rehide = RehidePolicy.shouldRehideOnAppSwitch(
            enabled: model.settings.rehideOnAppSwitch,
            state: state,
            activatedBarback: pid == ProcessInfo.processInfo.processIdentifier,
            // Clicking a revealed item can activate its app; the pointer is still in the menu bar then.
            mouseInMenuBar: ScreenInfo.isMouseInMenuBar(),
            menuOpen: menuIsOpen || model.isRecordingHotkey || ScreenInfo.isAnyMenuOpen()
        )
        if rehide { perform(.hide, userInitiated: false) }
    }

    // MARK: - Layout

    private func revalidate() {
        let v = SectionLayout.validate(
            chevron: Self.frame(of: chevron),
            hiddenSeparator: Self.frame(of: hiddenSeparator),
            alwaysHiddenSeparator: alwaysHiddenSeparator.flatMap(Self.frame(of:))
        )
        validation = v
        switch v {
        case .valid, .unknown:
            model.layoutWarning = nil
        case .hiddenSeparatorMisplaced:
            model.layoutWarning = String(localized: "The │ separator is to the right of Barback. Hold ⌘ and drag it to the left of the chevron.")
        case .alwaysHiddenSeparatorMisplaced:
            model.layoutWarning = String(localized: "The ┊ always-hidden separator is to the right of the │ separator. Hold ⌘ and drag it further left.")
        }
    }

    private func apply() {
        let appearance = model.settings.appearance
        let lengths = SectionLayout.lengths(
            for: state,
            validation: validation,
            alwaysHiddenEnabled: model.settings.alwaysHiddenEnabled,
            collapsed: SeparatorLengths(
                hidden: appearance.hiddenDivider.collapsedLength,
                alwaysHidden: appearance.alwaysHiddenDivider.collapsedLength
            )
        )
        if hiddenSeparator.length != lengths.hidden { hiddenSeparator.length = lengths.hidden }
        if let a = alwaysHiddenSeparator, a.length != lengths.alwaysHidden { a.length = lengths.alwaysHidden }
        updateChevronAppearance()
    }

    private static func frame(of item: NSStatusItem) -> CGRect? {
        guard let window = item.button?.window else { return nil }
        let f = window.frame
        return f.width > 0 ? f : nil
    }

    // MARK: - Auto-rehide (one-shot timer only)

    private func scheduleRehide(after interval: TimeInterval? = nil) {
        cancelRehide()
        guard let delay = interval ?? RehidePolicy.initialDelay(autoRehideSeconds: model.settings.autoRehideSeconds) else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehideTimerFired() }
        }
        timer.tolerance = min(1, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        rehideTimer = timer
    }

    private func cancelRehide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    private func rehideTimerFired() {
        rehideTimer = nil
        let context = RehideContext(
            state: state,
            autoRehideSeconds: model.settings.autoRehideSeconds,
            mouseInMenuBar: ScreenInfo.isMouseInMenuBar(),
            menuOpen: menuIsOpen || model.isRecordingHotkey || ScreenInfo.isAnyMenuOpen()
        )
        switch RehidePolicy.decide(context) {
        case .none: break
        case .rehideNow: perform(.hide, userInitiated: false)
        case .postpone(let seconds): scheduleRehide(after: seconds)
        }
    }

    // MARK: - Status item setup

    private func configure(_ button: NSStatusBarButton?) {
        guard let button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
    }

    private func configureSeparator(_ item: NSStatusItem, alwaysHidden: Bool) {
        configure(item.button)
        guard let button = item.button else { return }
        let appearance = model.settings.appearance
        button.image = StatusIcons.dividerImage(
            style: alwaysHidden ? appearance.alwaysHiddenDivider : appearance.hiddenDivider,
            label: alwaysHidden
                ? String(localized: "Always-hidden section separator")
                : String(localized: "Hidden section separator")
        )
        button.appearsDisabled = false
        if alwaysHidden {
            button.setAccessibilityLabel(String(localized: "Always-hidden section separator"))
            button.toolTip = String(localized: "Hold ⌘ and drag icons to the left of ┊ to keep them always hidden. Option-click Barback to reveal them.")
        } else {
            button.setAccessibilityLabel(String(localized: "Hidden section separator"))
            button.toolTip = String(localized: "Hold ⌘ and drag icons to the left of │ to hide them.")
        }
        button.setAccessibilityHelp(button.toolTip)
    }

    private func updateChevronAppearance() {
        guard let button = chevron.button else { return }
        let revealed = state.isRevealed
        let usesPanel = model.settings.clickAction == .dropDown
        let panelOpen = usesPanel && panel.isShown
        let label: String
        if revealed {
            label = String(localized: "Hide menu bar items")
        } else if usesPanel {
            label = panelOpen ? String(localized: "Close hidden items panel") : String(localized: "Open hidden items panel")
        } else {
            label = String(localized: "Show hidden menu bar items")
        }
        let appearance = model.settings.appearance
        var image: NSImage?
        if usesPanel, !revealed {
            image = StatusIcons.dropDownImage(style: appearance.toggleIcon, weight: appearance.iconWeight, panelOpen: panelOpen, label: label)
        }
        button.image = image ?? StatusIcons.toggleImage(style: appearance.toggleIcon, weight: appearance.iconWeight, revealed: revealed, label: label)
        // Colour is a secondary cue; the glyph itself always changes with the state too.
        let tint: NSColor? = appearance.tintWhenShowing && (revealed || panelOpen) ? .controlAccentColor : nil
        if button.contentTintColor != tint { button.contentTintColor = tint }
        button.setAccessibilityLabel(label)
        var help = usesPanel
            ? String(localized: "Click to see hidden items in a panel. Option-click to show every item in the menu bar, including always-hidden ones. Right-click for options.")
            : String(localized: "Click to show or hide menu bar items. Option-click to include always-hidden items. Right-click for options.")
        if let warning = model.layoutWarning { help = warning + "\n" + help }
        button.toolTip = help
        button.setAccessibilityHelp(help)
    }

    private func refreshImages() {
        configureSeparator(hiddenSeparator, alwaysHidden: false)
        if let item = alwaysHiddenSeparator { configureSeparator(item, alwaysHidden: true) }
        for item in extraDividers { configureDivider(item) }
        updateChevronAppearance()
    }

    private func createAlwaysHiddenSeparator() {
        guard alwaysHiddenSeparator == nil else { return }
        Self.seedPositionIfNeeded(AutosaveName.alwaysHidden, relativeTo: AutosaveName.hidden)
        let item = NSStatusBar.system.statusItem(withLength: SectionLayout.separatorLength)
        item.autosaveName = AutosaveName.alwaysHidden
        item.isVisible = true
        configureSeparator(item, alwaysHidden: true)
        alwaysHiddenSeparator = item
    }

    private func removeAlwaysHiddenSeparator() {
        guard let item = alwaysHiddenSeparator else { return }
        Self.removeKeepingPosition(item, autosaveName: AutosaveName.alwaysHidden)
        alwaysHiddenSeparator = nil
    }

    /// removeStatusItem forgets the saved position; keep it so re-adding the item restores the user's layout.
    /// Callers must drop their reference to `item` right away.
    private static func removeKeepingPosition(_ item: NSStatusItem, autosaveName: String) {
        let key = positionKey(autosaveName)
        let saved = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.doubleValue
        NSStatusBar.system.removeStatusItem(item)
        guard let saved else { return }
        UserDefaults.standard.set(saved, forKey: key)
        // AppKit clears the key again when the item is deallocated, so restore it once more afterwards.
        DispatchQueue.main.async { UserDefaults.standard.set(saved, forKey: key) }
    }

    // MARK: - Extra dividers

    /// Adds or removes decorative dividers to match the setting. They never take part in hiding.
    private func syncExtraDividers() {
        let wanted = model.settings.appearance.extraDividerCount
        while extraDividers.count > wanted {
            let item = extraDividers.removeLast()
            Self.removeKeepingPosition(item, autosaveName: AutosaveName.divider(extraDividers.count))
        }
        while extraDividers.count < wanted {
            let index = extraDividers.count
            let name = AutosaveName.divider(index)
            // New dividers appear just left of the chevron, where they are easy to find and ⌘-drag.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.positionKey(name)) == nil {
                let chevronPosition = (defaults.object(forKey: Self.positionKey(AutosaveName.chevron)) as? NSNumber)?.doubleValue ?? 0
                defaults.set(chevronPosition + 0.5 + Double(index) * 0.1, forKey: Self.positionKey(name))
            }
            let item = NSStatusBar.system.statusItem(withLength: model.settings.appearance.extraDividerStyle.collapsedLength)
            item.autosaveName = name
            item.isVisible = true
            configureDivider(item)
            extraDividers.append(item)
        }
    }

    private func configureDivider(_ item: NSStatusItem) {
        configure(item.button)
        let style = model.settings.appearance.extraDividerStyle
        if item.length != style.collapsedLength { item.length = style.collapsedLength }
        guard let button = item.button else { return }
        let label = String(localized: "Divider")
        button.image = StatusIcons.dividerImage(style: style, label: label)
        button.setAccessibilityLabel(label)
        button.toolTip = String(localized: "A divider for grouping menu bar items. Hold ⌘ and drag it anywhere.")
        button.setAccessibilityHelp(button.toolTip)
    }

    private static func positionKey(_ autosaveName: String) -> String { "NSStatusItem Preferred Position \(autosaveName)" }

    /// First run: place separators immediately left of the chevron (positions count from the right edge).
    private static func seedPositionIfNeeded(_ name: String, relativeTo neighbour: String?) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: positionKey(name)) == nil else { return }
        var position: Double = 0
        if let neighbour {
            position = (defaults.object(forKey: positionKey(neighbour)) as? NSNumber)?.doubleValue ?? 0
            position += 1
        }
        defaults.set(position, forKey: positionKey(name))
    }

    // MARK: - Events

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu(from: sender)
            return
        }
        // Barback's own separators and dividers share this action; only the icon opens the panel.
        if sender === chevron.button, !flags.contains(.option) {
            performPrimaryAction()
        } else {
            perform(flags.contains(.option) ? .toggleAll : .toggle, userInitiated: true)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let item = ([chevron, hiddenSeparator, alwaysHiddenSeparator].compactMap { $0 } + extraDividers)
            .first { $0.button === button } ?? chevron
        rebuildMenu()
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revalidateAfterMove() }
        })
        // Fires when the user ⌘-drags one of our items (their windows move).
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                let ours = [self.chevron, self.hiddenSeparator, self.alwaysHiddenSeparator].compactMap { $0?.button?.window }
                if ours.contains(where: { $0 === window }) { self.revalidateAfterMove() }
            }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshImages() }
        })
    }

    private func revalidateAfterMove() {
        let before = validation
        revalidate()
        if before != validation {
            Log.statusBar.info("Layout validation → \(String(describing: self.validation), privacy: .public)")
            apply()
        } else {
            updateChevronAppearance()
        }
    }

    private func presentMisorderAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Move the Separator Left of Barback")
        alert.informativeText = String(localized: "Barback can’t hide items while the │ separator is to the right of its chevron, because that would hide Barback too.\n\nHold ⌘ and drag the │ separator so it sits immediately to the left of the chevron, then click the chevron again.")
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - Welcome tip

    /// Shows the getting-started popover once, shortly after the first launch.
    func showWelcomeTipIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.welcomeTipShownKey) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.chevron.button?.window != nil else { return }
            UserDefaults.standard.set(true, forKey: Self.welcomeTipShownKey)
            self.showWelcomeTip()
        }
    }

    func showWelcomeTip() {
        guard let button = chevron.button else { return }
        welcomePopover?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = WelcomeTip.makeController(
            hotkey: model.settings.hotkey,
            onDone: { [weak popover] in popover?.performClose(nil) }
        )
        welcomePopover = popover
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Menu (HIG: About, actions, Settings…, Quit)

    private func rebuildMenu() {
        menu.removeAllItems()

        let about = NSMenuItem(title: String(localized: "About Barback"), action: #selector(aboutClicked), keyEquivalent: "")
        about.target = self
        setSymbol(about, "info.circle")
        menu.addItem(about)
        let tip = NSMenuItem(title: String(localized: "Getting Started"), action: #selector(gettingStartedClicked), keyEquivalent: "")
        tip.target = self
        setSymbol(tip, "questionmark.circle")
        menu.addItem(tip)
        menu.addItem(.separator())

        let revealed = state.isRevealed
        let toggle = NSMenuItem(
            title: revealed ? String(localized: "Hide Items") : String(localized: "Show Hidden Items"),
            action: #selector(toggleClicked), keyEquivalent: ""
        )
        toggle.target = self
        let panelEntry = NSMenuItem(title: String(localized: "Open Drop-Down Panel"), action: #selector(panelClicked), keyEquivalent: "")
        panelEntry.target = self
        // The hotkey does what a click does, so the shortcut is listed on that entry.
        let hotkeyEntry = model.settings.clickAction == .dropDown && !revealed ? panelEntry : toggle
        if let combo = model.settings.hotkey, let key = combo.menuKeyEquivalent {
            // Shown for reference; the global hotkey does the real work.
            hotkeyEntry.keyEquivalent = key
            hotkeyEntry.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: combo.modifiers.cocoaFlags)
        }
        setSymbol(toggle, revealed ? "eye.slash" : "eye")
        setSymbol(panelEntry, "chevron.down.square")
        menu.addItem(toggle)
        menu.addItem(panelEntry)

        let showAll = NSMenuItem(title: String(localized: "Show Always-Hidden Items"), action: #selector(showAllClicked), keyEquivalent: "")
        showAll.target = self
        showAll.isEnabled = model.settings.alwaysHiddenEnabled
        showAll.state = state == .shownAll ? .on : .off
        if !model.settings.alwaysHiddenEnabled {
            showAll.toolTip = String(localized: "Turn on the always-hidden section in Settings to use this.")
        }
        menu.addItem(showAll)

        if let warning = model.layoutWarning {
            let item = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: String(localized: "Warning"))
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(settingsClicked), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = self
        setSymbol(settings, "gearshape")
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Barback"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    /// macOS 26 menus show leading SF Symbols; earlier releases stay text-only per their HIG.
    private func setSymbol(_ item: NSMenuItem, _ name: String) {
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
    }

    @objc private func aboutClicked() { onShowAbout?() }
    @objc private func gettingStartedClicked() {
        // Wait for the menu to finish closing so the popover can anchor to the chevron.
        DispatchQueue.main.async { [weak self] in self?.showWelcomeTip() }
    }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func toggleClicked() { perform(.toggle, userInitiated: true) }
    @objc private func panelClicked() {
        // Wait for the menu to finish closing so the panel can anchor to the chevron.
        DispatchQueue.main.async { [weak self] in self?.showDropDownPanel() }
    }
    @objc private func showAllClicked() {
        perform(state == .shownAll ? .hide : .showAll, userInitiated: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if hoverExitRetry != nil { scheduleHoverExitRetry(after: HoverPolicy.menuCloseRetryDelay) }
    }
}
