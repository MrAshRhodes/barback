import Foundation
import Testing
@testable import BarbackCore

@Suite("Item links")
struct ItemLinkURLTests {
    private func parse(_ string: String) -> Result<BarbackURLRequest, BarbackURLError> {
        BarbackURLRequest.parse(URL(string: string)!)
    }

    @Test func existingCommandsAndAliasesStillParse() {
        #expect(parse("barback://toggle") == .success(.command(.toggle)))
        #expect(parse("barback://reveal") == .success(.command(.show)))
        #expect(parse("BARBACK://Show-All") == .success(.command(.showAll)))
        #expect(parse("barback:toggleall") == .success(.command(.toggleAll)))
        #expect(parse("barback:///preferences") == .success(.command(.settings)))
        #expect(parse("barback://open-settings") == .success(.command(.settings)))
        #expect(BarbackURLCommand.parse(URL(string: "barback://hide")!) == .hide)
        // `open` is not a section command.
        #expect(BarbackURLCommand.parse(URL(string: "barback://open?name=Wi-Fi")!) == nil)
    }

    @Test func openByKeyDecodesPercentEncodedUnicode() {
        let result = parse("barback://open?item=com.apple.controlcenter/Wi%E2%80%91Fi%20%C3%A9t%C3%A9")
        #expect(result == .success(.open(.key(ItemKey(owner: "com.apple.controlcenter", detail: "Wi‑Fi été")))))
        #expect(parse("barback://open?item=com.example.app") == .success(.open(.key(ItemKey(owner: "com.example.app")))))
    }

    @Test func openByName() {
        #expect(parse("barback://open?name=Caf%C3%A9%20Menu") == .success(.open(.name("Café Menu"))))
        #expect(parse("barback:open?name=Dropbox") == .success(.open(.name("Dropbox"))))
        #expect(parse("barback://OPEN?Name=Dropbox") == .success(.open(.name("Dropbox"))))
        // A key is more precise than a name.
        #expect(parse("barback://open?name=X&item=com.example.x") == .success(.open(.key(ItemKey(owner: "com.example.x")))))
    }

    @Test func missingOrEmptyParametersAreErrors() {
        #expect(parse("barback://open") == .failure(.missingItem))
        #expect(parse("barback://open?name=") == .failure(.missingItem))
        #expect(parse("barback://open?item=%20&name=") == .failure(.missingItem))
        #expect(parse("barback://open?other=1") == .failure(.missingItem))
        #expect(parse("barback://open?item=/Wi-Fi") == .failure(.invalidItemKey("/Wi-Fi")))
    }

    @Test func unknownCommandsAndSchemes() {
        #expect(parse("barback://explode") == .failure(.unknownCommand("explode")))
        #expect(parse("https://open?name=x") == .failure(.unsupportedScheme))
        // Nothing in the scheme writes settings.
        #expect(parse("barback://set?hotkey=x") == .failure(.unknownCommand("set")))
    }

    @Test func linkIdentifierRoundTripsThroughURL() {
        let keys = [
            ItemKey(owner: "com.apple.controlcenter", detail: "Wi-Fi"),
            ItemKey(owner: "com.example.app"),
            ItemKey(owner: "com.example.app", detail: "Sync & Backup / Status = 100%+"),
            ItemKey(owner: "com.example.app", detail: "日本語 Ünïcödé"),
        ]
        for key in keys {
            #expect(BarbackURLRequest.parse(key.openURL) == .success(.open(.key(key))))
            #expect(ItemKey(linkIdentifier: key.linkIdentifier) == key)
        }
        #expect(ItemKey(owner: "com.example.app").openURL.absoluteString == "barback://open?item=com.example.app")
        #expect(ItemKey(linkIdentifier: "  ") == nil)
    }
}

@Suite("Item link matching")
struct ItemLinkMatchingTests {
    let wifi = ItemKey(owner: "com.apple.controlcenter", detail: "Wi-Fi")
    let battery = ItemKey(owner: "com.apple.controlcenter", detail: "Battery")
    let dropbox = ItemKey(owner: "com.getdropbox.dropbox")
    let cafeSync = ItemKey(owner: "com.example.cafe", detail: "Sync")
    let cafeStatus = ItemKey(owner: "com.example.cafe", detail: "Status")

    var candidates: [ItemLinkCandidate] {
        [
            ItemLinkCandidate(key: wifi, title: "Wi-Fi", appName: nil, detail: "Wi-Fi"),
            ItemLinkCandidate(key: battery, title: "Battery", appName: nil, detail: "Battery"),
            ItemLinkCandidate(key: dropbox, title: "Dropbox", appName: "Dropbox", detail: nil),
            ItemLinkCandidate(key: cafeSync, title: "Café", appName: "Café", detail: "Sync"),
            ItemLinkCandidate(key: cafeStatus, title: "Café", appName: "Café", detail: "Status"),
        ]
    }

    @Test func exactKey() {
        #expect(ItemLinkResolver.resolve(.key(wifi), among: candidates) == .found(wifi))
        #expect(ItemLinkResolver.resolve(.key(ItemKey(owner: "com.missing")), among: candidates) == .notFound)
        // Tolerant of a hand-written key's case and accents when that is still one item.
        #expect(ItemLinkResolver.resolve(.key(ItemKey(owner: "COM.APPLE.CONTROLCENTER", detail: "wi-fi")), among: candidates) == .found(wifi))
    }

    @Test func nameIgnoresCaseDiacriticsAndSpacing() {
        #expect(ItemLinkResolver.resolve(.name("dropbox"), among: candidates) == .found(dropbox))
        #expect(ItemLinkResolver.resolve(.name("  WI-FI "), among: candidates) == .found(wifi))
        #expect(ItemLinkResolver.resolve(.name("cafe sync"), among: candidates) == .notFound)
        #expect(ItemLinkResolver.resolve(.name("CAFE — sync"), among: candidates) == .found(cafeSync))
        #expect(ItemLinkResolver.resolve(.name("café - status"), among: candidates) == .found(cafeStatus))
        // Decomposed "é" (e + combining acute) matches too.
        #expect(ItemLinkResolver.resolve(.name("Cafe\u{301}  -  Status"), among: candidates) == .found(cafeStatus))
        #expect(ItemLinkResolver.resolve(.name("sync"), among: candidates) == .found(cafeSync))
    }

    @Test func ambiguousOrUnknownNamesNeverGuess() {
        #expect(ItemLinkResolver.resolve(.name("Cafe"), among: candidates) == .ambiguous([cafeSync, cafeStatus]))
        #expect(ItemLinkResolver.resolve(.name("Bluetooth"), among: candidates) == .notFound)
        #expect(ItemLinkResolver.resolve(.name("   "), among: candidates) == .notFound)
        // The same item listed twice (e.g. on two displays) is still one match.
        let doubled = candidates + [ItemLinkCandidate(key: dropbox, names: ["Dropbox"])]
        #expect(ItemLinkResolver.resolve(.name("Dropbox"), among: doubled) == .found(dropbox))
    }
}

@Suite("Item hotkeys")
struct ItemHotkeyTests {
    let a = ItemKey(owner: "com.example.a")
    let b = ItemKey(owner: "com.example.b")
    let comboA = KeyCombo(keyCode: 0, modifiers: [.control, .option])
    let comboB = KeyCombo(keyCode: 1, modifiers: [.control, .option])

    @Test func duplicateDetection() {
        var s = BarbackSettings()
        #expect(s.setItemHotkey(comboA, for: a, title: "A") == nil)
        // The main shortcut and other items' shortcuts are refused.
        #expect(s.setItemHotkey(.defaultToggle, for: b, title: "B") == .main)
        #expect(s.setItemHotkey(comboA, for: b, title: "B") == .item(a))
        #expect(s.itemHotkeys == [ItemHotkey(key: a, combo: comboA, title: "A")])
        // Reassigning an item's own shortcut is fine.
        #expect(s.setItemHotkey(comboA, for: a, title: "A") == nil)
        #expect(s.setItemHotkey(comboB, for: a, title: "A2") == nil)
        #expect(s.itemHotkeys == [ItemHotkey(key: a, combo: comboB, title: "A2")])
        #expect(HotkeyConflicts.conflict(for: comboB, target: .main, in: s.hotkeyAssignments) == .item(a))
        #expect(HotkeyConflicts.conflict(for: comboB, target: .named("search"), in: s.hotkeyAssignments) == .item(a))
        #expect(s.setItemHotkey(nil, for: a, title: nil) == nil)
        #expect(s.itemHotkeys.isEmpty)
    }

    @Test func duplicatesList() {
        let assignments = [
            HotkeyAssignment(target: .main, combo: comboA),
            HotkeyAssignment(target: .item(a), combo: comboA),
            HotkeyAssignment(target: .item(b), combo: comboB),
        ]
        #expect(HotkeyConflicts.duplicates(in: assignments) == [comboA: [.main, .item(a)]])
    }

    @Test func sanitizingDropsInvalidAndDuplicateShortcuts() {
        let s = BarbackSettings(itemHotkeys: [
            ItemHotkey(key: a, combo: comboA),
            ItemHotkey(key: b, combo: comboA),
            ItemHotkey(key: a, combo: comboB),
            ItemHotkey(key: b, combo: .defaultToggle),
            ItemHotkey(key: b, combo: KeyCombo(keyCode: 0, modifiers: [.shift])),
            ItemHotkey(key: b, combo: comboB),
        ]).sanitized()
        #expect(s.itemHotkeys == [ItemHotkey(key: a, combo: comboA), ItemHotkey(key: b, combo: comboB)])
    }

    @Test func storeRoundTripAndOldSettingsLoad() {
        let suite = "barback.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        // Settings saved before item shortcuts existed have no such key.
        #expect(store.load().itemHotkeys.isEmpty)
        let custom = BarbackSettings(itemHotkeys: [ItemHotkey(key: ItemKey(owner: "com.x", detail: "Ü"), combo: comboA, title: "X")])
        store.save(custom)
        #expect(store.load() == custom)
        d.set(Data("not json".utf8), forKey: SettingsKey.itemHotkeys.rawValue)
        #expect(store.load().itemHotkeys.isEmpty)
        store.save(BarbackSettings())
        #expect(d.object(forKey: SettingsKey.itemHotkeys.rawValue) == nil)
    }

    @Test func codableDecodingIsBackwardCompatible() throws {
        // A document from before `itemHotkeys` (and missing other keys) still decodes.
        let old = Data(#"{"autoRehideSeconds": 30, "showOnHover": true, "groups": []}"#.utf8)
        let decoded = try JSONDecoder().decode(BarbackSettings.self, from: old)
        #expect(decoded.autoRehideSeconds == 30)
        #expect(decoded.showOnHover)
        #expect(decoded.itemHotkeys.isEmpty)
        #expect(decoded.appearance == .default)

        let custom = BarbackSettings(itemHotkeys: [ItemHotkey(key: a, combo: comboA, title: "A")])
        let roundTripped = try JSONDecoder().decode(BarbackSettings.self, from: JSONEncoder().encode(custom))
        #expect(roundTripped == custom)
    }
}
