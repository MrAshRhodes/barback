import Foundation

public enum ItemOpenError: LocalizedError, Equatable, Sendable {
    case permissionRequired
    case unavailable
    case couldNotOpen
    case uncertain

    public var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return String(localized: "Accessibility permission is required to open this item. Enable Barback in System Settings → Privacy & Security → Accessibility, or reveal it and open it manually.")
        case .unavailable:
            return String(localized: "This item is unavailable or cannot be identified safely. Reveal it in the menu bar to open it manually.")
        case .couldNotOpen:
            return String(localized: "macOS could not open this item. Reveal it in the menu bar to open it manually.")
        case .uncertain:
            return String(localized: "macOS did not confirm whether this item opened. It may already be open. Reveal it in the menu bar to check; Barback will not try to open it twice.")
        }
    }
}

/// Serializes blocking scans and actions without blocking the UI. Only a missing target is retried.
@MainActor
public final class ItemOpenWorker<Target: Sendable> {
    private let queue: DispatchQueue
    private let firstDelay: TimeInterval
    private let retryDelay: TimeInterval
    private let isTrusted: @Sendable () -> Bool
    private let press: @Sendable (Target) -> Result<Void, ItemOpenError>
    private var operation: ItemOpenPermit?

    public init(
        firstDelay: TimeInterval = 0.3,
        retryDelay: TimeInterval = 0.4,
        queue: DispatchQueue = DispatchQueue(label: "Barback.ItemOpener", qos: .userInitiated),
        isTrusted: @escaping @Sendable () -> Bool,
        press: @escaping @Sendable (Target) -> Result<Void, ItemOpenError>
    ) {
        self.firstDelay = firstDelay
        self.retryDelay = retryDelay
        self.queue = queue
        self.isTrusted = isTrusted
        self.press = press
    }

    deinit { operation?.cancel() }

    /// Supersedes the previous request. Completion runs once on the main actor for the current request only.
    public func open(
        scan: @escaping @Sendable () -> Target?,
        completion: @escaping @MainActor (Result<Void, ItemOpenError>) -> Void
    ) {
        cancel()
        let permit = ItemOpenPermit()
        operation = permit
        let attempt = ItemOpenAttempt(
            queue: queue, retryDelay: retryDelay, permit: permit,
            isTrusted: isTrusted, scan: scan, press: press
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.operation === permit else { return }
                self.operation = nil
                completion(result)
            }
        }
        attempt.schedule(after: firstDelay, isRetry: false)
    }

    /// Revokes an uncommitted action immediately. An action already committed to AX cannot be retracted.
    public func cancel() {
        operation?.cancel()
        operation = nil
    }
}

/// The lock protects only the action's commit point, never a scan, AX call, or completion.
private final class ItemOpenPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false

    var isCurrent: Bool { lock.withLock { !cancelled } }

    func cancel() { lock.withLock { cancelled = true } }

    func beginAction() -> Bool {
        lock.withLock {
            guard !cancelled, !committed else { return false }
            committed = true
            return true
        }
    }
}

private final class ItemOpenAttempt<Target: Sendable>: Sendable {
    let queue: DispatchQueue
    let retryDelay: TimeInterval
    let permit: ItemOpenPermit
    let isTrusted: @Sendable () -> Bool
    let scan: @Sendable () -> Target?
    let press: @Sendable (Target) -> Result<Void, ItemOpenError>
    let finish: @Sendable (Result<Void, ItemOpenError>) -> Void

    init(
        queue: DispatchQueue,
        retryDelay: TimeInterval,
        permit: ItemOpenPermit,
        isTrusted: @escaping @Sendable () -> Bool,
        scan: @escaping @Sendable () -> Target?,
        press: @escaping @Sendable (Target) -> Result<Void, ItemOpenError>,
        finish: @escaping @Sendable (Result<Void, ItemOpenError>) -> Void
    ) {
        self.queue = queue
        self.retryDelay = retryDelay
        self.permit = permit
        self.isTrusted = isTrusted
        self.scan = scan
        self.press = press
        self.finish = finish
    }

    func schedule(after delay: TimeInterval, isRetry: Bool) {
        queue.asyncAfter(deadline: .now() + delay) { self.run(isRetry: isRetry) }
    }

    private func run(isRetry: Bool) {
        guard permit.isCurrent else { return }
        guard isTrusted() else {
            finish(.failure(.permissionRequired))
            return
        }
        let target = scan()
        guard permit.isCurrent else { return }
        guard let target else {
            if isRetry { finish(.failure(.unavailable)) }
            else { schedule(after: retryDelay, isRetry: true) }
            return
        }
        guard isTrusted() else {
            finish(.failure(.permissionRequired))
            return
        }
        // Once committed, cancellation can suppress the result but cannot undo an in-flight AX press.
        guard permit.beginAction() else { return }
        finish(press(target))
    }
}
