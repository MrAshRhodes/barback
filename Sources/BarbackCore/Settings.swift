import Foundation

/// User preferences. Defaults are chosen so a fresh install is useful without visiting Settings.
public struct BarbackSettings: Equatable, Codable, Sendable {
    /// Seconds before hidden items are hidden again after being shown; 0 = never.
    public var autoRehideSeconds: Int
    /// Global toggle shortcut; nil = disabled.
    public var hotkey: KeyCombo?
    /// Reveal hidden items when the pointer enters the menu bar's status area.
    public var showOnHover: Bool
    /// Adds a second separator whose items stay hidden until explicitly revealed.
    public var alwaysHiddenEnabled: Bool
    /// Hide revealed items again as soon as another app becomes active.
    public var rehideOnAppSwitch: Bool
    /// Toggle icon, separator and divider styles.
    public var appearance: AppearanceSettings
    /// What clicking the Barback icon does (the hotkey follows it).
    public var clickAction: ClickAction
    /// List or grid inside the drop-down panel's boxes.
    public var dropDownLayout: DropDownLayout
    /// The drop-down panel's group boxes, in display order. Empty until the user makes some.
    public var groups: [ItemGroup]
    /// Global shortcuts that open one item each. Empty unless the user sets some.
    public var itemHotkeys: [ItemHotkey]
    public var notchOverflowEnabled: Bool
    public var profiles: [VisibilityProfile]
    public var activeProfileID: UUID?
    public var baseVisibility: ProfileVisibility

    public init(
        autoRehideSeconds: Int = 10,
        hotkey: KeyCombo? = .defaultToggle,
        showOnHover: Bool = false,
        alwaysHiddenEnabled: Bool = false,
        rehideOnAppSwitch: Bool = false,
        appearance: AppearanceSettings = .default,
        clickAction: ClickAction = .default,
        dropDownLayout: DropDownLayout = .default,
        groups: [ItemGroup] = [],
        itemHotkeys: [ItemHotkey] = [],
        notchOverflowEnabled: Bool = false,
        profiles: [VisibilityProfile] = [],
        activeProfileID: UUID? = nil,
        baseVisibility: ProfileVisibility = .hidden
    ) {
        self.autoRehideSeconds = autoRehideSeconds
        self.hotkey = hotkey
        self.showOnHover = showOnHover
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        self.rehideOnAppSwitch = rehideOnAppSwitch
        self.appearance = appearance
        self.clickAction = clickAction
        self.dropDownLayout = dropDownLayout
        self.groups = groups
        self.itemHotkeys = itemHotkeys
        self.notchOverflowEnabled = notchOverflowEnabled
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.baseVisibility = baseVisibility
    }

    private enum CodingKeys: String, CodingKey {
        case autoRehideSeconds, hotkey, showOnHover, alwaysHiddenEnabled, rehideOnAppSwitch, appearance
        case clickAction, dropDownLayout, groups, itemHotkeys
        case notchOverflowEnabled, profiles, activeProfileID, baseVisibility
    }

    /// Missing keys (for example `itemHotkeys` in data from an older version) keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BarbackSettings.default
        // `contains` + `decode` rather than `decodeIfPresent`, which can drop the key from error coding paths.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            c.contains(key) ? try c.decode(T.self, forKey: key) : fallback
        }
        autoRehideSeconds = try value(.autoRehideSeconds, d.autoRehideSeconds)
        // As with synthesized Codable, a missing or null shortcut means none (encoding leaves nil out).
        if c.contains(.hotkey), try !c.decodeNil(forKey: .hotkey) {
            hotkey = try c.decode(KeyCombo.self, forKey: .hotkey)
        } else {
            hotkey = nil
        }
        showOnHover = try value(.showOnHover, d.showOnHover)
        alwaysHiddenEnabled = try value(.alwaysHiddenEnabled, d.alwaysHiddenEnabled)
        rehideOnAppSwitch = try value(.rehideOnAppSwitch, d.rehideOnAppSwitch)
        appearance = try value(.appearance, d.appearance)
        clickAction = try value(.clickAction, d.clickAction)
        dropDownLayout = try value(.dropDownLayout, d.dropDownLayout)
        groups = try value(.groups, d.groups)
        itemHotkeys = try value(.itemHotkeys, d.itemHotkeys)
        notchOverflowEnabled = try value(.notchOverflowEnabled, d.notchOverflowEnabled)
        profiles = try value(.profiles, d.profiles)
        activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        baseVisibility = try value(.baseVisibility, d.baseVisibility)
    }

    public static let `default` = BarbackSettings()

    /// Choices offered in Settings (seconds). 0 = never.
    public static let autoRehidePresets: [Int] = [0, 5, 10, 15, 30, 60, 120, 300]
    public static let maxAutoRehideSeconds = 3600

    /// Clamps out-of-range values and drops hotkeys that can't be registered globally.
    public func sanitized() -> BarbackSettings {
        var s = self
        s.autoRehideSeconds = min(max(0, autoRehideSeconds), Self.maxAutoRehideSeconds)
        if let hk = hotkey, !hk.isValidGlobalHotkey { s.hotkey = .defaultToggle }
        s.appearance = appearance.sanitized()
        s.groups = ItemGroups.sanitized(groups)
        s.itemHotkeys = HotkeyConflicts.sanitized(itemHotkeys, mainHotkey: s.hotkey)
        s.profiles = VisibilityProfiles.sanitized(profiles)
        if !s.profiles.contains(where: { $0.id == s.activeProfileID }) { s.activeProfileID = nil }
        return s
    }

    /// Human-readable label for a rehide delay, e.g. "Never", "10 seconds", "2 minutes".
    public static func describeRehide(seconds: Int) -> String {
        if seconds <= 0 { return "Never" }
        if seconds % 60 == 0 {
            let m = seconds / 60
            return m == 1 ? "1 minute" : "\(m) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }
}

/// UserDefaults keys. Values are stored individually so `defaults write` stays usable for power users.
public enum SettingsKey: String, CaseIterable, Sendable {
    case autoRehideSeconds
    case hotkey
    case showOnHover
    case alwaysHiddenEnabled
    case rehideOnAppSwitch
    case toggleIcon
    case iconWeight
    case tintWhenShowing
    case hiddenDividerStyle
    case alwaysHiddenDividerStyle
    case extraDividerCount
    case extraDividerStyle
    case clickAction
    case dropDownLayout
    /// The groups as one JSON document.
    case groups
    /// Per-item shortcuts as one JSON document.
    case itemHotkeys
    case notchOverflowEnabled, profiles, activeProfileID, baseVisibility
}

/// Loads and saves `BarbackSettings` in a `UserDefaults` domain.
public struct SettingsStore {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> BarbackSettings {
        var s = BarbackSettings.default
        if defaults.object(forKey: SettingsKey.autoRehideSeconds.rawValue) != nil {
            s.autoRehideSeconds = defaults.integer(forKey: SettingsKey.autoRehideSeconds.rawValue)
        }
        if defaults.object(forKey: SettingsKey.showOnHover.rawValue) != nil {
            s.showOnHover = defaults.bool(forKey: SettingsKey.showOnHover.rawValue)
        }
        if defaults.object(forKey: SettingsKey.alwaysHiddenEnabled.rawValue) != nil {
            s.alwaysHiddenEnabled = defaults.bool(forKey: SettingsKey.alwaysHiddenEnabled.rawValue)
        }
        if let data = defaults.data(forKey: SettingsKey.hotkey.rawValue),
           let decoded = try? JSONDecoder().decode(StoredHotkey.self, from: data) {
            s.hotkey = decoded.combo
        }
        if let v = bool(.rehideOnAppSwitch) { s.rehideOnAppSwitch = v }
        // Enums are stored as strings; unknown values (from a newer or older version) keep the default.
        if let v = value(.toggleIcon, ToggleIconStyle.self) { s.appearance.toggleIcon = v }
        if let v = value(.iconWeight, IconWeight.self) { s.appearance.iconWeight = v }
        if let v = bool(.tintWhenShowing) { s.appearance.tintWhenShowing = v }
        if let v = value(.hiddenDividerStyle, DividerStyle.self) { s.appearance.hiddenDivider = v }
        if let v = value(.alwaysHiddenDividerStyle, DividerStyle.self) { s.appearance.alwaysHiddenDivider = v }
        if defaults.object(forKey: SettingsKey.extraDividerCount.rawValue) != nil {
            s.appearance.extraDividerCount = defaults.integer(forKey: SettingsKey.extraDividerCount.rawValue)
        }
        if let v = value(.extraDividerStyle, DividerStyle.self) { s.appearance.extraDividerStyle = v }
        if let v = value(.clickAction, ClickAction.self) { s.clickAction = v }
        if let v = value(.dropDownLayout, DropDownLayout.self) { s.dropDownLayout = v }
        s.groups = loadGroups()
        s.itemHotkeys = loadItemHotkeys()
        if let v = bool(.notchOverflowEnabled) { s.notchOverflowEnabled = v }
        s.profiles = loadProfiles()
        s.activeProfileID = defaults.string(forKey: SettingsKey.activeProfileID.rawValue).flatMap(UUID.init(uuidString:))
        if let v = value(.baseVisibility, ProfileVisibility.self) { s.baseVisibility = v }
        return s.sanitized()
    }

    /// Corrupt or unreadable group data means no groups, never a crash.
    private func loadGroups() -> [ItemGroup] {
        let key = SettingsKey.groups.rawValue
        // A JSON string (for example from `defaults write`) is accepted as well as the Data we write.
        guard let data = defaults.data(forKey: key) ?? defaults.string(forKey: key)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ItemGroup].self, from: data)) ?? []
    }

    /// Missing or unreadable data means no profiles, never a crash.
    private func loadProfiles() -> [VisibilityProfile] {
        let key = SettingsKey.profiles.rawValue
        guard let data = defaults.data(forKey: key) ?? defaults.string(forKey: key)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([VisibilityProfile].self, from: data)) ?? []
    }

    /// Missing or unreadable data means no item shortcuts, never a crash.
    private func loadItemHotkeys() -> [ItemHotkey] {
        let key = SettingsKey.itemHotkeys.rawValue
        guard let data = defaults.data(forKey: key) ?? defaults.string(forKey: key)?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ItemHotkey].self, from: data)) ?? []
    }

    public func save(_ settings: BarbackSettings) {
        let s = settings.sanitized()
        defaults.set(s.autoRehideSeconds, forKey: SettingsKey.autoRehideSeconds.rawValue)
        defaults.set(s.showOnHover, forKey: SettingsKey.showOnHover.rawValue)
        defaults.set(s.alwaysHiddenEnabled, forKey: SettingsKey.alwaysHiddenEnabled.rawValue)
        if let data = try? JSONEncoder().encode(StoredHotkey(combo: s.hotkey)) {
            defaults.set(data, forKey: SettingsKey.hotkey.rawValue)
        }
        defaults.set(s.rehideOnAppSwitch, forKey: SettingsKey.rehideOnAppSwitch.rawValue)
        let a = s.appearance
        defaults.set(a.toggleIcon.rawValue, forKey: SettingsKey.toggleIcon.rawValue)
        defaults.set(a.iconWeight.rawValue, forKey: SettingsKey.iconWeight.rawValue)
        defaults.set(a.tintWhenShowing, forKey: SettingsKey.tintWhenShowing.rawValue)
        defaults.set(a.hiddenDivider.rawValue, forKey: SettingsKey.hiddenDividerStyle.rawValue)
        defaults.set(a.alwaysHiddenDivider.rawValue, forKey: SettingsKey.alwaysHiddenDividerStyle.rawValue)
        defaults.set(a.extraDividerCount, forKey: SettingsKey.extraDividerCount.rawValue)
        defaults.set(a.extraDividerStyle.rawValue, forKey: SettingsKey.extraDividerStyle.rawValue)
        defaults.set(s.clickAction.rawValue, forKey: SettingsKey.clickAction.rawValue)
        defaults.set(s.dropDownLayout.rawValue, forKey: SettingsKey.dropDownLayout.rawValue)
        defaults.set(s.notchOverflowEnabled, forKey: SettingsKey.notchOverflowEnabled.rawValue)
        defaults.set(s.activeProfileID?.uuidString, forKey: SettingsKey.activeProfileID.rawValue)
        defaults.set(s.baseVisibility.rawValue, forKey: SettingsKey.baseVisibility.rawValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if s.profiles.isEmpty {
            defaults.removeObject(forKey: SettingsKey.profiles.rawValue)
        } else if let data = try? encoder.encode(s.profiles) {
            defaults.set(data, forKey: SettingsKey.profiles.rawValue)
        }
        if s.groups.isEmpty {
            defaults.removeObject(forKey: SettingsKey.groups.rawValue)
        } else if let data = try? encoder.encode(s.groups) {
            defaults.set(data, forKey: SettingsKey.groups.rawValue)
        }
        if s.itemHotkeys.isEmpty {
            defaults.removeObject(forKey: SettingsKey.itemHotkeys.rawValue)
        } else if let data = try? encoder.encode(s.itemHotkeys) {
            defaults.set(data, forKey: SettingsKey.itemHotkeys.rawValue)
        }
    }

    private func bool(_ key: SettingsKey) -> Bool? {
        defaults.object(forKey: key.rawValue) != nil ? defaults.bool(forKey: key.rawValue) : nil
    }

    private func value<T: RawRepresentable>(_ key: SettingsKey, _: T.Type) -> T? where T.RawValue == String {
        defaults.string(forKey: key.rawValue).flatMap(T.init(rawValue:))
    }

    public func reset() {
        for key in SettingsKey.allCases { defaults.removeObject(forKey: key.rawValue) }
    }

    /// Wrapper so "no hotkey" (user cleared it) is distinguishable from "never set" (missing key → default).
    private struct StoredHotkey: Codable {
        var combo: KeyCombo?
    }
}
