import Foundation

/// One operation may deliver at most one confirmed opening. Failures are terminal, including uncertain AX actions.
public struct UsageReviewConfirmation {
    private let key: ItemKey
    private var finished = false

    public init(key: ItemKey) { self.key = key }

    public mutating func confirmedKey(for result: Result<Void, ItemOpenError>) -> ItemKey? {
        guard !finished else { return nil }
        finished = true
        guard case .success = result, UsageReview.isStableKey(key) else { return nil }
        return key
    }
}

extension ItemOpenWorker {
    /// Opens the item for `key` and reports the key once if Accessibility confirmed the press. A press that a newer
    /// request has superseded is still reported: it opened the item even though its completion is dropped.
    public func open(
        key: ItemKey,
        scan: @escaping @Sendable () -> Target?,
        confirmed: @escaping @MainActor (ItemKey) -> Void,
        completion: @escaping @MainActor (Result<Void, ItemOpenError>) -> Void
    ) {
        var confirmation = UsageReviewConfirmation(key: key)
        open(scan: scan, actionResult: { result in
            if let confirmedKey = confirmation.confirmedKey(for: result) { confirmed(confirmedKey) }
        }, completion: completion)
    }
}

public struct UsageReviewInterval: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
}

public struct UsageReviewDay: Codable, Equatable, Sendable {
    public var day: Date
    public var openings: Int
}

/// Only the latest measured copy is retained, not a history of foreground applications or geometry.
public struct UsageReviewMeasurement: Codable, Equatable, Sendable {
    public var widthPoints: Double
    public var observedAt: Date
    public var displayName: String?
    public var foregroundApp: String?

    public init(widthPoints: Double, observedAt: Date, displayName: String?, foregroundApp: String?) {
        self.widthPoints = widthPoints
        self.observedAt = observedAt
        self.displayName = displayName
        self.foregroundApp = foregroundApp
    }

    public var isValid: Bool {
        widthPoints.isFinite && widthPoints > 0 && observedAt.timeIntervalSince1970.isFinite
    }
}

public struct UsageReviewEntry: Codable, Equatable, Identifiable, Sendable {
    public var key: ItemKey
    public var title: String
    public var days: [UsageReviewDay]
    public var measurement: UsageReviewMeasurement?

    public var id: ItemKey { key }
    public var openings: Int {
        days.reduce(0) { total, day in
            let (sum, overflow) = total.addingReportingOverflow(day.openings)
            return overflow ? Int.max : sum
        }
    }
}

/// Daily UTC aggregates, deliberately separate from settings and their export format.
public struct UsageReview: Codable, Equatable, Sendable {
    public static let retentionDays = 30
    public private(set) var version = 1
    public private(set) var isEnabled = false
    public private(set) var intervals: [UsageReviewInterval] = []
    public private(set) var entries: [UsageReviewEntry] = []
    public private(set) var lastClearedAt: Date?
    public private(set) var lastUpdatedAt: Date?

    public init() {}

    public static func isStableKey(_ key: ItemKey) -> Bool {
        key.ordinal == 0 && !key.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func day(containing date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 86_400) * 86_400)
    }

    /// Today and the preceding 29 UTC dates; daily buckets cannot honestly implement a partial-day cutoff.
    public static func retentionStart(at date: Date) -> Date {
        day(containing: date).addingTimeInterval(-Double(retentionDays - 1) * 86_400)
    }

    public mutating func start(at date: Date) {
        prune(at: date)
        guard !isEnabled else { return }
        isEnabled = true
        intervals.append(UsageReviewInterval(startedAt: date))
        lastUpdatedAt = date
    }

    public mutating func stop(at date: Date) {
        prune(at: date)
        closeInterval(at: date)
        isEnabled = false
        lastUpdatedAt = date
    }

    /// Keeps the user's opt-in while closing the current process's recorded interval.
    public mutating func endSession(at date: Date) {
        prune(at: date)
        closeInterval(at: date)
        lastUpdatedAt = date
    }

    public mutating func resumeAfterLoad(at date: Date) {
        // After an unclean exit the last persisted update is the only defensible endpoint.
        closeInterval(at: min(lastUpdatedAt ?? date, date))
        prune(at: date)
        if isEnabled { intervals.append(UsageReviewInterval(startedAt: date)) }
        if isEnabled { lastUpdatedAt = date }
    }

    public mutating func clear(at date: Date) {
        self = UsageReview()
        lastClearedAt = date
        lastUpdatedAt = date
    }

    public mutating func recordConfirmedOpen(key: ItemKey, at date: Date) {
        prune(at: date)
        guard isEnabled, Self.isStableKey(key), isInCurrentInterval(date) else { return }
        let index = entryIndex(for: key)
        let day = Self.day(containing: date)
        if let bucket = entries[index].days.firstIndex(where: { $0.day == day }) {
            if entries[index].days[bucket].openings < Int.max { entries[index].days[bucket].openings += 1 }
        } else {
            entries[index].days.append(UsageReviewDay(day: day, openings: 1))
        }
        lastUpdatedAt = date
    }

    public mutating func observe(
        key: ItemKey, title: String, measurement: UsageReviewMeasurement?, at date: Date
    ) {
        prune(at: date)
        guard isEnabled, Self.isStableKey(key), isInCurrentInterval(date),
              let measurement, measurement.isValid,
              measurement.observedAt >= Self.retentionStart(at: date),
              measurement.observedAt <= date,
              // A pre-consent snapshot is not part of this recorded period.
              measurement.observedAt >= (intervals.last?.startedAt ?? date) else { return }
        let index = entryIndex(for: key)
        entries[index].title = title
        if entries[index].measurement.map({ $0.observedAt <= measurement.observedAt }) ?? true {
            entries[index].measurement = measurement
        }
        lastUpdatedAt = date
    }

    public mutating func prune(at date: Date) {
        let cutoff = Self.retentionStart(at: date)
        let today = Self.day(containing: date)
        for index in entries.indices {
            entries[index].days.removeAll { $0.day < cutoff || $0.day > today }
            if let measurement = entries[index].measurement,
               measurement.observedAt < cutoff || measurement.observedAt > date {
                entries[index].measurement = nil
            }
        }
        entries.removeAll { $0.days.isEmpty && $0.measurement == nil }
        intervals.removeAll { ($0.endedAt ?? date) < cutoff || $0.startedAt > date }
        for index in intervals.indices {
            intervals[index].startedAt = max(intervals[index].startedAt, cutoff)
        }
        if let lastClearedAt, lastClearedAt < cutoff { self.lastClearedAt = nil }
        if let lastUpdatedAt, lastUpdatedAt < cutoff,
           !intervals.contains(where: { $0.endedAt == nil }) {
            self.lastUpdatedAt = nil
        }
    }

    /// Reject malformed or unsupported archives rather than silently presenting their data as zero.
    public var isValid: Bool {
        guard version == 1, Set(entries.map(\.key)).count == entries.count,
              intervals.filter({ $0.endedAt == nil }).count <= 1,
              isEnabled || intervals.allSatisfy({ $0.endedAt != nil }) else { return false }
        guard lastUpdatedAt != nil || (entries.isEmpty && intervals.isEmpty) else { return false }
        guard entries.isEmpty || !intervals.isEmpty else { return false }
        guard [lastUpdatedAt, lastClearedAt].compactMap({ $0 }).allSatisfy({
            $0.timeIntervalSince1970.isFinite
        }) else { return false }
        for (index, interval) in intervals.enumerated() {
            guard interval.startedAt.timeIntervalSince1970.isFinite else { return false }
            if let end = interval.endedAt {
                guard end.timeIntervalSince1970.isFinite, end >= interval.startedAt else { return false }
            } else if index != intervals.count - 1 { return false }
            if index > 0, let previousEnd = intervals[index - 1].endedAt,
               previousEnd > interval.startedAt { return false }
        }
        return entries.allSatisfy { entry in
            Self.isStableKey(entry.key)
                && Set(entry.days.map(\.day)).count == entry.days.count
                && entry.days.allSatisfy {
                    $0.day.timeIntervalSince1970.isFinite && Self.day(containing: $0.day) == $0.day && $0.openings > 0
                }
                && (entry.measurement?.isValid ?? true)
        }
    }

    private mutating func entryIndex(for key: ItemKey) -> Int {
        if let index = entries.firstIndex(where: { $0.key == key }) { return index }
        let title = [key.owner, key.detail].compactMap { $0 }.joined(separator: " — ")
        entries.append(UsageReviewEntry(key: key, title: title, days: []))
        return entries.count - 1
    }

    private func isInCurrentInterval(_ date: Date) -> Bool {
        guard let interval = intervals.last, interval.endedAt == nil else { return false }
        return date >= interval.startedAt
    }

    private mutating func closeInterval(at date: Date) {
        guard let index = intervals.indices.last, intervals[index].endedAt == nil else { return }
        intervals[index].endedAt = max(intervals[index].startedAt, date)
    }
}
