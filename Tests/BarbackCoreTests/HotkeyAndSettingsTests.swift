import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Hotkey")
struct HotkeyTests {
    @Test func defaultToggleDisplaysAsControlOptionCommandB() {
        #expect(KeyCombo.defaultToggle.displayString == "⌃⌥⌘B")
        #expect(KeyCombo.defaultToggle.accessibilityDescription == "Control-Option-Command-B")
    }

    @Test func modifierSymbolsFollowMacOSOrder() {
        let all: HotkeyModifiers = [.command, .shift, .option, .control]
        #expect(all.symbols == "⌃⌥⇧⌘")
        #expect(HotkeyModifiers().symbols == "")
    }

    @Test func carbonRawValuesMatchHIToolbox() {
        #expect(HotkeyModifiers.command.rawValue == 256)
        #expect(HotkeyModifiers.shift.rawValue == 512)
        #expect(HotkeyModifiers.option.rawValue == 2048)
        #expect(HotkeyModifiers.control.rawValue == 4096)
        #expect(KeyCombo.defaultToggle.modifiers.rawValue == 256 | 2048 | 4096)
    }

    @Test func cocoaFlagsRoundTripAndIgnoreCapsLockAndFn() {
        let capsLock: UInt = 1 << 16
        let function: UInt = 1 << 23
        let flags = HotkeyModifiers.cocoaCommand | HotkeyModifiers.cocoaShift | capsLock | function
        let m = HotkeyModifiers(cocoaFlags: flags)
        #expect(m == [.command, .shift])
        #expect(m.cocoaFlags == HotkeyModifiers.cocoaCommand | HotkeyModifiers.cocoaShift)
        #expect(HotkeyModifiers(cocoaFlags: 0).isEmpty)
    }

    @Test func specialAndUnknownKeyNames() {
        #expect(KeyCombo(keyCode: 49, modifiers: [.option]).displayString == "⌥Space")
        #expect(KeyCombo(keyCode: 122, modifiers: []).displayString == "F1")
        #expect(KeyCombo(keyCode: 126, modifiers: [.command]).accessibilityDescription == "Command-Up Arrow")
        #expect(KeyCodes.name(for: 999) == "Key 999")
    }

    @Test func globalHotkeyValidity() {
        #expect(KeyCombo.defaultToggle.isValidGlobalHotkey)
        #expect(!KeyCombo(keyCode: 11, modifiers: []).isValidGlobalHotkey)
        #expect(!KeyCombo(keyCode: 11, modifiers: [.shift]).isValidGlobalHotkey)
        #expect(KeyCombo(keyCode: 96, modifiers: []).isValidGlobalHotkey, "bare F5 is allowed")
        #expect(!KeyCombo(keyCode: 55, modifiers: [.command]).isValidGlobalHotkey, "modifier key alone")
    }

    @Test func menuKeyEquivalentOnlyForCharacterKeys() {
        #expect(KeyCombo.defaultToggle.menuKeyEquivalent == "b")
        #expect(KeyCombo(keyCode: 123, modifiers: [.command]).menuKeyEquivalent == nil)
    }

    @Test func keyComboCodableRoundTrip() throws {
        let combo = KeyCombo(keyCode: 40, modifiers: [.control, .shift])
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }
}

@Suite("Settings")
struct SettingsTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "barback.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func defaultsAreSensible() {
        let s = BarbackSettings.default
        #expect(s.autoRehideSeconds == 10)
        #expect(s.hotkey == .defaultToggle)
        #expect(!s.showOnHover)
        #expect(!s.alwaysHiddenEnabled)
    }

    @Test func emptyStoreLoadsDefaults() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: d).load() == .default)
    }

    @Test func saveLoadRoundTripIncludingClearedHotkey() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        let custom = BarbackSettings(autoRehideSeconds: 0, hotkey: nil, showOnHover: true, alwaysHiddenEnabled: true)
        store.save(custom)
        #expect(store.load() == custom, "a cleared hotkey must stay cleared, not fall back to the default")
        store.reset()
        #expect(store.load() == .default)
    }

    @Test func corruptHotkeyDataFallsBackToDefault() {
        let (d, suite) = freshDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data("not json".utf8), forKey: SettingsKey.hotkey.rawValue)
        d.set(-50, forKey: SettingsKey.autoRehideSeconds.rawValue)
        let s = SettingsStore(defaults: d).load()
        #expect(s.hotkey == .defaultToggle)
        #expect(s.autoRehideSeconds == 0, "negative delays clamp to never")
    }

    @Test func sanitizeClampsAndRejectsUnusableHotkey() {
        let s = BarbackSettings(autoRehideSeconds: 99_999, hotkey: KeyCombo(keyCode: 0, modifiers: [])).sanitized()
        #expect(s.autoRehideSeconds == BarbackSettings.maxAutoRehideSeconds)
        #expect(s.hotkey == .defaultToggle)
    }

    @Test func rehideDescriptions() {
        #expect(BarbackSettings.describeRehide(seconds: 0) == "Never")
        #expect(BarbackSettings.describeRehide(seconds: -3) == "Never")
        #expect(BarbackSettings.describeRehide(seconds: 1) == "1 second")
        #expect(BarbackSettings.describeRehide(seconds: 10) == "10 seconds")
        #expect(BarbackSettings.describeRehide(seconds: 60) == "1 minute")
        #expect(BarbackSettings.describeRehide(seconds: 300) == "5 minutes")
        #expect(BarbackSettings.autoRehidePresets.contains(BarbackSettings.default.autoRehideSeconds))
    }

    @Test func versionFromInfoDictionary() {
        #expect(BarbackInfo.version(from: ["CFBundleShortVersionString": "1.2.3"]) == "1.2.3")
        #expect(BarbackInfo.version(from: nil) == BarbackInfo.fallbackVersion)
        #expect(BarbackInfo.version(from: ["CFBundleShortVersionString": "  "]) == BarbackInfo.fallbackVersion)
        #expect(BarbackInfo.build(from: ["CFBundleVersion": "42"]) == "42")
        #expect(BarbackInfo.build(from: [:]) == nil)
    }
}
