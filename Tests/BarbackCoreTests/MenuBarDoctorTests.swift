import CoreGraphics
import Foundation
import Testing
@testable import BarbackCore

@Suite("Menu Bar Doctor evidence")
struct MenuBarDoctorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = ItemKey(owner: "com.example.clock", detail: "Timer")
    let display = MenuBarDisplay(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        notch: CGRect(x: 650, y: 0, width: 140, height: 32)
    )

    func entry(
        id: UInt32 = 1, bundle: String? = "com.example.clock", detail: String? = "Timer",
        x: CGFloat = 1100, y: CGFloat = 0, display: Int? = 0,
        section: MenuBarSection = .hidden, visibility: ItemVisibility = .shown
    ) -> MenuBarDoctor.Entry {
        MenuBarDoctor.Entry(
            item: MenuBarItem(
                windowID: id, ownerName: "Control Center", ownerPID: 20,
                frame: CGRect(x: x, y: y, width: 24, height: 24),
                isOnScreen: visibility == .shown, resolvedName: "Clock", bundleID: bundle,
                detail: detail, sourcePID: bundle == nil ? nil : 42
            ),
            section: section, visibility: visibility, display: display
        )
    }

    func snapshot(
        _ entries: [MenuBarDoctor.Entry] = [], at date: Date? = nil,
        trusted: Bool = true, failure: String? = nil, stale: Bool = false
    ) -> MenuBarDoctor.Snapshot {
        MenuBarDoctor.Snapshot(
            entries: entries, displays: [display], displayNames: ["Built-in display"],
            scannedAt: date ?? now, attemptedAt: now, failure: failure, accessibilityTrusted: trusted,
            contextIsStale: stale, sectionState: .hidden, frontmostApp: "Finder",
            runningBundleIDs: ["com.example.clock", "com.apple.controlcenter"]
        )
    }

    @Test func observedMeansWindowObservedNotProvenVisible() {
        let report = MenuBarDoctor.report(for: key, snapshot: snapshot([entry(visibility: .notDrawn)]), history: .init(), now: now)
        #expect(report.status == .current)
        #expect(report.presence == .observed)
        #expect(report.current?.entry.visibility == .notDrawn)
        #expect(report.current?.hiddenState == .hiddenSectionCollapsed)
        #expect(report.current?.displayName == "Built-in display")
        #expect(report.lastObservedAt == now)
        #expect(report.sourceBundleID == "com.example.clock")
        #expect(report.sourceAppRunning == true)
    }

    @Test func absentPreservesBoundedPreviousObservationWithoutCurrentClaims() {
        var history = MenuBarDoctorHistory()
        history.record(snapshot([entry()], at: now.addingTimeInterval(-90)), now: now)
        let report = MenuBarDoctor.report(for: key, snapshot: snapshot(), history: history, now: now)
        #expect(report.status == .current)
        #expect(report.presence == .notObserved)
        #expect(report.current == nil)
        #expect(report.previous?.observedAt == now.addingTimeInterval(-90))
        #expect(report.confidence == .limited)
    }

    @Test func noReliablePreviousObservationRemainsUnknown() {
        let report = MenuBarDoctor.report(for: key, snapshot: snapshot(), history: .init(), now: now)
        #expect(report.presence == .notObserved)
        #expect(report.lastObservedAt == nil)
        #expect(report.sourceBundleID == nil)
        #expect(report.sourceAppRunning == nil)
        let unscanned = MenuBarDoctor.report(for: key, snapshot: nil, history: .init(), now: now)
        #expect(unscanned.status == .notScanned)
        #expect(unscanned.presence == .unknown)
    }

    @Test func duplicateIdentityDoesNotMatchByPosition() {
        let duplicate = snapshot([entry(), entry(id: 2, x: 1200)])
        let report = MenuBarDoctor.report(for: key, snapshot: duplicate, history: .init(), now: now)
        #expect(report.presence == .ambiguous)
        #expect(report.current == nil)
        #expect(report.confidence == .unknown)
        var history = MenuBarDoctorHistory()
        history.record(duplicate, now: now)
        #expect(history.observations(now: now).isEmpty)
    }

    @Test func legacyPositionalKeyCannotBePromotedToReliableIdentity() {
        let positional = ItemKey(owner: key.owner, detail: key.detail, ordinal: 1)
        let report = MenuBarDoctor.report(for: positional, snapshot: snapshot([entry()]), history: .init(), now: now)
        #expect(report.presence == .ambiguous)
        #expect(report.current == nil)
        #expect(report.sourceBundleID == nil)
    }

    @Test func changedOrMissingDetailCannotReassignSibling() {
        let unnamed = ItemKey(owner: key.owner)
        let report = MenuBarDoctor.report(for: unnamed, snapshot: snapshot([entry()]), history: .init(), now: now)
        #expect(report.presence == .ambiguous)
        let missingDetail = MenuBarDoctor.report(for: key, snapshot: snapshot([entry(detail: nil)]), history: .init(), now: now)
        #expect(missingDetail.presence == .ambiguous)
    }

    @Test func mirroredCopiesUseReliableIdentityNotWindowID() {
        var scan = snapshot([entry(id: 9), entry(id: 12, x: 1500, display: 1)])
        scan.displays.append(MenuBarDisplay(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)))
        #expect(scan.reliableKeys.count == 2)
        let report = MenuBarDoctor.report(for: key, snapshot: scan, history: .init(), now: now)
        #expect(report.presence == .observed)
        var history = MenuBarDoctorHistory()
        history.record(scan, now: now)
        #expect(history.observations(now: now).count == 1)
    }

    @Test func permissionLimitedResultsNeverGainHighConfidence() {
        let observed = MenuBarDoctor.report(for: key, snapshot: snapshot([entry()], trusted: false), history: .init(), now: now)
        #expect(observed.presence == .observed)
        #expect(observed.confidence == .limited)
        let absent = MenuBarDoctor.report(for: key, snapshot: snapshot(trusted: false), history: .init(), now: now)
        #expect(absent.presence == .notObserved)
        #expect(absent.confidence == .limited)
    }

    @Test func unresolvedHostedWindowsAreNotSourceApps() {
        var unresolved = entry(bundle: nil, detail: nil)
        unresolved.item.sourcePID = 42
        let scan = snapshot([unresolved])
        #expect(scan.reliableKeys.isEmpty)
        let report = MenuBarDoctor.report(for: ItemKey(owner: "Control Center"), snapshot: scan, history: .init(), now: now)
        #expect(report.presence == .ambiguous)
        #expect(report.sourceBundleID == nil)
        #expect(report.sourceAppRunning == nil)
        #expect(report.unidentifiedCount == 1)
    }

    @Test func systemHostBundleNeverBecomesLaunchableApp() {
        let systemKey = ItemKey(owner: "com.apple.controlcenter", detail: "Battery")
        let system = entry(bundle: "com.apple.controlcenter", detail: "Battery")
        let report = MenuBarDoctor.report(for: systemKey, snapshot: snapshot([system]), history: .init(), now: now)
        #expect(report.presence == .observed)
        #expect(report.sourceBundleID == nil)
        #expect(report.sourceAppRunning == nil)
        let mixedCaseKey = ItemKey(owner: "com.apple.SystemUIServer", detail: "Battery")
        let mixedCaseHost = entry(bundle: mixedCaseKey.owner, detail: "Battery")
        let mixedCaseReport = MenuBarDoctor.report(for: mixedCaseKey, snapshot: snapshot([mixedCaseHost]), history: .init(), now: now)
        #expect(mixedCaseReport.sourceBundleID == nil)
        #expect(mixedCaseReport.sourceAppRunning == nil)
    }

    @Test func staleTimeContextAndFutureEvidenceAreNotCurrent() {
        for scan in [
            snapshot([entry()], at: now.addingTimeInterval(-121)),
            snapshot([entry()], stale: true),
            snapshot([entry()], at: now.addingTimeInterval(1)),
        ] {
            let report = MenuBarDoctor.report(for: key, snapshot: scan, history: .init(), now: now)
            #expect(report.status == .stale)
            #expect(report.presence == .unknown)
            #expect(report.current == nil)
        }
    }

    @Test func failedScanIsNotSuccessfulAbsenceEvenWithPreservedRows() {
        var history = MenuBarDoctorHistory()
        history.record(snapshot([entry()], at: now.addingTimeInterval(-20)), now: now)
        for entries in [[], [entry()]] {
            let failed = snapshot(entries, failure: "Window server unavailable")
            history.record(failed, now: now)
            let report = MenuBarDoctor.report(for: key, snapshot: failed, history: history, now: now)
            #expect(report.status == .failed)
            #expect(report.presence == .unknown)
            #expect(report.current == nil)
            #expect(report.previous?.observedAt == now.addingTimeInterval(-20))
            #expect(report.confidence == .unknown)
        }
    }

    @Test func geometryRequiresMeasuredSameDisplayFrames() {
        let underNotch = entry(x: 700)
        #expect(MenuBarDoctor.geometry(for: underNotch, in: snapshot([underNotch])).notch == .overlapsNotch)
        #expect(MenuBarDoctor.geometry(for: entry(), in: snapshot()).notch == .clearOfNotch)
        var external = snapshot()
        external.displays = [MenuBarDisplay(frame: display.frame)]
        #expect(MenuBarDoctor.geometry(for: underNotch, in: external).notch == .noNotch)
        #expect(MenuBarDoctor.geometry(for: entry(display: nil), in: snapshot()).notch == .geometryUnavailable)
        #expect(MenuBarDoctor.geometry(for: entry(display: 8), in: snapshot()).notch == .geometryUnavailable)
        #expect(MenuBarDoctor.geometry(for: entry(x: -8000, visibility: .offScreen), in: snapshot()).notch == .outsideDisplay)
    }

    @Test func invalidGeometryCannotBecomeNotchOrCrowdingEvidence() {
        var invalid = entry()
        invalid.item.frame.size.width = .nan
        #expect(MenuBarDoctor.geometry(for: invalid, in: snapshot()).notch == .geometryUnavailable)
        var scan = snapshot()
        scan.displays[0].notch = CGRect(x: 650, y: 0, width: 0, height: 32)
        #expect(MenuBarDoctor.geometry(for: entry(x: 700), in: scan).notch == .geometryUnavailable)
        scan.displays[0].frame.size.width = .infinity
        #expect(MenuBarDoctor.geometry(for: entry(), in: scan).notch == .geometryUnavailable)
    }

    @Test func onlyCapturedOverlappingPeersSupportCrowdingClue() {
        let item = entry()
        let peer = entry(id: 2, bundle: "com.example.other", x: 1110)
        #expect(MenuBarDoctor.geometry(for: item, in: snapshot([item, peer])).overlapsCapturedPeer == true)
        let otherDisplay = entry(id: 2, bundle: "com.example.other", x: 1110, display: 1)
        #expect(MenuBarDoctor.geometry(for: item, in: snapshot([item, otherDisplay])).overlapsCapturedPeer == false)
        var invalidPeer = peer
        invalidPeer.item.frame.size.width = 0
        #expect(MenuBarDoctor.geometry(for: item, in: snapshot([item, invalidPeer])).overlapsCapturedPeer == nil)
    }

    @Test func touchingEdgesAreNotMeasuredOverlap() {
        let touchesNotch = entry(x: 626)
        #expect(MenuBarDoctor.geometry(for: touchesNotch, in: snapshot([touchesNotch])).notch == .clearOfNotch)
        let item = entry()
        let adjacent = entry(id: 2, bundle: "com.example.other", x: 1124)
        #expect(MenuBarDoctor.geometry(for: item, in: snapshot([item, adjacent])).overlapsCapturedPeer == false)
    }

    @Test func hiddenStateRequiresSectionAndRevealState() {
        #expect(MenuBarDoctor.hiddenState(section: .unknown, state: .hidden) == .unknown)
        #expect(MenuBarDoctor.hiddenState(section: .hidden, state: nil) == .unknown)
        #expect(MenuBarDoctor.hiddenState(section: .hidden, state: .shown) == .sectionRevealed)
        #expect(MenuBarDoctor.hiddenState(section: .alwaysHidden, state: .shown) == .alwaysHiddenSectionCollapsed)
        #expect(MenuBarDoctor.hiddenState(section: .alwaysHidden, state: .shownAll) == .sectionRevealed)
        #expect(MenuBarDoctor.hiddenState(section: .visible, state: .hidden) == .notManaged)
    }

    @Test func boundedHistoryExpiresAndIgnoresOlderOrFailedUpdates() {
        var history = MenuBarDoctorHistory()
        history.record(snapshot([entry()]), now: now)
        history.record(snapshot([entry(x: 700)], at: now.addingTimeInterval(-50)), now: now)
        #expect(history.observation(for: key, now: now)?.entry.item.frame.minX == 1100)
        #expect(history.observation(for: key, now: now.addingTimeInterval(MenuBarDoctorHistory.maximumAge + 1)) == nil)
        let many = (1...300).map { entry(id: UInt32($0), bundle: "com.example.app\($0)") }
        history.record(snapshot(many), now: now)
        #expect(history.observations(now: now).count == 256)
        history.record(snapshot(), now: now.addingTimeInterval(MenuBarDoctorHistory.maximumAge + 1))
        #expect(history.observations(now: now.addingTimeInterval(MenuBarDoctorHistory.maximumAge + 1)).isEmpty)
    }

    @Test func pickerCombinesSavedCurrentAndPreviouslySeenTargets() {
        var history = MenuBarDoctorHistory()
        history.record(snapshot([entry()], at: now.addingTimeInterval(-60)), now: now)
        let saved = ItemKey(owner: "com.example.saved", detail: "Saved item")
        let targets = MenuBarDoctor.targets(
            snapshot: snapshot([entry(id: 2, bundle: "com.example.other")]), savedKeys: [saved],
            history: history, now: now
        )
        #expect(targets.count == 3)
        #expect(targets.first { $0.key == saved }?.isSaved == true)
        #expect(targets.first { $0.key == key }?.wasPreviouslyObserved == true)
    }
}
