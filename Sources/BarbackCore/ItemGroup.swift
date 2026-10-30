import Foundation

/// A user-defined box in the drop-down panel, e.g. "Work" or "Gaming".
public struct ItemGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol shown next to the name.
    public var symbol: String
    /// The items in this group; an item belongs to at most one group.
    public var itemKeys: [ItemKey]
    /// An override for this panel; nil inherits the global layout.
    public var layout: DropDownLayout?

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = ItemGroups.defaultSymbol,
        itemKeys: [ItemKey] = [],
        layout: DropDownLayout? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.itemKeys = itemKeys
        self.layout = layout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ItemGroups.defaultSymbol
        itemKeys = try c.decodeIfPresent([ItemKey].self, forKey: .itemKeys) ?? []
        // A layout from a newer version must not make the entire saved group list unreadable.
        layout = try? c.decodeIfPresent(DropDownLayout.self, forKey: .layout)
    }
}

/// One box of the panel: a group and the items assigned to it, or the ungrouped rest (`group == nil`).
public struct ItemPartition<Item> {
    public var group: ItemGroup?
    public var items: [Item]

    public init(group: ItemGroup?, items: [Item]) {
        self.group = group
        self.items = items
    }
}

extension ItemPartition: Equatable where Item: Equatable {}
extension ItemPartition: Sendable where Item: Sendable {}

/// Pure operations on the user's list of groups.
public enum ItemGroups {
    public static let maxGroups = 12
    public static let maxNameLength = 24
    public static let maxKeysPerGroup = 256
    public static let defaultSymbol = "folder"
    public static let defaultName = "Group"

    /// Symbols offered in Settings; all exist in SF Symbols 5 (macOS 14).
    public static let symbolPalette: [String] = [
        "folder", "briefcase", "gamecontroller", "music.note", "play.rectangle", "bubble.left.and.bubble.right",
        "wrench.and.screwdriver", "network", "lock.shield", "camera", "house", "star",
    ]

    /// Quick-add suggestions with a fitting symbol each.
    public static let suggestions: [(name: String, symbol: String)] = [
        ("Work", "briefcase"),
        ("Gaming", "gamecontroller"),
        ("Media", "play.rectangle"),
        ("Social", "bubble.left.and.bubble.right"),
        ("Utilities", "wrench.and.screwdriver"),
    ]

    // MARK: - Names and symbols

    /// Trims, collapses whitespace, drops control characters and limits the length; nil if nothing is left.
    public static func sanitizedName(_ raw: String) -> String? {
        let words = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let name = String(words.joined(separator: " ").prefix(maxNameLength))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// `name`, or `name 2`, `name 3`… when another group already uses it (case-insensitively).
    public static func uniqueName(_ name: String, in groups: [ItemGroup], excluding id: UUID? = nil) -> String {
        let taken = Set(groups.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while true {
            let suffix = " \(n)"
            let candidate = String(name.prefix(maxNameLength - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    /// Accepts SF Symbol-looking names only (letters, digits, dots, dashes, underscores).
    public static func sanitizedSymbol(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !trimmed.isEmpty, trimmed.count <= 64, trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            return defaultSymbol
        }
        return trimmed
    }

    // MARK: - Editing

    /// Adds a group; nil when the list is full. An unusable name becomes "Group"; a taken one gets a number.
    @discardableResult
    public static func add(name: String, symbol: String = defaultSymbol, to groups: inout [ItemGroup]) -> UUID? {
        guard groups.count < maxGroups else { return nil }
        let unique = uniqueName(sanitizedName(name) ?? defaultName, in: groups)
        let group = ItemGroup(name: unique, symbol: sanitizedSymbol(symbol))
        groups.append(group)
        return group.id
    }

    @discardableResult
    public static func rename(_ id: UUID, to name: String, in groups: inout [ItemGroup]) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }), let clean = sanitizedName(name) else { return false }
        groups[index].name = uniqueName(clean, in: groups, excluding: id)
        return true
    }

    @discardableResult
    public static func setSymbol(_ symbol: String, for id: UUID, in groups: inout [ItemGroup]) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].symbol = sanitizedSymbol(symbol)
        return true
    }

    @discardableResult
    public static func setLayout(_ layout: DropDownLayout, for id: UUID, in groups: inout [ItemGroup]) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[index].layout = layout
        return true
    }

    /// Moves an assigned item within its panel, clamping to either end without changing memberships.
    @discardableResult
    public static func moveItem(_ key: ItemKey, in id: UUID, by offset: Int, groups: inout [ItemGroup]) -> Bool {
        guard let groupIndex = groups.firstIndex(where: { $0.id == id }),
              let index = groups[groupIndex].itemKeys.firstIndex(of: key) else { return false }
        let distance = min(max(-index, offset), groups[groupIndex].itemKeys.count - 1 - index)
        guard distance != 0 else { return false }
        let item = groups[groupIndex].itemKeys.remove(at: index)
        groups[groupIndex].itemKeys.insert(item, at: index + distance)
        return true
    }

    /// Deletes a group; its items become ungrouped.
    @discardableResult
    public static func remove(_ id: UUID, from groups: inout [ItemGroup]) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups.remove(at: index)
        return true
    }

    /// Moves a group by `offset` places (negative = earlier), stopping at the ends.
    @discardableResult
    public static func move(_ id: UUID, by offset: Int, in groups: inout [ItemGroup]) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(0, index + offset), groups.count - 1)
        guard target != index else { return false }
        groups.insert(groups.remove(at: index), at: target)
        return true
    }

    /// Puts `key` in the group `id`, or ungroups it when `id` is nil. The key leaves any other group first.
    /// Returns false when the group doesn't exist or is full.
    @discardableResult
    public static func assign(_ key: ItemKey, to id: UUID?, in groups: inout [ItemGroup]) -> Bool {
        if let id {
            guard let target = groups.firstIndex(where: { $0.id == id }) else { return false }
            if groups[target].itemKeys.contains(key) { return true }
            guard groups[target].itemKeys.count < maxKeysPerGroup else { return false }
        }
        for index in groups.indices { groups[index].itemKeys.removeAll { $0 == key } }
        if let id, let target = groups.firstIndex(where: { $0.id == id }) {
            groups[target].itemKeys.append(key)
        }
        return true
    }

    public static func groupID(for key: ItemKey, in groups: [ItemGroup]) -> UUID? {
        groups.first { $0.itemKeys.contains(key) }?.id
    }

    /// Repairs a decoded list: drops duplicate ids and everything past the limit, fixes names and symbols, and
    /// keeps each item key in the first group that lists it. Applying it twice changes nothing more.
    public static func sanitized(_ groups: [ItemGroup]) -> [ItemGroup] {
        var result: [ItemGroup] = []
        var ids = Set<UUID>()
        var assigned = Set<ItemKey>()
        for var group in groups {
            guard result.count < maxGroups, ids.insert(group.id).inserted else { continue }
            group.name = uniqueName(sanitizedName(group.name) ?? defaultName, in: result)
            group.symbol = sanitizedSymbol(group.symbol)
            var keys: [ItemKey] = []
            for key in group.itemKeys where keys.count < maxKeysPerGroup {
                let owner = key.owner.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !owner.isEmpty, assigned.insert(key).inserted else { continue }
                keys.append(key)
            }
            group.itemKeys = keys
            result.append(group)
        }
        return result
    }

    // MARK: - Partitioning

    /// Splits `items` into one box per group, in the user's group order, then the ungrouped rest. Items keep
    /// their input order inside each box. Empty groups are left out unless `includeEmptyGroups`; the
    /// ungrouped box only appears when something is in it.
    public static func partition<Item>(
        _ items: [Item],
        groups: [ItemGroup],
        includeEmptyGroups: Bool = false,
        key: (Item) -> ItemKey
    ) -> [ItemPartition<Item>] {
        var groupIndex: [ItemKey: Int] = [:]
        for (index, group) in groups.enumerated() {
            for itemKey in group.itemKeys where groupIndex[itemKey] == nil { groupIndex[itemKey] = index }
        }
        var buckets = [[Item]](repeating: [], count: groups.count)
        var rest: [Item] = []
        for item in items {
            if let index = groupIndex[key(item)] { buckets[index].append(item) } else { rest.append(item) }
        }
        var result: [ItemPartition<Item>] = []
        for (index, group) in groups.enumerated() where includeEmptyGroups || !buckets[index].isEmpty {
            result.append(ItemPartition(group: group, items: buckets[index]))
        }
        if !rest.isEmpty { result.append(ItemPartition(group: nil, items: rest)) }
        return result
    }
}
