import AppKit
import SwiftUI

/// Single-instance Settings window with standard toolbar tabs (General, Appearance, Items, Panel, About).
/// The window title follows the selected tab, as in System Settings-era macOS apps.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int {
        case general, appearance, items, panel, about
    }

    private let tabs = NSTabViewController()
    private let loginItem: LoginItemController
    private let itemsModel: ItemsModel

    init(model: AppModel, loginItem: LoginItemController, items: ItemsModel) {
        self.loginItem = loginItem
        self.itemsModel = items

        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        tabs.addTabViewItem(Self.tab(
            String(localized: "General"), symbol: "gearshape",
            GeneralSettingsView(model: model, loginItem: loginItem)
        ))
        tabs.addTabViewItem(Self.tab(
            String(localized: "Appearance"), symbol: "paintbrush",
            AppearanceSettingsView(model: model)
        ))
        tabs.addTabViewItem(Self.tab(
            String(localized: "Items"), symbol: "menubar.rectangle",
            ItemsSettingsView(items: items, model: model)
        ))
        tabs.addTabViewItem(Self.tab(
            String(localized: "Panel"), symbol: "chevron.down.square",
            PanelSettingsView(model: model, items: items)
        ))
        tabs.addTabViewItem(Self.tab(
            String(localized: "About"), symbol: "info.circle",
            AboutSettingsView(model: model)
        ))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.setAccessibilityLabel(String(localized: "Barback Settings"))
        super.init(window: window)
        window.delegate = self
        applyReduceMotion()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(tab: Tab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
        loginItem.refresh()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        loginItem.refresh()
    }

    @objc private func accessibilityOptionsChanged() {
        applyReduceMotion()
    }

    /// Tab switches resize the window; skip the crossfade when Reduce Motion is on.
    private func applyReduceMotion() {
        tabs.transitionOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? [.allowUserInteraction]
            : [.crossfade, .allowUserInteraction]
    }

    private static func tab<V: View>(_ title: String, symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}
