import Foundation
import Testing
@testable import BarbackCore

@Suite("Settings transfer")
struct SettingsTransferTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    private let customised: BarbackSettings = {
        var s = BarbackSettings.default
        s.autoRehideSeconds = 30
        s.hotkey = KeyCombo(keyCode: 0, modifiers: [.command, .shift])
        s.showOnHover = true
        s.alwaysHiddenEnabled = true
        s.rehideOnAppSwitch = true
        s.appearance.toggleIcon = .wineglass
        s.appearance.extraDividerCount = 2
        s.clickAction = .dropDown
        s.dropDownLayout = .grid
        s.groups = [
            ItemGroup(name: "Café ☕️ 仕事", symbol: "briefcase", itemKeys: [ItemKey(owner: "com.example.app", detail: "Ünïcode")], layout: .grid),
            ItemGroup(name: "Gaming", symbol: "gamecontroller"),
        ]
        s.itemHotkeys = [
            ItemHotkey(key: ItemKey(owner: "com.example.app", detail: "Ünïcode"), combo: KeyCombo(keyCode: 1, modifiers: [.command, .option]), title: "Ünïcode ✨"),
        ]
        return s
    }()

    @Test func roundTripsEverySetting() throws {
        let data = try SettingsTransfer.encode(customised, appVersion: "1.2.3")
        #expect(try SettingsTransfer.decode(data, current: .default) == customised)
    }

    @Test func exportIsReadableSortedJSONWithVersions() throws {
        let data = try SettingsTransfer.encode(customised, appVersion: "1.2.3")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\n  \"app\" : \"Barback\",\n  \"appVersion\" : \"1.2.3\",\n  \"formatVersion\" : 1,"))
        #expect(text.contains("Café ☕️ 仕事"))
        #expect(!text.contains("\\/"))
        #expect(text.hasSuffix("}\n"))
    }

    @Test func disabledHotkeyIsExportedAsNullAndSurvivesImport() throws {
        var s = BarbackSettings.default
        s.hotkey = nil
        let data = try SettingsTransfer.encode(s, appVersion: "1")
        #expect(String(decoding: data, as: UTF8.self).contains("\"hotkey\" : null"))
        #expect(try SettingsTransfer.decode(data, current: .default).hotkey == nil)
    }

    @Test func unknownKeysAreIgnored() throws {
        let data = json(#"{"formatVersion": 1, "future": [1, 2], "settings": {"showOnHover": true, "sparkles": "yes", "appearance": {"glow": 3}}}"#)
        let s = try SettingsTransfer.decode(data, current: .default)
        #expect(s.showOnHover)
        #expect(s.appearance == .default)
    }

    @Test func missingKeysKeepCurrentValues() throws {
        let data = json(#"{"formatVersion": 1, "settings": {"autoRehideSeconds": 5, "appearance": {"tintWhenShowing": false}}}"#)
        let s = try SettingsTransfer.decode(data, current: customised)
        var expected = customised
        expected.autoRehideSeconds = 5
        expected.appearance.tintWhenShowing = false
        #expect(s == expected)
        #expect(try SettingsTransfer.decode(json(#"{"formatVersion": 1}"#), current: customised) == customised)
    }

    @Test func newerFormatVersionIsRejected() {
        #expect(throws: SettingsTransferError.unsupportedFormatVersion(found: 2, supported: 1)) {
            try SettingsTransfer.decode(json(#"{"formatVersion": 2, "settings": {}}"#), current: .default)
        }
    }

    @Test func malformedOrForeignFilesAreRejected() {
        #expect(throws: SettingsTransferError.malformedJSON) {
            try SettingsTransfer.decode(json(#"{"formatVersion": 1, "settings": {"#), current: .default)
        }
        #expect(throws: SettingsTransferError.notASettingsFile) {
            try SettingsTransfer.decode(json(#"{"showOnHover": true}"#), current: .default)
        }
        #expect(throws: SettingsTransferError.notASettingsFile) {
            try SettingsTransfer.decode(json("[1, 2, 3]"), current: .default)
        }
        #expect(throws: SettingsTransferError.invalidValue(path: "formatVersion")) {
            try SettingsTransfer.decode(json(#"{"formatVersion": "1"}"#), current: .default)
        }
        #expect(throws: SettingsTransferError.invalidValue(path: "settings")) {
            try SettingsTransfer.decode(json(#"{"formatVersion": 1, "settings": []}"#), current: .default)
        }
        #expect(throws: SettingsTransferError.fileTooLarge(bytes: SettingsTransfer.maxFileSize + 1)) {
            try SettingsTransfer.decode(Data(count: SettingsTransfer.maxFileSize + 1), current: .default)
        }
    }

    @Test func wrongTypesAndUnknownEnumValuesAreRejectedWithTheirPath() {
        let cases: [(String, String)] = [
            (#"{"showOnHover": "yes"}"#, "settings.showOnHover"),
            (#"{"clickAction": "explode"}"#, "settings.clickAction"),
            (#"{"appearance": {"toggleIcon": "unicorn"}}"#, "settings.appearance.toggleIcon"),
            (#"{"groups": [{"name": "No id"}]}"#, "settings.groups[0].id"),
            (#"{"hotkey": {"keyCode": "b", "modifiers": 256}}"#, "settings.hotkey.keyCode"),
        ]
        for (settings, path) in cases {
            let data = json(#"{"formatVersion": 1, "settings": "# + settings + "}")
            #expect(throws: SettingsTransferError.invalidValue(path: path)) {
                try SettingsTransfer.decode(data, current: .default)
            }
        }
        // Foundation reports unrepresentable numbers without a coding path.
        for settings in [#"{"autoRehideSeconds": 1.5}"#, #"{"hotkey": {"keyCode": -1, "modifiers": 256}}"#] {
            let data = json(#"{"formatVersion": 1, "settings": "# + settings + "}")
            #expect(throws: SettingsTransferError.self) { try SettingsTransfer.decode(data, current: .default) }
        }
    }

    @Test func outOfRangeValuesAreClamped() throws {
        let id = UUID()
        let data = json("""
        {"formatVersion": 1, "settings": {
          "autoRehideSeconds": 999999,
          "hotkey": {"keyCode": 11, "modifiers": 512},
          "appearance": {"extraDividerCount": 99},
          "groups": [
            {"id": "\(id)", "name": "  Wörk\\u0007  ", "symbol": "not a symbol!"},
            {"id": "\(id)", "name": "Duplicate"}
          ]
        }}
        """)
        let s = try SettingsTransfer.decode(data, current: .default)
        #expect(s.autoRehideSeconds == BarbackSettings.maxAutoRehideSeconds)
        #expect(s.hotkey == .defaultToggle)
        #expect(s.appearance.extraDividerCount == AppearanceSettings.maxExtraDividers)
        #expect(s.groups.map(\.name) == ["Wörk"])
        #expect(s.groups.first?.symbol == ItemGroups.defaultSymbol)
    }

    @Test func defaultFileNameIsDated() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SettingsTransfer.defaultFileName(date: date).hasPrefix("Barback Settings 2027-"))
        #expect(SettingsTransfer.defaultFileName(date: date).hasSuffix(".json"))
    }
}
