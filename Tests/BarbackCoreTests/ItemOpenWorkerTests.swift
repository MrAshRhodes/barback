import Foundation
import Testing
@testable import BarbackCore

@Suite("Item open worker", .timeLimit(.minutes(1)))
struct ItemOpenWorkerTests {
    @MainActor @Test func opensAnAvailableItemOffTheMainThread() async {
        let activity = OpenActivity()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { true },
            press: { target in
                activity.recordPress(target)
                return .success(())
            }
        )
        let result = await withCheckedContinuation { continuation in
            worker.open(scan: {
                activity.recordScan()
                return 42
            }) { result in
                continuation.resume(returning: result)
            }
        }
        if case .failure(let error) = result { Issue.record("Unexpected failure: \(error)") }
        #expect(activity.scans == 1)
        #expect(activity.pressed == [42])
        #expect(!activity.usedMainThread)
    }

    @MainActor @Test func cancellationBeforeTheDelayDoesNotScanOrPress() async {
        let activity = OpenActivity()
        let queue = DispatchQueue(label: "test.cancel-before-scan")
        queue.suspend()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0, queue: queue,
            isTrusted: { true },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        var completions = 0
        worker.open(scan: { activity.recordScan(); return 1 }) { _ in completions += 1 }
        worker.cancel()
        queue.resume()
        await drain(queue)
        #expect(activity.scans == 0)
        #expect(activity.pressed.isEmpty)
        #expect(completions == 0)
    }

    @MainActor @Test func cancellationDuringAScanPreventsItsPress() async {
        let activity = OpenActivity()
        let gate = OpenGate()
        let queue = DispatchQueue(label: "test.cancel-during-scan")
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0, queue: queue,
            isTrusted: { true },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        var completions = 0
        worker.open(scan: {
            activity.recordScan()
            gate.pause()
            return 1
        }) { _ in completions += 1 }
        #expect(await gate.waitUntilEntered())
        worker.cancel()
        gate.resume()
        await drain(queue)
        #expect(activity.scans == 1)
        #expect(activity.pressed.isEmpty)
        #expect(completions == 0)
    }

    @MainActor @Test func newerRequestSupersedesAScanningRequest() async {
        let activity = OpenActivity()
        let gate = OpenGate()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { true },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        var completions: [Int] = []
        worker.open(scan: {
            activity.recordScan()
            gate.pause()
            return 1
        }) { _ in completions.append(1) }
        #expect(await gate.waitUntilEntered())
        await withCheckedContinuation { continuation in
            worker.open(scan: { activity.recordScan(); return 2 }) { _ in
                completions.append(2)
                continuation.resume()
            }
            gate.resume()
        }
        #expect(activity.scans == 2)
        #expect(activity.pressed == [2])
        #expect(completions == [2])
    }

    @MainActor @Test func permissionDeniedReportsFailureWithoutScanning() async {
        let activity = OpenActivity()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { false },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        let result = await withCheckedContinuation { continuation in
            worker.open(scan: { activity.recordScan(); return 1 }) {
                continuation.resume(returning: $0)
            }
        }
        expectFailure(result, .permissionRequired)
        #expect(activity.scans == 0)
        #expect(activity.pressed.isEmpty)
    }

    @MainActor @Test func permissionRevokedDuringScanPreventsThePress() async {
        let activity = OpenActivity()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { activity.trusted },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        let result = await withCheckedContinuation { continuation in
            worker.open(scan: {
                activity.recordScan()
                activity.trusted = false
                return 1
            }) { continuation.resume(returning: $0) }
        }
        expectFailure(result, .permissionRequired)
        #expect(activity.scans == 1)
        #expect(activity.pressed.isEmpty)
    }

    @MainActor @Test func missingItemIsRetriedOnceAndCanThenOpen() async {
        let activity = OpenActivity()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { true },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        let result = await withCheckedContinuation { continuation in
            worker.open(scan: {
                activity.recordScan()
                return activity.scans == 1 ? nil : 42
            }) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = result { Issue.record("Unexpected failure: \(error)") }
        #expect(activity.scans == 2)
        #expect(activity.pressed == [42])
    }

    @MainActor @Test func missingItemReportsFinalFailureAfterTwoScans() async {
        let activity = OpenActivity()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { true },
            press: { target in activity.recordPress(target); return .success(()) }
        )
        var completions = 0
        let result = await withCheckedContinuation { continuation in
            worker.open(scan: { activity.recordScan(); return nil }) {
                completions += 1
                continuation.resume(returning: $0)
            }
        }
        expectFailure(result, .unavailable)
        #expect(activity.scans == 2)
        #expect(activity.pressed.isEmpty)
        #expect(completions == 1)
    }

    @MainActor @Test(arguments: [
        ItemOpenError.couldNotOpen, .uncertain, .permissionRequired, .unavailable,
    ])
    func dispatchedActionsAreNeverRetried(error: ItemOpenError) async {
        let activity = OpenActivity()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { true },
            press: { target in activity.recordPress(target); return .failure(error) }
        )
        let result = await withCheckedContinuation { continuation in
            worker.open(scan: { activity.recordScan(); return 1 }) {
                continuation.resume(returning: $0)
            }
        }
        expectFailure(result, error)
        #expect(activity.scans == 1)
        #expect(activity.pressed == [1])
    }

    @MainActor @Test func cancellingAnInFlightActionDoesNotBlockOrDeliverItsResult() async {
        let activity = OpenActivity()
        let gate = OpenGate()
        let worker = ItemOpenWorker<Int>(
            firstDelay: 0, retryDelay: 0,
            isTrusted: { true },
            press: { target in
                activity.recordPress(target)
                if target == 1 { gate.pause() }
                return .success(())
            }
        )
        var completions: [Int] = []
        worker.open(scan: { 1 }) { _ in completions.append(1) }
        #expect(await gate.waitUntilEntered())
        let start = ContinuousClock.now
        worker.cancel()
        #expect(start.duration(to: .now) < .seconds(0.5))
        await withCheckedContinuation { continuation in
            worker.open(scan: { 2 }) { _ in
                completions.append(2)
                continuation.resume()
            }
            gate.resume()
        }
        #expect(activity.pressed == [1, 2])
        #expect(completions == [2])
    }

    private func expectFailure(_ result: Result<Void, ItemOpenError>, _ expected: ItemOpenError) {
        if case .failure(let error) = result { #expect(error == expected) }
        else { Issue.record("Expected failure: \(expected)") }
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await Task.yield()
    }
}

private final class OpenActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var scanCount = 0
    private var targets: [Int] = []
    private var mainThread = false
    private var permission = true

    var scans: Int { lock.withLock { scanCount } }
    var pressed: [Int] { lock.withLock { targets } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    var trusted: Bool {
        get { lock.withLock { permission } }
        set { lock.withLock { permission = newValue } }
    }

    func recordScan() {
        lock.withLock {
            scanCount += 1
            mainThread = mainThread || Thread.isMainThread
        }
    }

    func recordPress(_ target: Int) {
        lock.withLock {
            targets.append(target)
            mainThread = mainThread || Thread.isMainThread
        }
    }
}

private final class OpenGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        _ = released.wait(timeout: .now() + 5)
    }

    func resume() { released.signal() }

    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}
