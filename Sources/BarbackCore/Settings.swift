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

    public init(
        autoRehideSeconds: Int = 10,
        hotkey: KeyCombo? = .defaultToggle,
        showOnHover: Bool = false,
        alwaysHiddenEnabled: Bool = false,
        rehideOnAppSwitch: Bool = false,
        appearance: AppearanceSettings = .default
    ) {
        self.autoRehideSeconds = autoRehideSeconds
        self.hotkey = hotkey
        self.showOnHover = showOnHover
        self.alwaysHiddenEnabled = alwaysHiddenEnabled
        self.rehideOnAppSwitch = rehideOnAppSwitch
        self.appearance = appearance
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
        return s.sanitized()
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
