import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Panel configuration")
struct PanelConfigurationTests {
    @Test func oldGroupsKeepTheirMembershipAndInheritTheGlobalLayout() throws {
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"Work","itemKeys":[{"owner":"com.example.work"}]}]
        """
        let groups = try JSONDecoder().decode([ItemGroup].self, from: Data(json.utf8))

        #expect(groups.count == 1)
        #expect(groups[0].id == id)
        #expect(groups[0].layout == nil)
        #expect(groups[0].symbol == ItemGroups.defaultSymbol)
        #expect(groups[0].itemKeys == [ItemKey(owner: "com.example.work")])
    }

    @Test func unknownLayoutsDoNotDiscardAnyGroupsOrMemberships() throws {
        let ids = [UUID(), UUID()]
        let json = """
        [
          {"id":"\(ids[0])","name":"Work","layout":"carousel","itemKeys":[{"owner":"com.example.work","ordinal":3}]},
          {"id":"\(ids[1])","name":"Play","layout":"grid","itemKeys":[{"owner":"com.example.play"}]}
        ]
        """
        let groups = try JSONDecoder().decode([ItemGroup].self, from: Data(json.utf8))

        #expect(groups.map(\.id) == ids)
        #expect(groups.map(\.layout) == [nil, .grid])
        #expect(groups[0].itemKeys == [ItemKey(owner: "com.example.work", ordinal: 3)])
        #expect(groups[1].itemKeys == [ItemKey(owner: "com.example.play")])
    }

    @Test func eachPanelKeepsItsOwnLayoutThroughARoundTrip() throws {
        let work = ItemGroup(name: "Work", itemKeys: [ItemKey(owner: "com.example.work")])
        let play = ItemGroup(name: "Play", layout: .grid)
        var groups = [work, play]

        #expect(ItemGroups.setLayout(.list, for: work.id, in: &groups))
        #expect(!ItemGroups.setLayout(.grid, for: UUID(), in: &groups))
        let decoded = try JSONDecoder().decode([ItemGroup].self, from: JSONEncoder().encode(groups))

        #expect(decoded.map(\.layout) == [.list, .grid])
        #expect(decoded[0].itemKeys == work.itemKeys)
        #expect(decoded == groups)
    }

    @Test func movingItemsPersistsTheOrderAndStopsAtBothEnds() throws {
        let a = ItemKey(owner: "com.example.a")
        let b = ItemKey(owner: "com.example.b")
        let c = ItemKey(owner: "com.example.c")
        let panel = ItemGroup(name: "Work", itemKeys: [a, b, c])
        var groups = [panel]

        #expect(ItemGroups.moveItem(c, in: panel.id, by: -1, groups: &groups))
        #expect(groups[0].itemKeys == [a, c, b])
        #expect(ItemGroups.moveItem(c, in: panel.id, by: Int.min, groups: &groups))
        #expect(groups[0].itemKeys == [c, a, b])
        #expect(!ItemGroups.moveItem(c, in: panel.id, by: -1, groups: &groups))
        #expect(ItemGroups.moveItem(c, in: panel.id, by: Int.max, groups: &groups))
        #expect(groups[0].itemKeys == [a, b, c])
        #expect(!ItemGroups.moveItem(c, in: panel.id, by: 1, groups: &groups))
        #expect(!ItemGroups.moveItem(c, in: panel.id, by: 0, groups: &groups))
        #expect(!ItemGroups.moveItem(c, in: UUID(), by: -1, groups: &groups))
        #expect(!ItemGroups.moveItem(ItemKey(owner: "missing"), in: panel.id, by: -1, groups: &groups))
        #expect(ItemGroups.moveItem(b, in: panel.id, by: -1, groups: &groups))

        let decoded = try JSONDecoder().decode([ItemGroup].self, from: JSONEncoder().encode(groups))
        #expect(decoded == groups)
        #expect(decoded[0].itemKeys == [b, a, c])
    }

    @Test func panelKeysRequireAnIdentifiedOwnerAndANamedSystemItem() {
        let items = [
            item(1, owner: "Control Center"),
            item(2, owner: "Control Center", title: "A window title"),
            item(3, owner: "Unknown"),
            item(4, owner: "Control Center", bundleID: "com.apple.controlcenter"),
            item(5, owner: "Control Center", bundleID: "com.example.work"),
            item(6, owner: "Control Center", bundleID: "com.apple.controlcenter", detail: "Wi-Fi"),
        ]
        let keys = ItemKeyAssigner.panelKeys(for: items)

        #expect(Set(keys.keys) == [5, 6])
        #expect(keys[5] == ItemKey(owner: "com.example.work"))
        #expect(keys[6] == ItemKey(owner: "com.apple.controlcenter", detail: "Wi-Fi"))
    }

    @Test func ambiguousItemsCannotAcquireNewAssignmentsWhenTheyReorder() {
        let a = item(1, bundleID: "com.example.work", detail: "Status", x: 100)
        let b = item(2, bundleID: "com.example.work", detail: "Status", x: 200)
        let distinct = item(3, bundleID: "com.example.other")
        var movedA = a
        movedA.frame.origin.x = 300

        #expect(ItemKeyAssigner.panelKeys(for: [a, b, distinct]) == [3: ItemKey(owner: "com.example.other")])
        #expect(ItemKeyAssigner.panelKeys(for: [b, distinct, movedA]) == [3: ItemKey(owner: "com.example.other")])
    }

    @Test func accessibilityNamingOneSiblingDoesNotAttachTheOthersOldOrdinal() {
        let a = item(1, bundleID: "com.example.work", x: 100)
        let b = item(2, bundleID: "com.example.work", x: 200)
        let savedFirstKey = ItemKeyAssigner.keys(for: [a, b])[a.id]!
        var namedA = a
        namedA.detail = "First account"
        let keys = ItemKeyAssigner.panelKeys(for: [namedA, b])

        #expect(!keys.values.contains(savedFirstKey))
        #expect(keys[b.id] == nil)
        #expect(keys[a.id] == ItemKey(owner: "com.example.work", detail: "First account"))
    }

    @Test func displayCopiesShareOneIdentityButAmbiguityOnAnyDisplayRejectsAllCopies() {
        let displays = [
            MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
            MenuBarDisplay(frame: CGRect(x: 0, y: 900, width: 1440, height: 900)),
        ]
        let primary = item(1, bundleID: "com.example.work")
        let secondary = item(2, bundleID: "com.example.work", y: 900)
        let keys = ItemKeyAssigner.panelKeys(for: [primary, secondary], displays: displays)

        #expect(keys.count == 2)
        #expect(Set(keys.values) == [ItemKey(owner: "com.example.work")])
        #expect(ItemKeyAssigner.panelKeys(for: [secondary, primary], displays: displays) == keys)
        #expect(ItemKeyAssigner.panelKeys(for: [primary, secondary]).isEmpty, "unknown displays cannot prove mirroring")

        let duplicate = item(3, bundleID: "com.example.work", x: 200)
        #expect(ItemKeyAssigner.panelKeys(for: [primary, secondary, duplicate], displays: displays).isEmpty)
    }

    @Test func hostedPermissionTransitionsNeverMatchSavedUnresolvedOrdinals() throws {
        let raw = [
            item(1, owner: "Control Center", x: 100),
            item(2, owner: "Control Center", x: 200),
        ]
        let rawKeys = ItemKeyAssigner.keys(for: raw)
        let group = ItemGroup(name: "Saved panel", itemKeys: [rawKeys[1]!, rawKeys[2]!])
        let saved = try JSONEncoder().encode([group])
        let resolved = MenuBarItemParser.resolve(raw, using: [
            AccessibilityItem(appName: "Work", bundleID: "com.example.work", pid: 101, frame: raw[0].frame),
            AccessibilityItem(appName: "Play", bundleID: "com.example.play", pid: 102, frame: raw[1].frame),
        ])
        var reordered = resolved.reversed().map { $0 }
        reordered[0].frame.origin.x = 100
        reordered[1].frame.origin.x = 200
        let afterGrant = ItemKeyAssigner.panelKeys(for: reordered)

        #expect(afterGrant.count == 2)
        #expect(group.itemKeys.allSatisfy { !afterGrant.values.contains($0) })
        #expect(ItemKeyAssigner.panelKeys(for: Array(raw.reversed())).isEmpty)
        #expect(try JSONDecoder().decode([ItemGroup].self, from: saved) == [group])
    }

    private func item(
        _ id: UInt32,
        owner: String = "Work",
        bundleID: String? = nil,
        detail: String? = nil,
        title: String? = nil,
        x: CGFloat = 100,
        y: CGFloat = 0
    ) -> MenuBarItem {
        MenuBarItem(
            windowID: id,
            ownerName: owner,
            ownerPID: 10,
            title: title,
            frame: CGRect(x: x, y: y, width: 24, height: 24),
            isOnScreen: true,
            bundleID: bundleID,
            detail: detail
        )
    }
}
