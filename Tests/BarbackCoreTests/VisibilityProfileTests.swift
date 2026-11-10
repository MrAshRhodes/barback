import Foundation
import Testing
@testable import BarbackCore

@Suite("Visibility profiles")
struct VisibilityProfileTests {
    private func context(app: String? = nil, builtIn: Int = 1, external: Int = 0) -> ProfileContext {
        ProfileContext(frontmostBundleID: app, builtInDisplayCount: builtIn, externalDisplayCount: external)
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "BarbackCoreTests.Profiles.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func appRulesWinOverEarlierDisplayRulesAndOrderBreaksTies() {
        let desk = VisibilityProfile(name: "Desk", automatic: true, displayCondition: .externalPresent)
        let keynote = VisibilityProfile(name: "Keynote", automatic: true, appBundleID: "com.apple.Keynote")
        let keynoteDesk = VisibilityProfile(
            name: "Keynote desk", automatic: true, appBundleID: "com.apple.Keynote", displayCondition: .externalPresent
        )
        let later = VisibilityProfile(name: "Later desk", automatic: true, displayCondition: .externalPresent)
        let profiles = [desk, keynote, keynoteDesk, later]

        #expect(VisibilityProfiles.match(in: profiles, context: context(app: "com.apple.Keynote", external: 1)) == keynote.id)
        #expect(VisibilityProfiles.match(in: [desk, keynoteDesk, keynote], context: context(app: "com.apple.Keynote", external: 1)) == keynoteDesk.id)
        #expect(VisibilityProfiles.match(in: profiles, context: context(app: "com.apple.Safari", external: 1)) == desk.id)
        #expect(VisibilityProfiles.match(in: profiles, context: context(app: "com.apple.Safari")) == nil)
    }

    @Test func manualOrConditionlessProfilesNeverMatchAutomatically() {
        let manual = VisibilityProfile(name: "Manual", appBundleID: "com.apple.Safari")
        let empty = VisibilityProfile(name: "Empty", automatic: true)
        let any = context(app: "com.apple.Safari", external: 2)
        #expect(!manual.matches(any))
        #expect(!empty.matches(any))
        #expect(VisibilityProfiles.match(in: [manual, empty], context: any) == nil)
    }

    @Test func displayConditionsAndCountsCombine() {
        func profile(_ condition: ProfileDisplayCondition, count: Int? = nil) -> VisibilityProfile {
            VisibilityProfile(name: "P", automatic: true, displayCondition: condition, displayCount: count)
        }
        let laptop = context(builtIn: 1, external: 0)
        let docked = context(builtIn: 1, external: 1)
        let clamshell = context(builtIn: 0, external: 2)
        #expect(profile(.builtInOnly).matches(laptop))
        #expect(!profile(.builtInOnly).matches(docked))
        #expect(profile(.externalPresent).matches(docked))
        #expect(profile(.externalPresent).matches(clamshell))
        #expect(!profile(.externalPresent).matches(laptop))
        #expect(profile(.externalOnly).matches(clamshell))
        #expect(!profile(.externalOnly).matches(docked))
        #expect(profile(.any, count: 2).matches(docked))
        #expect(profile(.any, count: 2).matches(clamshell))
        #expect(!profile(.any, count: 2).matches(laptop))
        #expect(!profile(.externalOnly, count: 2).matches(docked))
    }

    @Test func profilesFilterPanelMembershipWithoutChangingTheBaseConfiguration() {
        let kept = ItemKey(owner: "com.example.kept")
        let excluded = ItemKey(owner: "com.example.excluded")
        let groups = [ItemGroup(name: "Work", itemKeys: [kept, excluded]), ItemGroup(name: "Play", itemKeys: [excluded])]
        let profile = VisibilityProfile(name: "Focus", excludedPanelItems: [excluded])

        let effective = VisibilityProfiles.groups(groups, applying: profile)
        #expect(effective.map(\.itemKeys) == [[kept], []])
        #expect(effective.map(\.id) == groups.map(\.id))
        #expect(groups.map(\.itemKeys) == [[kept, excluded], [excluded]])
        #expect(VisibilityProfiles.groups(groups, applying: nil) == groups)
    }

    @Test func sanitizingBoundsAndDeduplicatesProfiles() {
        let duplicate = VisibilityProfile(name: "One")
        let key = ItemKey(owner: "com.example.app")
        let messy = VisibilityProfile(
            name: "   ", excludedPanelItems: [key, key, ItemKey(owner: "")],
            appBundleID: "  com.apple.Safari \n", displayCount: 99
        )
        let many = (0..<30).map { VisibilityProfile(name: "P\($0)") }
        let result = VisibilityProfiles.sanitized([duplicate, duplicate, messy] + many)

        #expect(result.count == VisibilityProfiles.maxProfiles)
        #expect(result.filter { $0.id == duplicate.id }.count == 1)
        let cleaned = result[1]
        #expect(cleaned.name == "Profile")
        #expect(cleaned.appBundleID == "com.apple.Safari")
        #expect(cleaned.displayCount == 32)
        #expect(cleaned.excludedPanelItems == [key])
    }

    @Test func profilesPersistAndMissingActiveProfilesFallBackToBase() {
        let (d, suite) = defaults()
        defer { d.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: d)
        #expect(store.load().notchOverflowEnabled == false)
        #expect(store.load().profiles.isEmpty)
        #expect(store.load().baseVisibility == .hidden)

        var s = BarbackSettings.default
        let profile = VisibilityProfile(name: "Desk", visibility: .shownAll, automatic: true, displayCondition: .externalOnly)
        s.profiles = [profile]
        s.activeProfileID = profile.id
        s.baseVisibility = .shown
        s.notchOverflowEnabled = true
        store.save(s)
        #expect(store.load() == s)

        d.set(UUID().uuidString, forKey: SettingsKey.activeProfileID.rawValue)
        #expect(store.load().activeProfileID == nil)
        #expect(store.load().profiles == [profile])

        s.profiles = []
        s.activeProfileID = nil
        store.save(s)
        #expect(d.object(forKey: SettingsKey.profiles.rawValue) == nil)
        #expect(store.load().profiles.isEmpty)

        store.save(BarbackSettings(profiles: [profile], activeProfileID: profile.id, baseVisibility: .shownAll))
        store.reset()
        #expect(store.load() == .default)
    }

    @Test func unreadableProfilesAreIgnoredAndOlderProfilesKeepDefaults() throws {
        let (d, suite) = defaults()
        defer { d.removePersistentDomain(forName: suite) }
        d.set(Data("not json".utf8), forKey: SettingsKey.profiles.rawValue)
        #expect(SettingsStore(defaults: d).load().profiles.isEmpty)

        let id = UUID()
        d.set(#"[{"id": "\#(id.uuidString)", "name": "Older"}]"#, forKey: SettingsKey.profiles.rawValue)
        let loaded = try #require(SettingsStore(defaults: d).load().profiles.first)
        #expect(loaded == VisibilityProfile(id: id, name: "Older"))
    }
}
