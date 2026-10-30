import AppKit
import BarbackCore
import SwiftUI
import Testing
@testable import Barback

@Suite("Panel interface", .serialized)
@MainActor
struct PanelInterfaceTests {
    private func row(_ id: UInt32, name: String, section: MenuBarSection = .hidden) -> MenuBarItemRow {
        typealias K = MenuBarItemParser.Key
        var item = MenuBarItemParser.parse([[
            K.number: id, K.layer: 25, K.ownerPID: 123, K.ownerName: name,
            K.bounds: ["X": 300, "Y": 0, "Width": 24, "Height": 24],
            K.isOnScreen: true,
        ]])[0]
        item.bundleID = "test.\(name)"
        return MenuBarItemRow(
            item: item, section: section, visibility: section == .visible ? .shown : .offScreen,
            overlapsNotch: false, barbackRole: nil, key: ItemKey(owner: "test.\(name)"), display: 0
        )
    }

    @Test func editorSavesRealPanelConfigurationAcrossRelaunch() throws {
        let suite = "BarbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: SettingsStore(defaults: defaults))
        let editor = PanelEditor()
        editor.addPanel(to: model)
        let id = try #require(model.selectedPanelID)
        #expect(model.settings.clickAction == .dropDown)
        let first = ItemKey(owner: "test.Clipboard")
        let second = ItemKey(owner: "test.Music")
        editor.update(model) { ItemGroups.rename(id, to: "Work", in: &$0) }
        editor.update(model) { ItemGroups.setLayout(.grid, for: id, in: &$0) }
        editor.update(model) { ItemGroups.assign(first, to: id, in: &$0) }
        editor.update(model) { ItemGroups.assign(second, to: id, in: &$0) }
        editor.update(model) { ItemGroups.moveItem(second, in: id, by: -1, groups: &$0) }
        let reloaded = AppModel(store: SettingsStore(defaults: defaults))
        #expect(reloaded.settings == model.settings)
        #expect(reloaded.settings.groups.first?.name == "Work")
        #expect(reloaded.settings.groups.first?.layout == .grid)
        #expect(reloaded.settings.groups.first?.itemKeys == [second, first])
        editor.update(model) { ItemGroups.assign(first, to: nil, in: &$0) }
        #expect(model.settings.groups.first?.itemKeys == [second])
        editor.update(model) { ItemGroups.remove(id, from: &$0) }
        #expect(model.store.load().groups.isEmpty)
    }

    @Test func editorPreservesSelectionWhenReorderingAfterRelaunchAndDeletion() throws {
        let suite = "BarbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: SettingsStore(defaults: defaults))
        let panels = [ItemGroup(name: "A"), ItemGroup(name: "B"), ItemGroup(name: "C")]
        model.settings.groups = panels
        let reloaded = AppModel(store: SettingsStore(defaults: defaults))
        let editor = PanelEditor()
        #expect(reloaded.selectedPanelID == nil)
        editor.update(reloaded) { ItemGroups.move(panels[0].id, by: 1, in: &$0) }
        #expect(reloaded.selectedPanelID == panels[0].id)
        editor.update(reloaded) { ItemGroups.move(panels[0].id, by: 1, in: &$0) }
        #expect(reloaded.settings.groups.map(\.id) == [panels[1].id, panels[2].id, panels[0].id])
        editor.update(reloaded) { ItemGroups.remove(panels[0].id, from: &$0) }
        #expect(reloaded.selectedPanelID == panels[1].id)
        editor.update(reloaded) { ItemGroups.move(panels[1].id, by: 1, in: &$0) }
        #expect(reloaded.selectedPanelID == panels[1].id)
        #expect(reloaded.settings.groups.map(\.id) == [panels[2].id, panels[1].id])
    }

    @Test func dropdownContainsOnlySelectionsInSavedOrderAndKeepsEmptyPanels() {
        let clipboard = DropDownPanelItem(row: row(1, name: "Clipboard"))
        let music = DropDownPanelItem(row: row(2, name: "Music"))
        let unselected = DropDownPanelItem(row: row(3, name: "Unselected"))
        let groups = [
            ItemGroup(name: "Work", itemKeys: [music.key, clipboard.key], layout: .grid),
            ItemGroup(name: "Empty"),
            ItemGroup(name: "Offline", itemKeys: [ItemKey(owner: "test.Offline")]),
        ]
        let boxes = DropDownPanelBox.make(
            items: [clipboard, unselected, music], groups: groups, defaultLayout: .list
        )
        #expect(boxes.map(\.title) == ["Work", "Empty", "Offline"])
        #expect(boxes[0].items.map(\.key) == [music.key, clipboard.key])
        #expect(boxes[0].layout == .grid)
        #expect(boxes[1].items.isEmpty && boxes[1].unavailableCount == 0)
        #expect(boxes[2].items.isEmpty && boxes[2].unavailableCount == 1)
        #expect(DropDownPanelBox.make(items: [unselected], groups: [], defaultLayout: .list).isEmpty)
    }

    @Test func onlyHiddenSelectionsNeedAReveal() {
        #expect(DropDownPanelItem(row: row(1, name: "Visible", section: .visible)).revealAction == nil)
        #expect(DropDownPanelItem(row: row(2, name: "Hidden")).revealAction == .show)
        #expect(DropDownPanelItem(row: row(3, name: "Always", section: .alwaysHidden)).revealAction == .showAll)
    }

    @Test func setupStateOffersConfigurationAndNeverDrawsUnidentifiedTiles() {
        let driver = PanelDriver()
        defer { driver.close() }
        driver.model.canOpenItems = true
        driver.model.unidentifiedItemCount = 34
        driver.scan()
        let height = driver.size.height
        let settings = driver.points("settings")
        #expect(settings.contains { $0.y > height - 60 }, "The header Panel Settings button is unreachable")
        #expect(settings.contains { $0.y < height - 64 }, "The Configure Panels button is unreachable")
        #expect(driver.names.contains("refresh"))
        #expect(!driver.names.contains { $0.hasPrefix("open:") })
        #expect(driver.size.width == DropDownPanelView.width)
    }

    @Test func itemsStayLockedWithoutAccessibilityThenOpenInSavedOrder() throws {
        for layout in DropDownLayout.allCases {
            let driver = PanelDriver()
            defer { driver.close() }
            let alpha = DropDownPanelItem(row: row(1, name: "Alpha"))
            let bravo = DropDownPanelItem(row: row(2, name: "Bravo"))
            let group = ItemGroup(name: "Work", itemKeys: [alpha.key, bravo.key], layout: layout)
            driver.model.boxes = DropDownPanelBox.make(items: [bravo, alpha], groups: [group], defaultLayout: .list)

            driver.model.canOpenItems = false
            driver.scan()
            #expect(!driver.names.contains { $0.hasPrefix("open:") }, "Items opened without permission in \(layout)")
            #expect(driver.names.isSuperset(of: ["allow", "reveal"]), "No recovery actions in \(layout)")

            driver.reset()
            driver.model.canOpenItems = true
            driver.scan()
            #expect(!driver.names.contains("allow") && !driver.names.contains("reveal"))
            let first = try #require(driver.center("open:\(alpha.title)"), "Alpha is unreachable in \(layout)")
            let second = try #require(driver.center("open:\(bravo.title)"), "Bravo is unreachable in \(layout)")
            switch layout {
            case .list: #expect(first.y > second.y, "List order is not top to bottom")
            case .grid: #expect(first.x < second.x, "Grid order is not left to right")
            }
        }
    }

    @Test func editButtonsCarryTheirOwnPanelIdentity() {
        let driver = PanelDriver()
        defer { driver.close() }
        let alpha = DropDownPanelItem(row: row(1, name: "Alpha"))
        let work = ItemGroup(name: "Work", itemKeys: [alpha.key])
        let empty = ItemGroup(name: "Empty")
        driver.model.canOpenItems = true
        driver.model.boxes = DropDownPanelBox.make(items: [alpha], groups: [work, empty], defaultLayout: .list)
        driver.scan()
        let edits = driver.names.filter { $0.hasPrefix("edit:") }
        #expect(edits == ["edit:\(work.id.uuidString)", "edit:\(empty.id.uuidString)"])
    }

    @Test func itemNamesAreDrawnInBothLayouts() throws {
        func render(_ names: [String], layout: DropDownLayout) throws -> Data {
            let driver = PanelDriver()
            defer { driver.close() }
            let items = names.enumerated().map { DropDownPanelItem(row: row(UInt32($0.offset + 1), name: $0.element)) }
            let group = ItemGroup(name: "Work", itemKeys: items.map(\.key), layout: layout)
            driver.model.canOpenItems = true
            driver.model.boxes = DropDownPanelBox.make(items: items, groups: [group], defaultLayout: .list)
            return try #require(driver.snapshot(), "Could not render the panel")
        }
        for layout in DropDownLayout.allCases {
            let original = try render(["Alpha", "Bravo"], layout: layout)
            #expect(try render(["Alpha", "Bravo"], layout: layout) == original, "Rendering is not repeatable in \(layout)")
            #expect(try render(["Gamma", "Delta"], layout: layout) != original, "Item names are not drawn in \(layout)")
        }
    }

    @Test func settingsFitTheirWindowWithAndWithoutPanels() throws {
        _ = NSApplication.shared
        let suite = "BarbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: SettingsStore(defaults: defaults))
        let alpha = row(1, name: "Alpha")
        let items = ItemsModel(snapshot: [alpha, row(2, name: "Bravo")], accessibilityTrusted: true)
        let host = NSHostingView(rootView: PanelSettingsView(model: model, items: items))
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        defer { window.close() }

        func settle() {
            for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
        }
        settle()
        #expect(host.fittingSize.width == SettingsMetrics.width)
        PanelEditor().addPanel(to: model)
        let id = try #require(model.selectedPanelID)
        model.settings.groups = model.settings.groups.map { group in
            var group = group
            if group.id == id { group.itemKeys = [alpha.key, ItemKey(owner: "test.Offline")] }
            return group
        }
        settle()
        #expect(host.fittingSize.width == SettingsMetrics.width)
        #expect(host.fittingSize.height > 0)
    }
}

/// SwiftUI publishes its accessibility tree only to a connected assistive client, so these tests drive the real
/// panel with mouse events delivered through an invisible, off-screen window instead of reading that tree.
@MainActor
private final class PanelDriver {
    private final class Host: NSHostingView<DropDownPanelView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    let model = DropDownPanelModel()
    private(set) var events: [(name: String, point: NSPoint)] = []
    private var current = NSPoint.zero
    private let host: Host
    private let window: NSWindow

    var names: Set<String> { Set(events.map(\.name)) }
    var size: NSSize { host.frame.size }

    init() {
        _ = NSApplication.shared
        model.chrome = .solid
        host = Host(rootView: DropDownPanelView(model: model))
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: DropDownPanelView.width, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFrontRegardless()
        model.onOpen = { [unowned self] in record("open:\($0.title)") }
        model.onOpenSettings = { [unowned self] in record("settings") }
        model.onEditPanel = { [unowned self] in record("edit:\($0.uuidString)") }
        model.onAllowAccessibility = { [unowned self] in record("allow") }
        model.onRefresh = { [unowned self] in record("refresh") }
        model.onReveal = { [unowned self] in record("reveal") }
    }

    func close() { window.close() }
    func reset() { events.removeAll() }
    func points(_ name: String) -> [NSPoint] { events.filter { $0.name == name }.map(\.point) }

    func center(_ name: String) -> NSPoint? {
        let hits = points(name)
        guard !hits.isEmpty else { return nil }
        return NSPoint(x: hits.map(\.x).reduce(0, +) / CGFloat(hits.count), y: hits.map(\.y).reduce(0, +) / CGFloat(hits.count))
    }

    /// Clicks every few points of the panel, recording which action each click reached.
    func scan(step: CGFloat = 6) {
        layout()
        var y = step / 2
        while y < size.height {
            var x = step / 2
            while x < size.width {
                click(NSPoint(x: x, y: y))
                x += step
            }
            y += step
        }
    }

    func snapshot() -> Data? {
        layout()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func layout() {
        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let fitting = host.fittingSize
        window.setContentSize(fitting)
        host.frame = NSRect(origin: .zero, size: fitting)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<2 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func click(_ point: NSPoint) {
        current = point
        // An AppKit control tracks the mouse in a nested loop on mouse down that a synthetic click can never finish.
        var target = host.hitTest(point)
        while let view = target {
            if let control = view as? NSControl {
                (control as? NSButton)?.performClick(nil)
                return
            }
            target = view.superview
        }
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure
            )
        }
        guard let down = event(.leftMouseDown, pressure: 1), let up = event(.leftMouseUp, pressure: 0) else {
            Issue.record("Could not create mouse events")
            return
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func record(_ name: String) {
        events.append((name, current))
    }
}
