import Foundation
import Testing
@testable import BarbackCore

@Suite("Local usage review aggregates")
struct UsageReviewTests {
    private let start = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC
    private let key = ItemKey(owner: "test.status", detail: "Status")

    @Test func collectionIsOffUntilExplicitlyStarted() {
        var review = UsageReview()
        review.recordConfirmedOpen(key: key, at: start)
        review.observe(key: key, title: "Status", measurement: measurement(at: start), at: start)
        #expect(!review.isEnabled)
        #expect(review.entries.isEmpty)
        #expect(review.intervals.isEmpty)
        #expect(review.lastUpdatedAt == nil)
        review.start(at: start)
        review.recordConfirmedOpen(key: key, at: start)
        #expect(review.entries.first?.openings == 1)
        #expect(review.intervals.first?.startedAt == start)
    }

    @Test func duplicateCompletionCountsOnceButIndependentOpeningsCountSeparately() {
        var review = UsageReview()
        review.start(at: start)
        var operation = UsageReviewConfirmation(key: key)
        for _ in 0..<3 {
            if let confirmedKey = operation.confirmedKey(for: .success(())) {
                review.recordConfirmedOpen(key: confirmedKey, at: start)
            }
        }
        #expect(review.entries.first?.openings == 1)
        var nextOperation = UsageReviewConfirmation(key: key)
        if let confirmedKey = nextOperation.confirmedKey(for: .success(())) {
            review.recordConfirmedOpen(key: confirmedKey, at: start)
        }
        #expect(review.entries.first?.openings == 2)
        #expect(review.entries.first?.days.count == 1)
    }

    @Test(arguments: [
        ItemOpenError.couldNotOpen, .uncertain, .permissionRequired, .unavailable,
    ])
    func unsuccessfulAndUncertainActionsNeverConfirm(error: ItemOpenError) {
        var operation = UsageReviewConfirmation(key: key)
        #expect(operation.confirmedKey(for: .failure(error)) == nil)
        #expect(operation.confirmedKey(for: .success(())) == nil)
    }

    @MainActor @Test func cancelledOperationCannotReachTheRecordingCallback() async {
        var review = UsageReview()
        review.start(at: start)
        var confirmation = UsageReviewConfirmation(key: key)
        let queue = DispatchQueue(label: "UsageReviewTests.cancelled")
        queue.suspend()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0, queue: queue,
            isTrusted: { true }, press: { _ in .success(()) }
        )
        worker.open(scan: { 1 }) { result in
            if let confirmedKey = confirmation.confirmedKey(for: result) {
                review.recordConfirmedOpen(key: confirmedKey, at: start)
            }
        }
        worker.cancel()
        queue.resume()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await Task.yield()
        #expect(review.entries.isEmpty)
    }

    @Test func positionalOrEmptyKeysAreNotRecorded() {
        var review = UsageReview()
        review.start(at: start)
        for unsafe in [ItemKey(owner: "test.status", ordinal: 1), ItemKey(owner: "  ")] {
            review.recordConfirmedOpen(key: unsafe, at: start)
            review.observe(key: unsafe, title: "Unsafe", measurement: measurement(at: start), at: start)
            var operation = UsageReviewConfirmation(key: unsafe)
            #expect(operation.confirmedKey(for: .success(())) == nil)
        }
        #expect(review.entries.isEmpty)
    }

    @Test func sameDisplayAmbiguityProducesNoHistorySelectors() {
        let items = [
            item(id: 1, x: 100, detail: "Same"),
            item(id: 2, x: 140, detail: "Same"),
        ]
        let selectors = ItemKeyAssigner.panelKeys(for: items) { _ in 0 }
        #expect(selectors.isEmpty)
        var review = UsageReview()
        review.start(at: start)
        for selector in selectors.values {
            review.recordConfirmedOpen(key: selector, at: start)
        }
        #expect(review.entries.isEmpty)
    }

    @Test func latestMeasurementIsNotAClickOrAnActivityTimeline() throws {
        var review = UsageReview()
        review.start(at: start)
        review.observe(key: key, title: "Status", measurement: measurement(at: start), at: start)
        #expect(review.entries.first?.openings == 0)
        let later = start.addingTimeInterval(60)
        review.observe(
            key: key, title: "Status",
            measurement: UsageReviewMeasurement(widthPoints: 42, observedAt: later, displayName: "External", foregroundApp: "Mail"),
            at: later
        )
        #expect(review.entries.count == 1)
        #expect(review.entries.first?.measurement?.foregroundApp == "Mail")
        #expect(review.entries.first?.measurement?.widthPoints == 42)
        let encoded = try JSONEncoder().encode(review)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("Editor"))
        #expect(!json.contains("events"))
    }

    @Test func invalidFutureAndPreConsentMeasurementsAreExcluded() {
        var review = UsageReview()
        review.start(at: start)
        review.observe(key: key, title: "Status", measurement: measurement(at: start.addingTimeInterval(-1)), at: start)
        review.observe(key: key, title: "Status", measurement: measurement(at: start.addingTimeInterval(1)), at: start)
        for width in [0.0, -1.0, Double.nan, Double.infinity] {
            review.observe(
                key: key, title: "Status",
                measurement: UsageReviewMeasurement(widthPoints: width, observedAt: start, displayName: nil, foregroundApp: nil),
                at: start
            )
        }
        #expect(review.entries.isEmpty)
        review.observe(key: key, title: "Status", measurement: measurement(at: start), at: start)
        #expect(review.entries.first?.measurement?.widthPoints == 24)
    }

    @Test func retentionIsExactlyThirtyUTCDateBuckets() {
        var review = UsageReview()
        review.start(at: start)
        review.recordConfirmedOpen(key: key, at: start)
        review.observe(key: key, title: "Status", measurement: measurement(at: start), at: start)
        let thirtiethDay = UsageReview.day(containing: start).addingTimeInterval(29 * 86_400)
        review.prune(at: thirtiethDay)
        #expect(review.entries.first?.openings == 1)
        #expect(review.entries.first?.measurement != nil)
        let nextDay = thirtiethDay.addingTimeInterval(86_400)
        review.prune(at: nextDay)
        #expect(review.entries.isEmpty)
        #expect(review.intervals.first?.startedAt == UsageReview.day(containing: start).addingTimeInterval(86_400))
    }

    @Test func oldDayExpiresWithoutLosingNewDayForSameIdentity() {
        var review = UsageReview()
        review.start(at: start)
        review.recordConfirmedOpen(key: key, at: start)
        let nextDay = start.addingTimeInterval(86_400)
        review.recordConfirmedOpen(key: key, at: nextDay)
        review.prune(at: UsageReview.day(containing: start).addingTimeInterval(30 * 86_400))
        #expect(review.entries.first?.openings == 1)
        #expect(review.entries.first?.days.map(\.day) == [UsageReview.day(containing: nextDay)])
    }

    @Test func stoppedAndClearedMetadataAlsoExpires() {
        var review = UsageReview()
        review.start(at: start)
        review.stop(at: start)
        review.prune(at: start.addingTimeInterval(30 * 86_400))
        #expect(review.intervals.isEmpty)
        #expect(review.lastUpdatedAt == nil)
        review.clear(at: start)
        review.prune(at: start.addingTimeInterval(30 * 86_400))
        #expect(review.lastClearedAt == nil)
        #expect(review.lastUpdatedAt == nil)
        #expect(review.isValid)
    }

    @Test func stoppingResumingAndRelaunchKeepExactSeparateIntervals() throws {
        var review = UsageReview()
        review.start(at: start)
        review.start(at: start.addingTimeInterval(1))
        #expect(review.intervals.count == 1)
        review.recordConfirmedOpen(key: key, at: start.addingTimeInterval(10))
        review.stop(at: start.addingTimeInterval(20))
        review.recordConfirmedOpen(key: key, at: start.addingTimeInterval(25))
        #expect(review.entries.first?.openings == 1)
        review.start(at: start.addingTimeInterval(30))
        review.recordConfirmedOpen(key: key, at: start.addingTimeInterval(40))
        let data = try JSONEncoder().encode(review)
        var reloaded = try JSONDecoder().decode(UsageReview.self, from: data)
        reloaded.resumeAfterLoad(at: start.addingTimeInterval(100))
        #expect(reloaded.isValid)
        #expect(reloaded.entries.first?.openings == 2)
        #expect(reloaded.intervals.count == 3)
        #expect(reloaded.intervals[0].endedAt == start.addingTimeInterval(20))
        #expect(reloaded.intervals[1].endedAt == start.addingTimeInterval(40))
        #expect(reloaded.intervals[2].startedAt == start.addingTimeInterval(100))
        #expect(reloaded.intervals[2].endedAt == nil)
    }

    @Test func orderlyExitClosesIntervalWithoutChangingConsent() {
        var review = UsageReview()
        review.start(at: start)
        review.endSession(at: start.addingTimeInterval(60))
        #expect(review.isEnabled)
        #expect(review.intervals.first?.endedAt == start.addingTimeInterval(60))
        review.resumeAfterLoad(at: start.addingTimeInterval(100))
        #expect(review.intervals.first?.endedAt == start.addingTimeInterval(60))
        #expect(review.intervals.last?.startedAt == start.addingTimeInterval(100))
    }

    @Test func clearingIsDistinctFromZeroAndRequiresNewOptIn() {
        var review = UsageReview()
        review.start(at: start)
        review.observe(key: key, title: "Status", measurement: measurement(at: start), at: start)
        #expect(review.entries.first?.openings == 0)
        let clearedAt = start.addingTimeInterval(60)
        review.clear(at: clearedAt)
        review.recordConfirmedOpen(key: key, at: clearedAt)
        #expect(!review.isEnabled)
        #expect(review.entries.isEmpty)
        #expect(review.intervals.isEmpty)
        #expect(review.lastClearedAt == clearedAt)
        review.start(at: start.addingTimeInterval(100))
        #expect(review.intervals.first?.startedAt == start.addingTimeInterval(100))
        #expect(review.entries.isEmpty)
    }

    @Test func disappearanceDoesNotTransferCountsToAnotherIdentity() {
        var review = UsageReview()
        review.start(at: start)
        review.recordConfirmedOpen(key: key, at: start)
        let other = ItemKey(owner: key.owner, detail: "Other status")
        review.observe(key: other, title: "Other", measurement: measurement(at: start), at: start)
        #expect(review.entries.first(where: { $0.key == other })?.openings == 0)
        review.recordConfirmedOpen(key: key, at: start.addingTimeInterval(1))
        #expect(review.entries.first(where: { $0.key == key })?.openings == 2)
    }

    @Test func malformedArchivesAreRejected() throws {
        var review = UsageReview()
        review.start(at: start)
        review.recordConfirmedOpen(key: key, at: start)
        let data = try JSONEncoder().encode(review)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 999
        let unsupported = try JSONDecoder().decode(UsageReview.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!unsupported.isValid)
        json["version"] = 1
        var entries = try #require(json["entries"] as? [[String: Any]])
        entries += entries
        json["entries"] = entries
        let duplicate = try JSONDecoder().decode(UsageReview.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!duplicate.isValid)
    }

    private func measurement(at date: Date) -> UsageReviewMeasurement {
        UsageReviewMeasurement(widthPoints: 24, observedAt: date, displayName: "Built-in", foregroundApp: "Editor")
    }

    private func item(id: UInt32, x: Double, detail: String) -> MenuBarItem {
        MenuBarItem(
            windowID: id, ownerName: "Status", ownerPID: 1,
            frame: CGRect(x: x, y: 0, width: 24, height: 24), isOnScreen: true,
            bundleID: "test.status", detail: detail
        )
    }
}
