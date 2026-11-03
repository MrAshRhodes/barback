import Foundation

/// A global shortcut that opens one menu bar item's own menu.
public struct ItemHotkey: Hashable, Codable, Sendable {
    public var key: ItemKey
    public var combo: KeyCombo
    /// The item's name when the shortcut was set, so Settings can list it while the item isn't in the menu bar.
    public var title: String?

    public init(key: ItemKey, combo: KeyCombo, title: String? = nil) {
        self.key = key
        self.combo = combo
        self.title = title
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return key.detail ?? key.owner
    }
}

/// What a global shortcut does. `named` leaves room for other app-wide shortcuts (e.g. a search shortcut).
public enum HotkeyTarget: Hashable, Sendable {
    /// The main show/hide (or panel) shortcut.
    case main
    case item(ItemKey)
    case named(String)
}

public struct HotkeyAssignment: Hashable, Sendable {
    public var target: HotkeyTarget
    public var combo: KeyCombo

    public init(target: HotkeyTarget, combo: KeyCombo) {
        self.target = target
        self.combo = combo
    }
}

/// Pure duplicate detection for global shortcuts: one key combination can only do one thing.
public enum HotkeyConflicts {
    /// The other target already using `combo`, if any. Reassigning a target's own shortcut is not a conflict.
    public static func conflict(
        for combo: KeyCombo,
        target: HotkeyTarget,
        in assignments: [HotkeyAssignment]
    ) -> HotkeyTarget? {
        assignments.first { $0.combo == combo && $0.target != target }?.target
    }

    /// Key combinations used by more than one target, with those targets in order.
    public static func duplicates(in assignments: [HotkeyAssignment]) -> [KeyCombo: [HotkeyTarget]] {
        var byCombo: [KeyCombo: [HotkeyTarget]] = [:]
        for a in assignments where byCombo[a.combo]?.contains(a.target) != true {
            byCombo[a.combo, default: []].append(a.target)
        }
        return byCombo.filter { $0.value.count > 1 }
    }

    /// Valid shortcuts only, one per item and none reusing the main shortcut or an earlier item's.
    public static func sanitized(_ hotkeys: [ItemHotkey], mainHotkey: KeyCombo?) -> [ItemHotkey] {
        var keys = Set<ItemKey>()
        var combos = Set<KeyCombo>()
        if let mainHotkey { combos.insert(mainHotkey) }
        return hotkeys.filter {
            guard $0.combo.isValidGlobalHotkey, !keys.contains($0.key), !combos.contains($0.combo) else { return false }
            keys.insert($0.key)
            combos.insert($0.combo)
            return true
        }
    }
}

extension BarbackSettings {
    /// Every global shortcut these settings register, main shortcut first.
    public var hotkeyAssignments: [HotkeyAssignment] {
        var result: [HotkeyAssignment] = []
        if let hotkey { result.append(HotkeyAssignment(target: .main, combo: hotkey)) }
        result += itemHotkeys.map { HotkeyAssignment(target: .item($0.key), combo: $0.combo) }
        return result
    }

    public func itemHotkey(for key: ItemKey) -> ItemHotkey? {
        itemHotkeys.first { $0.key == key }
    }

    /// Sets or (with nil) clears an item's shortcut. Returns the conflicting target instead of changing anything
    /// when the combination is already used.
    @discardableResult
    public mutating func setItemHotkey(_ combo: KeyCombo?, for key: ItemKey, title: String?) -> HotkeyTarget? {
        guard let combo else {
            itemHotkeys.removeAll { $0.key == key }
            return nil
        }
        if let other = HotkeyConflicts.conflict(for: combo, target: .item(key), in: hotkeyAssignments) { return other }
        let hotkey = ItemHotkey(key: key, combo: combo, title: title)
        if let index = itemHotkeys.firstIndex(where: { $0.key == key }) {
            itemHotkeys[index] = hotkey
        } else {
            itemHotkeys.append(hotkey)
        }
        return nil
    }
}
