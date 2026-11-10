import AppKit
import BarbackCore
import Testing
@testable import Barback

@Suite("Local usage review storage")
@MainActor
struct UsageReviewModelTests {
    private let start = Date(timeIntervalSince1970: 1_767_268_800)
    private let key = ItemKey(owner: "test.status", detail: "Status")

    @Test func disabledModelDoesNotCreateStorageOrCollectMeasurements() throws {
        try withDefaults { defaults in
            let review = UsageReviewModel(defaults: defaults, now: { start })
            review.recordConfirmedOpen(key: key)
            review.refreshMeasurements(from: snapshot(at: start))
            review.endSession()
            #expect(!review.isEnabled)
            #expect(review.snapshot.entries.isEmpty)
            #expect(defaults.object(forKey: UsageReviewModel.storageKey) == nil)
        }
    }

    @Test func countsAndConsentSurviveRelaunchButDowntimeIsNotRecorded() throws {
        try withDefaults { defaults in
            var date = start
            let review = UsageReviewModel(defaults: defaults, now: { date })
            review.startRecording()
            date = start.addingTimeInterval(20)
            review.recordConfirmedOpen(key: key)
            date = start.addingTimeInterval(200)
            let reloaded = UsageReviewModel(defaults: defaults, now: { date })
            #expect(reloaded.isEnabled)
            #expect(reloaded.snapshot.entries.first?.openings == 1)
            #expect(reloaded.snapshot.intervals.first?.endedAt == start.addingTimeInterval(20))
            #expect(reloaded.snapshot.intervals.last?.startedAt == date)
            reloaded.stopRecording()
            let stopped = UsageReviewModel(defaults: defaults, now: { date })
            #expect(!stopped.isEnabled)
            #expect(stopped.snapshot.entries.first?.openings == 1)
        }
    }

    @Test func expiredStorageIsPrunedOnLoadReadAndWrite() throws {
        try withDefaults { defaults in
            var date = start
            let review = UsageReviewModel(defaults: defaults, now: { date })
            review.startRecording()
            review.recordConfirmedOpen(key: key)
            let oldData = try #require(defaults.data(forKey: UsageReviewModel.storageKey))
            date = start.addingTimeInterval(30 * 86_400)
            #expect(review.snapshot.entries.isEmpty)
            let prunedData = try #require(defaults.data(forKey: UsageReviewModel.storageKey))
            #expect(try JSONDecoder().decode(UsageReview.self, from: prunedData).entries.isEmpty)
            defaults.set(oldData, forKey: UsageReviewModel.storageKey)
            let reloaded = UsageReviewModel(defaults: defaults, now: { date })
            #expect(reloaded.snapshot.entries.isEmpty)
            reloaded.recordConfirmedOpen(key: key)
            let written = try #require(defaults.data(forKey: UsageReviewModel.storageKey))
            let archive = try JSONDecoder().decode(UsageReview.self, from: written)
            #expect(archive.entries.first?.openings == 1)
            #expect(archive.entries.first?.days.first?.day == UsageReview.day(containing: date))
        }
    }

    @Test func corruptStorageIsVisibleAndFailsClosedUntilExplicitClear() throws {
        try withDefaults { defaults in
            let corrupt = Data("not a review archive".utf8)
            defaults.set(corrupt, forKey: UsageReviewModel.storageKey)
            let review = UsageReviewModel(defaults: defaults, now: { start })
            #expect(review.storageError != nil)
            #expect(!review.isEnabled)
            review.startRecording()
            review.recordConfirmedOpen(key: key)
            #expect(defaults.data(forKey: UsageReviewModel.storageKey) == corrupt)
            review.clearAll()
            #expect(review.storageError == nil)
            #expect(review.snapshot.lastClearedAt == start)
            #expect(!review.isEnabled)
            review.startRecording()
            review.recordConfirmedOpen(key: key)
            #expect(review.snapshot.entries.first?.openings == 1)
        }
    }

    @Test func clearingStopsAndRemovesAllRetainedItemAndIntervalData() throws {
        try withDefaults { defaults in
            let review = UsageReviewModel(defaults: defaults, now: { start })
            review.startRecording()
            review.refreshMeasurements(from: snapshot(at: start))
            review.recordConfirmedOpen(key: key)
            review.clearAll()
            let reloaded = UsageReviewModel(defaults: defaults, now: { start })
            #expect(!reloaded.isEnabled)
            #expect(reloaded.snapshot.entries.isEmpty)
            #expect(reloaded.snapshot.intervals.isEmpty)
            #expect(reloaded.snapshot.lastClearedAt == start)
        }
    }

    @Test func storesAreIsolatedAndHistoryIsNotASettingsExport() throws {
        try withDefaults { first in
            try withDefaults { second in
                let review = UsageReviewModel(defaults: first, now: { start })
                review.startRecording()
                review.recordConfirmedOpen(key: key)
                let separate = UsageReviewModel(defaults: second, now: { start })
                #expect(!separate.isEnabled)
                #expect(separate.snapshot.entries.isEmpty)
                let settingsData = try JSONEncoder().encode(SettingsStore(defaults: first).load())
                let settingsJSON = try #require(String(data: settingsData, encoding: .utf8))
                #expect(!settingsJSON.contains("openings"))
                #expect(!settingsJSON.contains("test.status"))
                #expect(first.data(forKey: UsageReviewModel.storageKey) != nil)
                #expect(second.data(forKey: UsageReviewModel.storageKey) == nil)
            }
        }
    }

    @Test func existingSnapshotUsesSafeSelectorsNotRowOrdinalsAndDoesNotCountAsOpening() throws {
        try withDefaults { defaults in
            let review = UsageReviewModel(defaults: defaults, now: { start })
            review.startRecording()
            review.refreshMeasurements(from: snapshot(at: start))
            let entry = try #require(review.snapshot.entries.first)
            #expect(entry.key == key)
            #expect(entry.key.ordinal == 0)
            #expect(entry.openings == 0)
            #expect(entry.measurement?.widthPoints == 24)
            #expect(entry.measurement?.displayName == "Built-in")
        }
    }

    @Test func staleFailedAndPreConsentSnapshotsCannotReplaceMeasurements() throws {
        try withDefaults { defaults in
            let review = UsageReviewModel(defaults: defaults, now: { start })
            review.startRecording()
            review.refreshMeasurements(from: snapshot(at: start, isStale: true))
            review.refreshMeasurements(from: snapshot(at: start, scanError: "Scan failed"))
            review.refreshMeasurements(from: snapshot(at: start.addingTimeInterval(-1)))
            #expect(review.snapshot.entries.isEmpty)
            review.refreshMeasurements(from: snapshot(at: start))
            #expect(review.snapshot.entries.first?.measurement?.observedAt == start)
        }
    }

    @Test func ambiguousItemsAreExcludedAndReappearanceKeepsTheOriginalCounts() throws {
        try withDefaults { defaults in
            let review = UsageReviewModel(defaults: defaults, now: { start })
            review.startRecording()
            review.recordConfirmedOpen(key: key)
            let duplicateRows = [row(id: 1), row(id: 2)]
            review.refreshMeasurements(from: ItemsModel(snapshot: duplicateRows, capturedAt: start))
            #expect(review.snapshot.entries.first?.measurement == nil)
            #expect(review.snapshot.entries.count == 1)
            review.refreshMeasurements(from: ItemsModel(snapshot: [], capturedAt: start))
            #expect(review.snapshot.entries.first?.openings == 1)
            review.refreshMeasurements(from: snapshot(at: start))
            #expect(review.snapshot.entries.first?.openings == 1)
            #expect(review.snapshot.entries.first?.measurement != nil)
        }
    }

    @Test func mirroredCopiesProduceOneEntry() throws {
        try withDefaults { defaults in
            let review = UsageReviewModel(defaults: defaults, now: { start })
            review.startRecording()
            let mirrors = ItemsModel(snapshot: [row(id: 1, display: 0), row(id: 2, display: 1)], capturedAt: start)
            review.refreshMeasurements(from: mirrors)
            #expect(review.snapshot.entries.count == 1)
            #expect(review.snapshot.entries.first?.openings == 0)
        }
    }

    private func snapshot(at date: Date, scanError: String? = nil, isStale: Bool = false) -> ItemsModel {
        ItemsModel(
            snapshot: [row(id: 1)],
            displays: [MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))],
            displayNames: ["Built-in"], capturedAt: date, scanError: scanError, isStale: isStale
        )
    }

    private func row(id: UInt32, display: Int = 0) -> MenuBarItemRow {
        MenuBarItemRow(
            item: MenuBarItem(
                windowID: id, ownerName: "Status", ownerPID: 123,
                frame: CGRect(x: 100 + Double(id) * 30, y: 0, width: 24, height: 24),
                isOnScreen: true, bundleID: key.owner, detail: key.detail
            ),
            section: .hidden, visibility: .shown, overlapsNotch: false, barbackRole: nil,
            key: ItemKey(owner: key.owner, detail: key.detail, ordinal: 99), display: display
        )
    }

    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "UsageReviewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }
}
