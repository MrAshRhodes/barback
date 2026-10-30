import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

// MARK: - Settings

@Suite("Drop-down settings")
struct DropDownSettingsTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "barback.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func defaultsKeepTheOriginalBehaviour() {
        let s = BarbackSettings.default
        #expect(s.clickAction == .revealStrip)
        #expect(s.dropDownLayout == .list)
        #expect(s.groups.isEmpty)
    }

    @Test func emptyStoreLoadsDefaultsAndWritesNoGroups() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        #expect(store.load() == .default)
        store.save(.default)
        #expect(d.object(forKey: SettingsKey.groups.rawValue) == nil)
        #expect(d.string(forKey: SettingsKey.clickAction.rawValue) == "revealStrip")
    }

    @Test func roundTripsClickActionLayoutAndGroups() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        var s = BarbackSettings.default
        s.clickAction = .dropDown
        s.dropDownLayout = .grid
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", symbol: "briefcase", to: &groups)!
        ItemGroups.assign(ItemKey(owner: "com.slack", detail: nil, ordinal: 0), to: work, in: &groups)
        ItemGroups.assign(ItemKey(owner: "com.apple.controlcenter", detail: "Wi-Fi", ordinal: 1), to: work, in: &groups)
        ItemGroups.add(name: "Gaming", to: &groups)
        s.groups = groups
        store.save(s)
        #expect(store.load() == s)
        #expect(d.data(forKey: SettingsKey.groups.rawValue) != nil)
    }

    @Test func unknownEnumValuesFallBackToDefaults() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        d.set("somethingNew", forKey: SettingsKey.clickAction.rawValue)
        d.set("carousel", forKey: SettingsKey.dropDownLayout.rawValue)
        let s = SettingsStore(defaults: d).load()
        #expect(s.clickAction == .revealStrip)
        #expect(s.dropDownLayout == .list)
    }

    @Test func corruptGroupDataMeansNoGroups() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        for junk in [Data("not json".utf8), Data("{\"a\":1}".utf8), Data("[{\"id\":\"nope\"}]".utf8), Data()] {
            d.set(junk, forKey: SettingsKey.groups.rawValue)
            #expect(store.load().groups.isEmpty)
        }
        d.set(42, forKey: SettingsKey.groups.rawValue)
        #expect(store.load().groups.isEmpty)
        d.set("also not json", forKey: SettingsKey.groups.rawValue)
        #expect(store.load().groups.isEmpty)
    }

    @Test func groupsAcceptedAsJSONString() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let id = UUID()
        d.set("[{\"id\":\"\(id.uuidString)\",\"name\":\"Work\"}]", forKey: SettingsKey.groups.rawValue)
        let groups = SettingsStore(defaults: d).load().groups
        #expect(groups.count == 1)
        #expect(groups[0].id == id)
        #expect(groups[0].symbol == ItemGroups.defaultSymbol, "missing symbol falls back")
        #expect(groups[0].itemKeys.isEmpty)
    }

    @Test func loadRepairsDamagedGroups() throws {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let id = UUID()
        let damaged = [
            ItemGroup(id: id, name: "   ", symbol: "bad symbol!", itemKeys: [ItemKey(owner: "a"), ItemKey(owner: "a")]),
            ItemGroup(id: id, name: "Duplicate id"),
        ]
        d.set(try JSONEncoder().encode(damaged), forKey: SettingsKey.groups.rawValue)
        let groups = SettingsStore(defaults: d).load().groups
        #expect(groups.count == 1)
        #expect(groups[0].name == "Group")
        #expect(groups[0].symbol == "folder")
        #expect(groups[0].itemKeys == [ItemKey(owner: "a")])
    }

    @Test func resetRemovesTheNewKeys() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        var s = BarbackSettings.default
        s.clickAction = .dropDown
        ItemGroups.add(name: "Work", to: &s.groups)
        store.save(s)
        store.reset()
        #expect(store.load() == .default)
    }

    @Test func sanitizedIsIdempotent() {
        var s = BarbackSettings.default
        s.groups = (0..<20).map { ItemGroup(id: UUID(), name: $0 % 3 == 0 ? "Same" : " x\ty ", itemKeys: [ItemKey(owner: "o\($0 % 4)")]) }
        let once = s.sanitized()
        #expect(once.groups.count == ItemGroups.maxGroups)
        #expect(once.sanitized() == once)
    }

    @Test func clickActionAndLayoutRawValuesAreStable() {
        #expect(ClickAction.revealStrip.rawValue == "revealStrip")
        #expect(ClickAction.dropDown.rawValue == "dropDown")
        #expect(DropDownLayout.list.rawValue == "list")
        #expect(DropDownLayout.grid.rawValue == "grid")
    }
}

// MARK: - Groups

@Suite("Item groups")
struct ItemGroupTests {
    private let a = ItemKey(owner: "com.a")
    private let b = ItemKey(owner: "com.b")
    private let c = ItemKey(owner: "com.c")

    @Test func nameSanitising() {
        #expect(ItemGroups.sanitizedName("  Work  ") == "Work")
        #expect(ItemGroups.sanitizedName("Side\n  projects") == "Side projects")
        #expect(ItemGroups.sanitizedName("Tab\tseparated") == "Tab separated")
        #expect(ItemGroups.sanitizedName("Bell\u{7}Name") == "BellName")
        #expect(ItemGroups.sanitizedName("   \n ") == nil)
        #expect(ItemGroups.sanitizedName("") == nil)
        let long = ItemGroups.sanitizedName(String(repeating: "a", count: 100))
        #expect(long?.count == ItemGroups.maxNameLength)
    }

    @Test func symbolSanitising() {
        #expect(ItemGroups.sanitizedSymbol("briefcase") == "briefcase")
        #expect(ItemGroups.sanitizedSymbol(" gamecontroller.fill ") == "gamecontroller.fill")
        #expect(ItemGroups.sanitizedSymbol("") == ItemGroups.defaultSymbol)
        #expect(ItemGroups.sanitizedSymbol("not a symbol") == ItemGroups.defaultSymbol)
        #expect(ItemGroups.sanitizedSymbol(String(repeating: "a", count: 65)) == ItemGroups.defaultSymbol)
    }

    @Test func paletteHasTwelveDistinctSymbolsAndSuggestionsUseThem() {
        #expect(ItemGroups.symbolPalette.count == 12)
        #expect(Set(ItemGroups.symbolPalette).count == 12)
        #expect(ItemGroups.suggestions.map(\.name) == ["Work", "Gaming", "Media", "Social", "Utilities"])
        for suggestion in ItemGroups.suggestions {
            #expect(ItemGroups.symbolPalette.contains(suggestion.symbol))
        }
    }

    @Test func addCreatesGroupsUpToTheLimit() {
        var groups: [ItemGroup] = []
        for i in 0..<ItemGroups.maxGroups {
            #expect(ItemGroups.add(name: "G\(i)", to: &groups) != nil)
        }
        #expect(groups.count == ItemGroups.maxGroups)
        #expect(ItemGroups.add(name: "One too many", to: &groups) == nil)
        #expect(groups.count == ItemGroups.maxGroups)
    }

    @Test func addFixesUnusableAndDuplicateNames() {
        var groups: [ItemGroup] = []
        ItemGroups.add(name: "Work", to: &groups)
        ItemGroups.add(name: "work", to: &groups)
        ItemGroups.add(name: "WORK", to: &groups)
        ItemGroups.add(name: "  ", symbol: "bad symbol", to: &groups)
        #expect(groups.map(\.name) == ["Work", "work 2", "WORK 3", "Group"])
        #expect(groups[3].symbol == ItemGroups.defaultSymbol)
    }

    @Test func uniqueSuffixStaysWithinTheLengthLimit() {
        let long = String(repeating: "x", count: ItemGroups.maxNameLength)
        var groups: [ItemGroup] = []
        ItemGroups.add(name: long, to: &groups)
        let second = ItemGroups.add(name: long, to: &groups)!
        let name = groups.first { $0.id == second }!.name
        #expect(name.count == ItemGroups.maxNameLength)
        #expect(name.hasSuffix(" 2"))
    }

    @Test func renameKeepsNamesUniqueAndRejectsEmpty() {
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", to: &groups)!
        let play = ItemGroups.add(name: "Play", to: &groups)!
        #expect(ItemGroups.rename(play, to: "  Games ", in: &groups))
        #expect(groups[1].name == "Games")
        #expect(ItemGroups.rename(play, to: "work", in: &groups))
        #expect(groups[1].name == "work 2")
        #expect(ItemGroups.rename(work, to: "Work", in: &groups), "keeping your own name is fine")
        #expect(groups[0].name == "Work")
        #expect(!ItemGroups.rename(work, to: "   ", in: &groups))
        #expect(groups[0].name == "Work")
        #expect(!ItemGroups.rename(UUID(), to: "Nope", in: &groups))
    }

    @Test func setSymbolValidatesAndNeedsAnExistingGroup() {
        var groups: [ItemGroup] = []
        let id = ItemGroups.add(name: "Work", to: &groups)!
        #expect(ItemGroups.setSymbol("briefcase", for: id, in: &groups))
        #expect(groups[0].symbol == "briefcase")
        #expect(ItemGroups.setSymbol("???", for: id, in: &groups))
        #expect(groups[0].symbol == ItemGroups.defaultSymbol)
        #expect(!ItemGroups.setSymbol("star", for: UUID(), in: &groups))
    }

    @Test func removeDeletesTheGroupAndFreesItsItems() {
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", to: &groups)!
        ItemGroups.assign(a, to: work, in: &groups)
        #expect(ItemGroups.remove(work, from: &groups))
        #expect(groups.isEmpty)
        #expect(ItemGroups.groupID(for: a, in: groups) == nil)
        #expect(!ItemGroups.remove(work, from: &groups))
    }

    @Test func moveReordersAndStopsAtTheEnds() {
        var groups: [ItemGroup] = []
        let ids = ["A", "B", "C"].map { ItemGroups.add(name: $0, to: &groups)! }
        #expect(ItemGroups.move(ids[2], by: -1, in: &groups))
        #expect(groups.map(\.name) == ["A", "C", "B"])
        #expect(ItemGroups.move(ids[0], by: 5, in: &groups))
        #expect(groups.map(\.name) == ["C", "B", "A"])
        #expect(!ItemGroups.move(ids[0], by: 1, in: &groups), "already last")
        #expect(ItemGroups.move(ids[1], by: -9, in: &groups), "clamped to the first place")
        #expect(groups.map(\.name) == ["B", "C", "A"])
        #expect(!ItemGroups.move(ids[1], by: -1, in: &groups), "already first")
        #expect(!ItemGroups.move(UUID(), by: 1, in: &groups))
    }

    @Test func anItemBelongsToAtMostOneGroup() {
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", to: &groups)!
        let play = ItemGroups.add(name: "Play", to: &groups)!
        #expect(ItemGroups.assign(a, to: work, in: &groups))
        #expect(ItemGroups.groupID(for: a, in: groups) == work)
        #expect(ItemGroups.assign(a, to: play, in: &groups))
        #expect(ItemGroups.groupID(for: a, in: groups) == play)
        #expect(groups[0].itemKeys.isEmpty)
        #expect(groups[1].itemKeys == [a])
        #expect(ItemGroups.assign(a, to: play, in: &groups), "assigning again is a no-op")
        #expect(groups[1].itemKeys == [a])
        #expect(ItemGroups.assign(a, to: nil, in: &groups))
        #expect(ItemGroups.groupID(for: a, in: groups) == nil)
    }

    @Test func assigningToAMissingGroupChangesNothing() {
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", to: &groups)!
        ItemGroups.assign(a, to: work, in: &groups)
        #expect(!ItemGroups.assign(a, to: UUID(), in: &groups))
        #expect(ItemGroups.groupID(for: a, in: groups) == work)
    }

    @Test func fullGroupsRefuseMoreItemsWithoutLosingTheOldAssignment() {
        var groups: [ItemGroup] = []
        let full = ItemGroups.add(name: "Full", to: &groups)!
        let other = ItemGroups.add(name: "Other", to: &groups)!
        for i in 0..<ItemGroups.maxKeysPerGroup { ItemGroups.assign(ItemKey(owner: "k\(i)"), to: full, in: &groups) }
        ItemGroups.assign(a, to: other, in: &groups)
        #expect(!ItemGroups.assign(a, to: full, in: &groups))
        #expect(ItemGroups.groupID(for: a, in: groups) == other)
    }

    @Test func sanitizedRepairsWithoutReorderingGoodData() {
        let id1 = UUID(), id2 = UUID()
        let input = [
            ItemGroup(id: id1, name: "Work", symbol: "briefcase", itemKeys: [a, b, a]),
            ItemGroup(id: id2, name: "work", symbol: "star", itemKeys: [b, c, ItemKey(owner: "  ")]),
            ItemGroup(id: id1, name: "Dup", itemKeys: [c]),
        ]
        let out = ItemGroups.sanitized(input)
        #expect(out.map(\.id) == [id1, id2])
        #expect(out.map(\.name) == ["Work", "work 2"])
        #expect(out[0].itemKeys == [a, b])
        #expect(out[1].itemKeys == [c], "b stays in the first group; blank owners are dropped")
        #expect(ItemGroups.sanitized(out) == out)
    }

    @Test func partitionOrdersGroupsThenOtherAndKeepsInputOrder() {
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", to: &groups)!
        let play = ItemGroups.add(name: "Play", to: &groups)!
        ItemGroups.add(name: "Empty", to: &groups)
        let keys = ["a", "b", "c", "d", "e"].map { ItemKey(owner: $0) }
        ItemGroups.assign(keys[3], to: play, in: &groups)
        ItemGroups.assign(keys[0], to: work, in: &groups)
        ItemGroups.assign(keys[4], to: work, in: &groups)
        let items = Array(keys.enumerated())

        let parts = ItemGroups.partition(items, groups: groups) { $0.element }
        #expect(parts.map { $0.group?.name } == ["Work", "Play", nil])
        #expect(parts[0].items.map(\.offset) == [0, 4])
        #expect(parts[1].items.map(\.offset) == [3])
        #expect(parts[2].items.map(\.offset) == [1, 2])

        let withEmpty = ItemGroups.partition(items, groups: groups, includeEmptyGroups: true) { $0.element }
        #expect(withEmpty.map { $0.group?.name } == ["Work", "Play", "Empty", nil])
        #expect(withEmpty[2].items.isEmpty)
    }

    @Test func partitionWithoutGroupsIsOneUngroupedBoxAndNothingWhenEmpty() {
        let items = [ItemKey(owner: "a"), ItemKey(owner: "b")]
        let parts = ItemGroups.partition(items, groups: []) { $0 }
        #expect(parts.count == 1)
        #expect(parts[0].group == nil)
        #expect(parts[0].items == items)
        #expect(ItemGroups.partition([ItemKey](), groups: []) { $0 }.isEmpty)
    }

    @Test func partitionIsDeterministicAndIgnoresKeysThatAreGone() {
        var groups: [ItemGroup] = []
        let work = ItemGroups.add(name: "Work", to: &groups)!
        ItemGroups.assign(ItemKey(owner: "uninstalled"), to: work, in: &groups)
        ItemGroups.assign(a, to: work, in: &groups)
        let first = ItemGroups.partition([a, b], groups: groups) { $0 }
        let second = ItemGroups.partition([a, b], groups: groups) { $0 }
        #expect(first == second)
        #expect(first.map(\.items) == [[a], [b]])
    }

    @Test func groupsCodableRoundTripAndLenientDecoding() throws {
        let group = ItemGroup(name: "Work", symbol: "briefcase", itemKeys: [ItemKey(owner: "x", detail: "Wi-Fi", ordinal: 2)])
        let data = try JSONEncoder().encode([group])
        #expect(try JSONDecoder().decode([ItemGroup].self, from: data) == [group])

        let id = UUID()
        let minimal = Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"X\",\"itemKeys\":[{\"owner\":\"o\"}]}]".utf8)
        let decoded = try JSONDecoder().decode([ItemGroup].self, from: minimal)
        #expect(decoded.first?.itemKeys == [ItemKey(owner: "o", detail: nil, ordinal: 0)])
    }
}

// MARK: - Item keys

@Suite("Item keys")
struct ItemKeyTests {
    private func item(
        _ id: UInt32, owner: String = "App", x: CGFloat, width: CGFloat = 24,
        bundleID: String? = nil, detail: String? = nil, title: String? = nil
    ) -> MenuBarItem {
        MenuBarItem(
            windowID: id, ownerName: owner, ownerPID: Int32(id), title: title,
            frame: CGRect(x: x, y: 0, width: width, height: 24), isOnScreen: true, bundleID: bundleID, detail: detail
        )
    }

    @Test func ownerPrefersBundleIdentifierOverProcessName() {
        #expect(ItemKeyAssigner.identity(of: item(1, owner: "Slack", x: 0, bundleID: "com.tinyspeck.slackmacgap")).owner
                == "com.tinyspeck.slackmacgap")
        #expect(ItemKeyAssigner.identity(of: item(1, owner: "Slack", x: 0)).owner == "Slack")
        #expect(ItemKeyAssigner.identity(of: item(1, owner: "Slack", x: 0, bundleID: "")).owner == "Slack")
    }

    @Test func detailComesFromAccessibilityOrASystemHostsWindowTitle() {
        #expect(ItemKeyAssigner.identity(of: item(1, x: 0, detail: " Wi-Fi ")).detail == "Wi-Fi")
        #expect(ItemKeyAssigner.identity(of: item(1, x: 0, detail: "  ")).detail == nil)
        #expect(ItemKeyAssigner.identity(of: item(1, owner: "Control Center", x: 0, title: "Battery")).detail == "Battery")
        #expect(ItemKeyAssigner.identity(of: item(1, owner: "Dropbox", x: 0, title: "Window")).detail == nil)
    }

    @Test func keysDoNotDependOnWindowIDsOrAbsolutePositions() {
        let first = [item(10, owner: "Control Center", x: -500), item(11, owner: "Control Center", x: -400)]
        let relaunched = [item(900, owner: "Control Center", x: -3000), item(950, owner: "Control Center", x: 1000)]
        let k1 = ItemKeyAssigner.keys(for: first)
        let k2 = ItemKeyAssigner.keys(for: relaunched)
        #expect(k1[10] == k2[900])
        #expect(k1[11] == k2[950])
        #expect(k1[10] != k1[11])
        #expect(k1[10]?.ordinal == 0)
        #expect(k1[11]?.ordinal == 1)
    }

    @Test func ordinalsFollowLeftToRightOrderWithWindowIDTieBreak() {
        let items = [item(3, x: 100), item(1, x: 50), item(2, x: 50)]
        let keys = ItemKeyAssigner.keys(for: items)
        #expect(keys[1]?.ordinal == 0)
        #expect(keys[2]?.ordinal == 1)
        #expect(keys[3]?.ordinal == 2)
    }

    @Test func differentOwnersAndDetailsCountSeparately() {
        let items = [
            item(1, owner: "A", x: 0), item(2, owner: "B", x: 10),
            item(3, owner: "Control Center", x: 20, detail: "Wi-Fi"),
            item(4, owner: "Control Center", x: 30, detail: "Battery"),
        ]
        let keys = ItemKeyAssigner.keys(for: items)
        #expect(Set(keys.values).count == 4)
        #expect(keys.values.allSatisfy { $0.ordinal == 0 })
    }

    @Test func ordinalsAreCountedPerDisplay() {
        let displays = [
            MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            MenuBarDisplay(frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        let items = [item(1, x: 100), item(2, x: 1100), item(3, x: 1200)]
        let keys = ItemKeyAssigner.keys(for: items, displays: displays)
        #expect(keys[1]?.ordinal == 0)
        #expect(keys[2]?.ordinal == 0)
        #expect(keys[3]?.ordinal == 1)
        #expect(ItemKeyAssigner.item(for: keys[2]!, in: items, displays: displays, display: 1)?.windowID == 2)
        #expect(ItemKeyAssigner.item(for: keys[1]!, in: items, displays: displays, display: 1)?.windowID == 2)
        #expect(ItemKeyAssigner.item(for: keys[1]!, in: items, displays: displays, display: 0)?.windowID == 1)
    }

    @Test func offScreenItemsKeepTheKeyTheyHadWhileRevealed() {
        let displays = [MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))]
        let revealed = [item(1, owner: "A", x: 400), item(2, owner: "A", x: 450)]
        let hidden = [item(1, owner: "A", x: -9600), item(2, owner: "A", x: -9550)]
        #expect(ItemKeyAssigner.keys(for: revealed, displays: displays) == ItemKeyAssigner.keys(for: hidden, displays: displays))
    }

    @Test func findsAnItemByKeyInAFreshScan() {
        let before = [item(1, owner: "A", x: 0), item(2, owner: "B", x: 50), item(3, owner: "B", x: 80)]
        let key = ItemKeyAssigner.keys(for: before)[3]!
        let after = [item(77, owner: "B", x: 600), item(78, owner: "B", x: 640), item(79, owner: "A", x: 900)]
        #expect(ItemKeyAssigner.item(for: key, in: after)?.windowID == 78)
        #expect(ItemKeyAssigner.item(for: ItemKey(owner: "Gone"), in: after) == nil)
    }

    @Test func codableRoundTripAndClampedOrdinal() throws {
        let key = ItemKey(owner: "com.x", detail: "Wi-Fi", ordinal: 3)
        #expect(try JSONDecoder().decode(ItemKey.self, from: JSONEncoder().encode(key)) == key)
        let odd = try JSONDecoder().decode(ItemKey.self, from: Data("{\"owner\":\"o\",\"ordinal\":-4}".utf8))
        #expect(odd.ordinal == 0)
    }
}

// MARK: - Accessibility matching

@Suite("Accessibility matching")
struct AccessibilityMatchingTests {
    @Test func bestMatchPicksTheClosestWithinTolerance() {
        let frames = [CGRect(x: 100, y: 0, width: 24, height: 24), CGRect(x: 101.5, y: 0, width: 24, height: 24), CGRect(x: 300, y: 0, width: 24, height: 24)]
        #expect(FrameMatcher.bestMatchIndex(for: CGRect(x: 101, y: 0, width: 24, height: 22), among: frames) == 1)
        #expect(FrameMatcher.bestMatchIndex(for: CGRect(x: 300.5, y: 0, width: 24, height: 24), among: frames) == 2)
        #expect(FrameMatcher.bestMatchIndex(for: CGRect(x: 200, y: 0, width: 24, height: 24), among: frames) == nil)
        #expect(FrameMatcher.bestMatchIndex(for: CGRect(x: 100, y: 0, width: 40, height: 24), among: frames) == nil, "width must match too")
        #expect(FrameMatcher.bestMatchIndex(for: .zero, among: []) == nil)
    }

    @Test func accessibilityItemNaming() {
        let wifi = AccessibilityItem(appName: "Control Center", pid: 5, description: "Wi-Fi", frame: .zero)
        #expect(wifi.displayName == "Control Center — Wi-Fi")
        #expect(wifi.detail == "Wi-Fi")
        let same = AccessibilityItem(appName: "Slack", pid: 6, description: "Slack", frame: .zero)
        #expect(same.displayName == "Slack")
        #expect(same.detail == nil)
        let blank = AccessibilityItem(appName: "", pid: 7, description: "Clock", frame: .zero)
        #expect(blank.displayName == "Clock")
        #expect(AccessibilityItem(appName: "X", pid: 1, description: "  ", frame: .zero).detail == nil)
    }

    @Test func resolveFillsNameBundleDetailAndRealProcess() {
        let items = [
            MenuBarItem(windowID: 1, ownerName: "Control Center", ownerPID: 50, frame: CGRect(x: 100, y: 0, width: 30, height: 24), isOnScreen: true),
            MenuBarItem(windowID: 2, ownerName: "Control Center", ownerPID: 50, frame: CGRect(x: 200, y: 0, width: 30, height: 24), isOnScreen: true),
        ]
        let candidates = [
            AccessibilityItem(appName: "Dropbox", bundleID: "com.getdropbox.dropbox", pid: 77, description: "Dropbox", frame: CGRect(x: 100.5, y: 0, width: 30, height: 24)),
        ]
        let resolved = MenuBarItemParser.resolve(items, using: candidates)
        #expect(resolved[0].resolvedName == "Dropbox")
        #expect(resolved[0].bundleID == "com.getdropbox.dropbox")
        #expect(resolved[0].sourcePID == 77)
        #expect(resolved[1].resolvedName == nil)
        #expect(MenuBarItemParser.resolve(items, using: []) == items)
    }
    @Test func panelNamesAreShortForSystemItems() {
        let frame = CGRect(x: 0, y: 0, width: 30, height: 24)
        var wifi = MenuBarItem(windowID: 1, ownerName: "Control Center", ownerPID: 50, frame: frame, isOnScreen: true)
        wifi = MenuBarItemParser.resolve(
            [wifi],
            using: [AccessibilityItem(appName: "Control Center", bundleID: "com.apple.controlcenter", pid: 50, description: "Wi-Fi", frame: frame)]
        )[0]
        #expect(wifi.isSystemItem)
        #expect(wifi.panelName == "Wi-Fi")

        var dropbox = MenuBarItem(windowID: 2, ownerName: "Control Center", ownerPID: 50, frame: frame, isOnScreen: true)
        dropbox = MenuBarItemParser.resolve(
            [dropbox],
            using: [AccessibilityItem(appName: "Dropbox", bundleID: "com.getdropbox.dropbox", pid: 77, description: "Sync", frame: frame)]
        )[0]
        #expect(!dropbox.isSystemItem)
        #expect(dropbox.panelName == "Dropbox — Sync")

        let unresolved = MenuBarItem(windowID: 3, ownerName: "Control Center", ownerPID: 50, frame: frame, isOnScreen: true)
        #expect(unresolved.isSystemItem, "nothing says otherwise, so it is treated as a system item")
        let plain = MenuBarItem(windowID: 4, ownerName: "Slack", ownerPID: 9, frame: frame, isOnScreen: true)
        #expect(!plain.isSystemItem)
        #expect(plain.panelName == "Slack")
    }
}

// MARK: - Panel content rules

@Suite("Drop-down panel content")
struct DropDownContentTests {
    @Test func listsHiddenAndAlwaysHiddenItemsOnly() {
        func box(_ section: MenuBarSection, _ visibility: ItemVisibility = .offScreen, own: Bool = false, always: Bool = true) -> DropDownContent.Box? {
            DropDownContent.box(section: section, visibility: visibility, isBarbackItem: own, alwaysHiddenEnabled: always)
        }
        #expect(box(.hidden) == .hidden)
        #expect(box(.hidden, .shown) == .hidden, "still listed while the strip is revealed")
        #expect(box(.alwaysHidden) == .alwaysHidden)
        #expect(box(.alwaysHidden, always: false) == nil)
        #expect(box(.visible) == nil)
        #expect(box(.unknown) == nil)
        #expect(box(.hidden, own: true) == nil)
        #expect(box(.hidden, .notDrawn) == nil)
    }

    @Test func revealActionMatchesTheSection() {
        #expect(DropDownContent.revealAction(for: .hidden) == .show)
        #expect(DropDownContent.revealAction(for: .alwaysHidden) == .showAll)
    }

    @Test func everyPanelSymbolExistsOnThisSystem() {
        var names = ItemGroups.symbolPalette + ItemGroups.suggestions.map(\.symbol) + [ItemGroups.defaultSymbol]
        for style in ToggleIconStyle.allCases {
            names += [true, false].compactMap { style.dropDownSymbolName(panelOpen: $0) }
        }
        names += DropDownContent.systemSymbolNames
        names += ["questionmark.app", "tray", "eye.slash", "chevron.down.square", "ellipsis.circle", "list.bullet", "square.grid.2x2", "gearshape", "hand.raised"]
        for name in names {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }

    @Test func systemItemsGetFittingSymbols() {
        #expect(DropDownContent.systemSymbol(forDetail: "Wi-Fi") == "wifi")
        #expect(DropDownContent.systemSymbol(forDetail: "  battery ") == "battery.100")
        #expect(DropDownContent.systemSymbol(forDetail: "Something Else") == DropDownContent.genericSystemSymbol)
        #expect(DropDownContent.systemSymbol(forDetail: nil) == DropDownContent.genericSystemSymbol)
    }

    @Test func onlyDirectionalToggleStylesChangeInDropDownMode() {
        #expect(ToggleIconStyle.chevron.dropDownSymbolName(panelOpen: false) == "chevron.down")
        #expect(ToggleIconStyle.chevron.dropDownSymbolName(panelOpen: true) == "chevron.up")
        #expect(ToggleIconStyle.chevronCircle.dropDownSymbolName(panelOpen: false) == "chevron.down.circle")
        #expect(ToggleIconStyle.triangle.dropDownSymbolName(panelOpen: true) == "arrowtriangle.up.fill")
        #expect(ToggleIconStyle.eye.dropDownSymbolName(panelOpen: false) == nil)
        #expect(ToggleIconStyle.mug.dropDownSymbolName(panelOpen: true) == nil)
    }
}

// MARK: - Placement

@Suite("Drop-down placement")
struct DropDownPlacementTests {
    /// A 1512 × 982 screen whose menu bar is 38pt tall (AppKit coordinates: origin bottom-left).
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let size = CGSize(width: 340, height: 400)

    private func icon(maxX: CGFloat) -> CGRect {
        CGRect(x: maxX - 24, y: 944, width: 24, height: 38)
    }

    @Test func rightEdgeLinesUpWithTheIconAndTheTopHangsJustBelowIt() {
        let frame = DropDownPlacement.frame(size: size, anchor: icon(maxX: 1200), visible: visible)
        #expect(frame.maxX == 1200)
        #expect(frame.width == 340)
        #expect(frame.maxY == 944 - DropDownPlacement.gap)
        #expect(frame.height == 400)
    }

    @Test func staysInsideTheRightEdgeWithAMargin() {
        let frame = DropDownPlacement.frame(size: size, anchor: icon(maxX: 1510), visible: visible)
        #expect(frame.maxX == 1512 - DropDownPlacement.margin)
    }

    @Test func anIconNearTheLeftEdgeShiftsThePanelRightButKeepsItUnderTheIcon() {
        let anchor = icon(maxX: 60)
        let frame = DropDownPlacement.frame(size: size, anchor: anchor, visible: visible)
        #expect(frame.minX == DropDownPlacement.margin)
        #expect(frame.minX <= anchor.minX)
        #expect(frame.maxX >= anchor.maxX)
    }

    @Test func followsTheScreenTheIconIsOn() {
        // A second display to the right of the first, with its own origin.
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1055)
        let anchor = CGRect(x: 3000, y: second.maxY, width: 24, height: 25)
        let frame = DropDownPlacement.frame(size: size, anchor: anchor, visible: second)
        #expect(frame.maxX == 3024)
        #expect(frame.maxY == second.maxY - DropDownPlacement.gap)
        #expect(second.contains(frame))
    }

    @Test func neverRisesIntoTheMenuBar() {
        // An anchor reported lower than the usable area's top is still honoured; one reported higher is clamped.
        let high = CGRect(x: 1000, y: 970, width: 24, height: 38)
        let frame = DropDownPlacement.frame(size: size, anchor: high, visible: visible)
        #expect(frame.maxY <= visible.maxY)
    }

    @Test func tallPanelsAreCutToTheRoomBelowTheIcon() {
        let frame = DropDownPlacement.frame(size: CGSize(width: 340, height: 5000), anchor: icon(maxX: 800), visible: visible)
        #expect(frame.minY == visible.minY + DropDownPlacement.margin)
        #expect(frame.height == DropDownPlacement.maxHeight(anchor: icon(maxX: 800), visible: visible))
    }

    @Test func narrowScreensShrinkThePanelToFit() {
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 700)
        let frame = DropDownPlacement.frame(size: size, anchor: CGRect(x: 250, y: 700, width: 24, height: 25), visible: narrow)
        #expect(frame.width == 300 - 2 * DropDownPlacement.margin)
        #expect(frame.minX == DropDownPlacement.margin)
    }

    @Test func degenerateAreasGiveAnEmptyFrameRatherThanNegativeSizes() {
        let flat = CGRect(x: 0, y: 0, width: 400, height: 10)
        let frame = DropDownPlacement.frame(size: size, anchor: CGRect(x: 300, y: 10, width: 24, height: 25), visible: flat)
        #expect(frame.height == 0)
        #expect(DropDownPlacement.maxHeight(anchor: CGRect(x: 0, y: 0, width: 24, height: 25), visible: flat) == 0)
    }
}

@Suite("Drop-down module grid")
struct DropDownModuleGridTests {
    @Test func smallnessDependsOnTheLayout() {
        #expect(DropDownModuleGrid.isCompact(itemCount: 4, layout: .grid))
        #expect(!DropDownModuleGrid.isCompact(itemCount: 5, layout: .grid))
        #expect(DropDownModuleGrid.isCompact(itemCount: 3, layout: .list))
        #expect(!DropDownModuleGrid.isCompact(itemCount: 4, layout: .list))
    }

    @Test func neighbouringSmallBoxesShareARow() {
        #expect(DropDownModuleGrid.rows(compact: [true, true, true, true]) == [[0, 1], [2, 3]])
    }

    @Test func aSmallBoxWithoutAPartnerTakesTheWholeRow() {
        #expect(DropDownModuleGrid.rows(compact: [true, true, true]) == [[0, 1], [2]])
        #expect(DropDownModuleGrid.rows(compact: [true, false, true]) == [[0], [1], [2]])
        #expect(DropDownModuleGrid.rows(compact: [false, true, true, false]) == [[0], [1, 2], [3]])
    }

    @Test func largeBoxesAlwaysGetTheirOwnRowAndOrderIsKept() {
        #expect(DropDownModuleGrid.rows(compact: [false, false]) == [[0], [1]])
        #expect(DropDownModuleGrid.rows(compact: []).isEmpty)
        let rows = DropDownModuleGrid.rows(compact: [true, true, false, true, true, true])
        #expect(rows.flatMap { $0 } == [0, 1, 2, 3, 4, 5])
        #expect(rows.allSatisfy { $0.count <= 2 })
    }
}
