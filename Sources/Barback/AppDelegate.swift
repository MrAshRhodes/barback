import AppKit
import BarbackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let loginItem = LoginItemController()
    private let itemsModel = ItemsModel()
    private let hotkey = GlobalHotkey()
    /// One registration per item shortcut.
    private var itemHotkeys: [ItemKey: GlobalHotkey] = [:]
    private lazy var launcher = ItemLauncher(items: itemsModel)
    private let hover = HoverMonitor()
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?
    /// URL requests that arrived before the status items existed.
    private var pendingURLRequests: [BarbackURLRequest] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        let statusBar = StatusBarController(model: model, items: itemsModel)
        statusBar.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBar.onOpenPanelSettings = { [weak self] in self?.openSettings(tab: .panel) }
        statusBar.onShowAbout = { [weak self] in self?.showAboutPanel() }
        self.statusBar = statusBar
        itemsModel.statusBar = statusBar
        launcher.reveal = { [weak statusBar] action in statusBar?.perform(action, userInitiated: true) }
        launcher.onOpeningChange = { [weak statusBar] in statusBar?.externalItemOpeningDidChange($0) }

        hover.onEnterZone = { [weak self] in self?.statusBar?.revealFromHover() }
        hover.onExitMenuBar = { [weak self] in self?.statusBar?.hoverDidExit() }
        model.onSettingsChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        model.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.hotkey.unregister()
                self.unregisterItemHotkeys()
            } else {
                self.applyHotkey()
                self.applyItemHotkeys()
            }
        }

        applyHotkey()
        applyItemHotkeys()
        applyHover()
        Log.app.info("Barback \(self.model.version, privacy: .public) started")
        if CommandLine.arguments.contains("--settings") { showSettings() }
        let pending = pendingURLRequests
        pendingURLRequests = []
        pending.forEach(run)
        statusBar.showWelcomeTipIfFirstLaunch()
    }

    /// `barback://` URLs, e.g. `open -g barback://toggle` or `open -g "barback://open?name=Wi-Fi"` from Shortcuts,
    /// scripts or launchers.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let request: BarbackURLRequest
            switch BarbackURLRequest.parse(url) {
            case .success(let parsed): request = parsed
            case .failure(let error):
                Log.app.notice("Ignoring URL \(url.absoluteString, privacy: .public): \(error.message, privacy: .public)")
                continue
            }
            if statusBar == nil { pendingURLRequests.append(request) } else { run(request) }
        }
    }

    private func run(_ request: BarbackURLRequest) {
        switch request {
        case .command(let command):
            Log.app.info("URL command \(command.rawValue, privacy: .public)")
            if let action = command.sectionAction {
                statusBar?.perform(action, userInitiated: true, announce: true)
            } else {
                showSettings()
            }
        case .open(let reference):
            launcher.open(reference, source: "URL")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Spotlight, Launchpad) shows Settings, since there's no Dock icon.
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        unregisterItemHotkeys()
        launcher.cancel()
        hover.stop()
    }

    // MARK: - Settings plumbing

    private func settingsChanged(from old: BarbackSettings, to new: BarbackSettings) {
        statusBar?.settingsDidChange(from: old, to: new)
        if old.hotkey != new.hotkey { applyHotkey() }
        if old.itemHotkeys != new.itemHotkeys { applyItemHotkeys() }
        if old.showOnHover != new.showOnHover { applyHover() }
    }

    private func applyHotkey() {
        hotkey.unregister()
        model.hotkeyError = nil
        guard !model.isRecordingHotkey, let combo = model.settings.hotkey else { return }
        do {
            try hotkey.register(combo) { [weak self] in
                // Follows the click action: the panel with the drop-down action, otherwise the toggle.
                self?.statusBar?.performPrimaryAction(announce: true)
            }
        } catch {
            model.hotkeyError = error.localizedDescription
        }
    }

    private func unregisterItemHotkeys() {
        itemHotkeys.values.forEach { $0.unregister() }
        itemHotkeys = [:]
    }

    /// Registers each item shortcut; an item that isn't in the menu bar when pressed is logged and skipped.
    private func applyItemHotkeys() {
        unregisterItemHotkeys()
        var errors: [ItemKey: String] = [:]
        defer { if model.itemHotkeyErrors != errors { model.itemHotkeyErrors = errors } }
        guard !model.isRecordingHotkey else { return }
        for item in model.settings.itemHotkeys {
            let registration = GlobalHotkey()
            do {
                try registration.register(item.combo) { [weak self] in
                    self?.launcher.open(.key(item.key), source: "Shortcut \(item.combo.displayString)")
                }
                itemHotkeys[item.key] = registration
            } catch {
                errors[item.key] = error.localizedDescription
            }
        }
    }

    private func applyHover() {
        if model.settings.showOnHover { hover.start() } else { hover.stop() }
    }

    // MARK: - Windows

    @objc func showSettings() {
        openSettings(tab: nil)
    }

    func openSettings(tab: SettingsWindowController.Tab?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model, loginItem: loginItem, items: itemsModel)
        }
        settingsWindow?.show(tab: tab)
    }

    @objc func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(
            string: String(localized: "A fast, lightweight way to tidy your menu bar.") + "\n",
            attributes: base
        )
        var link = base
        link[.link] = BarbackInfo.repositoryURL
        credits.append(NSAttributedString(string: "github.com/MrAshRhodes/barback", attributes: link))

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: BarbackInfo.name,
            .applicationVersion: model.version,
            .version: model.build ?? model.version,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): BarbackInfo.copyright,
        ])
    }

    /// Accessory apps still need a main menu so ⌘W, ⌘Q, ⌘, and Edit commands work in the Settings window.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: BarbackInfo.name)
        appMenu.addItem(withTitle: String(localized: "About Barback"), action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Barback"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Barback"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
