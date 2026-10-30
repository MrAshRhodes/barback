import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Window list parsing")
struct MenuBarItemParserTests {
    typealias K = MenuBarItemParser.Key

    func window(
        id: Any = 100, layer: Any = 25, owner: Any? = "Control Centre", pid: Any = 1286,
        x: Any = 1845, y: Any = 0, w: Any = 32, h: Any = 24, onScreen: Any? = true, name: Any? = nil
    ) -> [String: Any] {
        var d: [String: Any] = [
            K.number: id, K.layer: layer, K.ownerPID: pid,
            K.bounds: ["X": x, "Y": y, "Width": w, "Height": h] as [String: Any],
        ]
        if let owner { d[K.ownerName] = owner }
        if let onScreen { d[K.isOnScreen] = onScreen }
        if let name { d[K.name] = name }
        return d
    }

    @Test func emptyInputYieldsNoItems() {
        #expect(MenuBarItemParser.parse([]).isEmpty)
        #expect(!MenuBarItemParser.containsOpenMenu([]))
    }

    @Test func parsesAndSortsLeftToRight() {
        let items = MenuBarItemParser.parse([
            window(id: 3, owner: "Maccy", pid: 73080, x: 3000.0),
            window(id: 1, x: 1845),
            window(id: 2, x: NSNumber(value: 2100.5)),
        ])
        #expect(items.map(\.windowID) == [1, 2, 3])
        #expect(items[1].frame.minX == 2100.5)
        #expect(items[2].ownerName == "Maccy")
        #expect(items[2].ownerPID == 73080)
        #expect(items[0].isHostedBySystem)
        #expect(!items[2].isHostedBySystem)
    }

    @Test func skipsMalformedAndForeignWindows() {
        let items = MenuBarItemParser.parse([
            window(id: 1, layer: 0),                       // normal window
            window(id: 2, layer: "25"),                    // wrong type
            ["garbage": true],                              // nothing useful
            window(id: 3, owner: "Window Server"),         // WindowServer chrome
            window(id: 4, h: 850),                         // tall status-level panel (popover)
            window(id: 5, w: 0),                           // zero width
            window(id: -1),                                // invalid id
            { var d = window(id: 6); d[K.bounds] = "nope"; return d }(),
            { var d = window(id: 7); d.removeValue(forKey: K.bounds); return d }(),
            window(id: 8, x: Double.nan),                  // non-finite
            window(id: 9),                                  // the only valid one
        ])
        #expect(items.map(\.windowID) == [9])
    }

    @Test func missingOptionalFieldsUseFallbacks() {
        let items = MenuBarItemParser.parse([window(id: 10, owner: nil, onScreen: nil, name: "")])
        #expect(items.count == 1)
        #expect(items[0].ownerName == "Unknown")
        #expect(items[0].isOnScreen == false)
        #expect(items[0].title == nil)
    }

    @Test func menuBarTopsFilterStrayWindows() {
        let windows = [window(id: 1, y: 0), window(id: 2, y: 1487), window(id: 3, y: -113)]
        #expect(MenuBarItemParser.parse(windows, menuBarTops: [0]).map(\.windowID) == [1])
        #expect(MenuBarItemParser.parse(windows, menuBarTops: [0, -113]).map(\.windowID).sorted() == [1, 3])
        #expect(MenuBarItemParser.parse(windows, menuBarTops: []).count == 3, "empty list means no filter")
    }

    @Test func visibilityOnScreens() {
        let screens = [CGRect(x: 0, y: 0, width: 3440, height: 1440)]
        let shown = MenuBarItem(windowID: 1, ownerName: "A", ownerPID: 1, frame: CGRect(x: 2000, y: 0, width: 30, height: 24), isOnScreen: true)
        var pushedOff = shown
        pushedOff.frame.origin.x = -8000
        var offFlag = shown
        offFlag.isOnScreen = false
        #expect(shown.isVisible(onScreens: screens))
        #expect(!pushedOff.isVisible(onScreens: screens))
        #expect(!offFlag.isVisible(onScreens: screens))
        #expect(!shown.isVisible(onScreens: []))
    }

    @Test func detectsOpenPopUpMenus() {
        #expect(MenuBarItemParser.containsOpenMenu([window(id: 1), window(id: 2, layer: 101)]))
        #expect(!MenuBarItemParser.containsOpenMenu([window(id: 2, layer: 101, onScreen: false)]))
        #expect(!MenuBarItemParser.containsOpenMenu([window(id: 1)]))
    }

    @Test func resolvesNamesByPosition() {
        let items = MenuBarItemParser.parse([window(id: 1, x: 1845, w: 32), window(id: 2, x: 2000, w: 40)])
        let resolved = MenuBarItemParser.resolveNames(items, using: [(name: "Wi-Fi", minX: 1846, width: 32)])
        #expect(resolved[0].displayName == "Wi-Fi")
        #expect(resolved[1].resolvedName == nil)
        #expect(resolved[1].displayName == "Control Centre")
        #expect(MenuBarItemParser.resolveNames(items, using: []) == items)
    }
}
