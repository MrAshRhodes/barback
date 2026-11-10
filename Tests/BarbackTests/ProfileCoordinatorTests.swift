import AppKit
import BarbackCore
import Testing
@testable import Barback

@Suite("Context profiles", .serialized)
@MainActor
struct ProfileCoordinatorTests {
    @MainActor
    private final class Harness {
        let suite = "BarbackTests.Profiles.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: AppModel
        var context = ProfileContext(frontmostBundleID: "com.apple.Safari", builtInDisplayCount: 1, externalDisplayCount: 0)
        var applied: [ProfileVisibility] = []
        var coordinator: ProfileCoordinator!

        init(profiles: [VisibilityProfile] = [], active: UUID? = nil, base: ProfileVisibility = .hidden) {
            defaults = UserDefaults(suiteName: suite)!
            model = AppModel(store: SettingsStore(defaults: defaults))
            model.settings.profiles = profiles
            model.settings.activeProfileID = active
            model.settings.baseVisibility = base
            coordinator = ProfileCoordinator(
                model: model, observeSystem: false,
                context: { [unowned self] in self.context },
                applyVisibility: { [unowned self] in self.applied.append($0) }
            )
            model.onSettingsChange = { [unowned self] in self.coordinator.settingsDidChange(from: $0, to: $1) }
        }

        deinit { defaults.removePersistentDomain(forName: suite) }
    }

    private let desk = VisibilityProfile(
        name: "Desk", visibility: .shownAll, automatic: true, displayCondition: .externalPresent
    )
    private let keynote = VisibilityProfile(
        name: "Keynote", visibility: .hidden, automatic: true, appBundleID: "com.apple.Keynote"
    )
    private let manual = VisibilityProfile(name: "Manual", visibility: .shown)

    @Test func withoutProfilesNothingIsObservedOrApplied() {
        let h = Harness()
        h.coordinator.start()
        h.context.externalDisplayCount = 1
        h.coordinator.contextChanged()
        h.coordinator.select(nil)
        #expect(h.applied.isEmpty)
        #expect(h.model.settings.activeProfileID == nil)
    }

    @Test func launchLeavesSectionsAloneWhenNothingMatches() {
        let h = Harness(profiles: [desk, keynote], base: .shown)
        h.coordinator.start()
        #expect(h.applied.isEmpty)
        #expect(h.model.settings.activeProfileID == nil)
    }

    @Test func launchSelectsTheMatchingProfileAndKeepsTheBase() {
        let h = Harness(profiles: [desk, keynote], base: .shown)
        h.context.externalDisplayCount = 1
        h.coordinator.start()
        #expect(h.model.settings.activeProfileID == desk.id)
        #expect(h.applied == [.shownAll])
        #expect(h.model.settings.baseVisibility == .shown)
        #expect(h.model.store.load().activeProfileID == desk.id)
    }

    @Test func launchRestoresASavedManualProfile() {
        let h = Harness(profiles: [desk, manual], active: manual.id)
        h.coordinator.start()
        #expect(h.applied == [.shown])
        #expect(h.model.settings.activeProfileID == manual.id)
    }

    /// What the delayed hide queued at launch decides when it fires, after `start()` has applied the profile.
    private func launchHideStillRuns(_ h: Harness) -> Bool {
        StatusBarController.shouldRunLaunchHide(userActed: false, activeProfile: h.model.activeProfile?.visibility)
    }

    @Test func aRestoredProfileThatShowsSectionsSurvivesTheLaunchHide() {
        for visibility in [ProfileVisibility.shown, .shownAll] {
            let saved = VisibilityProfile(name: "Saved", visibility: visibility)
            let h = Harness(profiles: [desk, saved], active: saved.id)
            h.coordinator.start()
            #expect(h.applied == [visibility])
            #expect(!launchHideStillRuns(h), "A \(visibility) profile restored at launch must not be hidden again")
        }
    }

    @Test func aMatchedProfileThatShowsSectionsSurvivesTheLaunchHide() {
        let h = Harness(profiles: [desk, keynote])
        h.context.externalDisplayCount = 1
        h.coordinator.start()
        #expect(h.applied == [.shownAll])
        #expect(!launchHideStillRuns(h))
    }

    @Test func hiddenAndUnmatchedLaunchesKeepTheLaunchHide() {
        let quiet = VisibilityProfile(name: "Quiet", visibility: .hidden)
        let restoredHidden = Harness(profiles: [quiet], active: quiet.id)
        restoredHidden.coordinator.start()
        #expect(restoredHidden.applied == [.hidden])
        #expect(launchHideStillRuns(restoredHidden))

        let unmatched = Harness(profiles: [desk, keynote], base: .shownAll)
        unmatched.coordinator.start()
        #expect(unmatched.applied.isEmpty)
        #expect(launchHideStillRuns(unmatched))

        let withoutProfiles = Harness()
        withoutProfiles.coordinator.start()
        #expect(launchHideStillRuns(withoutProfiles))
    }

    @Test func theLaunchHideFollowsAProfileChosenBeforeItRuns() {
        let h = Harness(profiles: [manual, keynote], active: manual.id)
        h.coordinator.start()
        #expect(!launchHideStillRuns(h))
        h.coordinator.select(keynote.id)
        #expect(h.applied == [.shown, .hidden])
        #expect(launchHideStillRuns(h))
    }

    @Test func appRulesWinAndBaseReturnsWhenNothingMatches() {
        let h = Harness(profiles: [desk, keynote], base: .shown)
        h.coordinator.start()
        h.context.externalDisplayCount = 1
        h.coordinator.contextChanged()
        #expect(h.model.settings.activeProfileID == desk.id)
        h.context.frontmostBundleID = "com.apple.Keynote"
        h.coordinator.contextChanged()
        #expect(h.model.settings.activeProfileID == keynote.id)
        h.context = ProfileContext(frontmostBundleID: "com.apple.Mail", builtInDisplayCount: 1, externalDisplayCount: 0)
        h.coordinator.contextChanged()
        #expect(h.model.settings.activeProfileID == nil)
        #expect(h.applied == [.shownAll, .hidden, .shown])
    }

    @Test func manualSelectionLastsUntilTheNextContextChange() {
        let h = Harness(profiles: [desk, manual])
        h.context.externalDisplayCount = 1
        h.coordinator.start()
        h.model.onProfileSelection = { [unowned h] in h.coordinator.select($0) }
        h.model.selectProfile(manual.id)
        #expect(h.model.settings.activeProfileID == manual.id)

        h.coordinator.contextChanged()
        #expect(h.model.settings.activeProfileID == manual.id, "An unchanged context keeps the manual choice")

        h.context.frontmostBundleID = "com.apple.Mail"
        h.coordinator.contextChanged()
        #expect(h.model.settings.activeProfileID == desk.id)
        #expect(h.applied == [.shownAll, .shown, .shownAll])
    }

    @Test func stayingOnTheSameProfileDoesNotReapplySections() {
        let h = Harness(profiles: [desk])
        h.context.externalDisplayCount = 1
        h.coordinator.start()
        h.context.frontmostBundleID = "com.apple.Mail"
        h.coordinator.contextChanged()
        h.context.externalDisplayCount = 2
        h.coordinator.contextChanged()
        #expect(h.applied == [.shownAll])
    }

    @Test func editsOnlyApplyWhenTheTargetVisibilityChanges() {
        let h = Harness(profiles: [manual], active: manual.id, base: .hidden)
        h.coordinator.start()
        h.applied.removeAll()

        h.model.settings.profiles[0].name = "Renamed"
        h.model.settings.profiles[0].appBundleID = "com.apple.Notes"
        h.model.settings.baseVisibility = .shownAll
        #expect(h.applied.isEmpty)

        h.model.settings.profiles[0].visibility = .shownAll
        #expect(h.applied == [.shownAll])

        h.coordinator.select(nil)
        #expect(h.applied == [.shownAll, .shownAll])
        h.model.settings.baseVisibility = .hidden
        #expect(h.applied == [.shownAll, .shownAll, .hidden])
    }

    @Test func deletingTheLastActiveProfileRestoresTheBaseAndStops() {
        let h = Harness(profiles: [manual], active: manual.id, base: .hidden)
        h.coordinator.start()
        h.model.settings.profiles = []
        #expect(h.model.settings.activeProfileID == nil)
        #expect(h.applied == [.shown, .hidden])

        h.context.externalDisplayCount = 3
        h.coordinator.contextChanged()
        #expect(h.applied == [.shown, .hidden])
    }

    @Test func creatingTheFirstProfileStartsWithoutChangingSections() {
        let h = Harness()
        h.coordinator.start()
        h.model.settings.profiles = [manual]
        #expect(h.applied.isEmpty)
        h.context.externalDisplayCount = 1
        h.model.settings.profiles.append(desk)
        h.coordinator.contextChanged()
        #expect(h.model.settings.activeProfileID == desk.id)
        #expect(h.applied == [.shownAll])
    }

    @Test func missingProfilesCannotBeSelected() {
        let h = Harness(profiles: [manual])
        h.coordinator.start()
        h.coordinator.select(UUID())
        #expect(h.model.settings.activeProfileID == nil)
        #expect(h.applied.isEmpty)
    }

    @Test func effectiveGroupsFilterOnlyTheActiveProfile() {
        let key = ItemKey(owner: "com.example.app")
        var focus = manual
        focus.excludedPanelItems = [key]
        let h = Harness(profiles: [focus])
        h.model.settings.groups = [ItemGroup(name: "Work", itemKeys: [key])]
        #expect(h.model.effectiveGroups.first?.itemKeys == [key])
        h.coordinator.start()
        h.coordinator.select(focus.id)
        #expect(h.model.effectiveGroups.first?.itemKeys == [])
        #expect(h.model.settings.groups.first?.itemKeys == [key])
    }
}

@Suite("Scan failures")
struct ScanFailureTests {
    @Test func anUnreadableWindowListIsAnErrorNotAnEmptyMenuBar() {
        let scan = AccessibilityScanner.scan(tops: [0], trusted: false, apps: [], readWindows: { nil })
        #expect(scan.items.isEmpty)
        #expect(scan.error != nil)
    }

    @Test func aReadableEmptyWindowListIsNotAnError() {
        let scan = AccessibilityScanner.scan(tops: [0], trusted: false, apps: [], readWindows: { [] })
        #expect(scan.items.isEmpty)
        #expect(scan.error == nil)
        #expect(scan.warnings.isEmpty)
    }

    @MainActor
    @Test func snapshotsCarryTheirErrorAndStaleness() {
        let captured = Date(timeIntervalSince1970: 1_000)
        let items = ItemsModel(snapshot: [], capturedAt: captured, scanError: "Failed", isStale: true)
        #expect(items.scanError == "Failed")
        #expect(items.snapshotContextIsStale)
        #expect(items.lastRefreshed == captured)
    }
}
