import Foundation

public enum ProfileVisibility: String, CaseIterable, Codable, Sendable {
    case hidden, shown, shownAll

    public init(_ state: SectionState) {
        switch state {
        case .hidden: self = .hidden
        case .shown: self = .shown
        case .shownAll: self = .shownAll
        }
    }

    public var title: String {
        switch self {
        case .hidden: return "Hide sections"
        case .shown: return "Show hidden section"
        case .shownAll: return "Show all sections"
        }
    }
}

public enum ProfileDisplayCondition: String, CaseIterable, Codable, Sendable {
    case any, builtInOnly, externalPresent, externalOnly

    public var title: String {
        switch self {
        case .any: return "Any displays"
        case .builtInOnly: return "Built-in display only"
        case .externalPresent: return "External display connected"
        case .externalOnly: return "External displays only"
        }
    }
}

public struct ProfileContext: Equatable, Sendable {
    public var frontmostBundleID: String?
    public var builtInDisplayCount: Int
    public var externalDisplayCount: Int
    public var displayIDs: [UInt32]

    public init(
        frontmostBundleID: String?, builtInDisplayCount: Int, externalDisplayCount: Int,
        displayIDs: [UInt32] = []
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.builtInDisplayCount = builtInDisplayCount
        self.externalDisplayCount = externalDisplayCount
        self.displayIDs = displayIDs.sorted()
    }
}

public struct VisibilityProfile: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var visibility: ProfileVisibility
    /// Filters configured panel memberships, never the physical menu bar or the base configuration.
    public var excludedPanelItems: [ItemKey]
    public var automatic: Bool
    public var appBundleID: String
    public var displayCondition: ProfileDisplayCondition
    public var displayCount: Int?

    public init(
        id: UUID = UUID(), name: String, visibility: ProfileVisibility = .hidden,
        excludedPanelItems: [ItemKey] = [], automatic: Bool = false, appBundleID: String = "",
        displayCondition: ProfileDisplayCondition = .any, displayCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.visibility = visibility
        self.excludedPanelItems = excludedPanelItems
        self.automatic = automatic
        self.appBundleID = appBundleID
        self.displayCondition = displayCondition
        self.displayCount = displayCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, visibility, excludedPanelItems, automatic, appBundleID, displayCondition, displayCount
    }

    /// Fields missing from older or hand-edited data keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        visibility = try c.decodeIfPresent(ProfileVisibility.self, forKey: .visibility) ?? .hidden
        excludedPanelItems = try c.decodeIfPresent([ItemKey].self, forKey: .excludedPanelItems) ?? []
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
        displayCondition = try c.decodeIfPresent(ProfileDisplayCondition.self, forKey: .displayCondition) ?? .any
        displayCount = try c.decodeIfPresent(Int.self, forKey: .displayCount)
    }

    public func matches(_ context: ProfileContext) -> Bool {
        guard automatic, !appBundleID.isEmpty || displayCondition != .any || displayCount != nil else { return false }
        guard appBundleID.isEmpty || context.frontmostBundleID == appBundleID else { return false }
        let total = context.builtInDisplayCount + context.externalDisplayCount
        guard displayCount == nil || displayCount == total else { return false }
        switch displayCondition {
        case .any: return true
        case .builtInOnly: return context.builtInDisplayCount > 0 && context.externalDisplayCount == 0
        case .externalPresent: return context.externalDisplayCount > 0
        case .externalOnly: return context.externalDisplayCount > 0 && context.builtInDisplayCount == 0
        }
    }
}

public enum VisibilityProfiles {
    public static let maxProfiles = 24

    /// App-specific rules precede display-only rules; array order breaks ties.
    public static func match(in profiles: [VisibilityProfile], context: ProfileContext) -> UUID? {
        profiles.first { !$0.appBundleID.isEmpty && $0.matches(context) }?.id
            ?? profiles.first { $0.matches(context) }?.id
    }

    public static func groups(_ groups: [ItemGroup], applying profile: VisibilityProfile?) -> [ItemGroup] {
        guard let profile else { return groups }
        let excluded = Set(profile.excludedPanelItems)
        return groups.map { group in
            var result = group
            result.itemKeys.removeAll { excluded.contains($0) }
            return result
        }
    }

    public static func sanitized(_ profiles: [VisibilityProfile]) -> [VisibilityProfile] {
        var ids = Set<UUID>()
        var cleaned: [VisibilityProfile] = []
        for profile in profiles {
            guard cleaned.count < maxProfiles else { break }
            guard ids.insert(profile.id).inserted else { continue }
            var result = profile
            result.name = ItemGroups.sanitizedName(profile.name) ?? "Profile"
            result.appBundleID = String(profile.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
            if let count = profile.displayCount { result.displayCount = min(max(count, 1), 32) }
            var keys = Set<ItemKey>()
            result.excludedPanelItems = profile.excludedPanelItems.prefix(ItemGroups.maxGroups * ItemGroups.maxKeysPerGroup)
                .filter { !$0.owner.isEmpty && keys.insert($0).inserted }
            cleaned.append(result)
        }
        return cleaned
    }
}
