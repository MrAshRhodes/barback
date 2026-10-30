import AppKit
import BarbackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let loginItem = LoginItemController()
    private let itemsModel = ItemsModel()
    private let hotkey = GlobalHotkey()
    private let hover = HoverMonitor()
    private var statusBar: StatusBarController?
    private var settingsWindow: SettingsWindowController?
    /// URL commands that arrived before the status items existed.
    private var pendingURLCommands: [BarbackURLCommand] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = makeMainMenu()

        let statusBar = StatusBarController(model: model, items: itemsModel)
        statusBar.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBar.onOpenPanelSettings = { [weak self] in self?.openSettings(tab: .panel) }
        statusBar.onShowAbout = { [weak self] in self?.showAboutPanel() }
        self.statusBar = statusBar
        itemsModel.statusBar = statusBar

        hover.onEnterZone = { [weak self] in self?.statusBar?.revealFromHover() }
        hover.onExitMenuBar = { [weak self] in self?.statusBar?.hoverDidExit() }
        model.onSettingsChange = { [weak self] old, new in self?.settingsChanged(from: old, to: new) }
        model.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording { self.hotkey.unregister() } else { self.applyHotkey() }
        }

        applyHotkey()
        applyHover()
        Log.app.info("Barback \(self.model.version, privacy: .public) started")
        if CommandLine.arguments.contains("--settings") { showSettings() }
        let pending = pendingURLCommands
        pendingURLCommands = []
        pending.forEach(run)
        statusBar.showWelcomeTipIfFirstLaunch()
    }

    /// `barback://` URLs, e.g. `open -g barback://toggle` from Shortcuts, scripts or launchers.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = BarbackURLCommand.parse(url) else {
                Log.app.notice("Ignoring unsupported URL \(url.absoluteString, privacy: .public)")
                continue
            }
            if statusBar == nil { pendingURLCommands.append(command) } else { run(command) }
        }
    }

    private func run(_ command: BarbackURLCommand) {
        Log.app.info("URL command \(command.rawValue, privacy: .public)")
        if let action = command.sectionAction {
            statusBar?.perform(action, userInitiated: true, announce: true)
        } else {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Spotlight, Launchpad) shows Settings, since there's no Dock icon.
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        hover.stop()
    }

    // MARK: - Settings plumbing

    private func settingsChanged(from old: BarbackSettings, to new: BarbackSettings) {
        statusBar?.settingsDidChange(from: old, to: new)
        if old.hotkey != new.hotkey { applyHotkey() }
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
