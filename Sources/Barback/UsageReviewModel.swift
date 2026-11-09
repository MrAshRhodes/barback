import Combine
import Foundation
import BarbackCore

@MainActor
final class UsageReviewModel: ObservableObject {
    static let storageKey = "barback.usageReview.v1"

    @Published private(set) var storageError: String?
    private let defaults: UserDefaults
    private let now: () -> Date
    private var archive = UsageReview()

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        guard let stored = defaults.object(forKey: Self.storageKey) else { return }
        guard let data = stored as? Data,
              let decoded = try? JSONDecoder().decode(UsageReview.self, from: data),
              decoded.isValid else {
            storageError = String(localized: "The local review data could not be read. Recording is off. Clear the damaged review data before starting again; your settings are unaffected.")
            return
        }
        archive = decoded
        archive.resumeAfterLoad(at: now())
        persist()
    }

    /// Retention is applied on reads as well as writes, without adding a timer or activity observer.
    var snapshot: UsageReview {
        pruneAndSave()
        return archive
    }

    var isEnabled: Bool { snapshot.isEnabled }

    func startRecording() {
        guard storageError == nil, !archive.isEnabled else { return }
        objectWillChange.send()
        archive.start(at: now())
        persist()
    }

    func stopRecording() {
        guard archive.isEnabled else { return }
        objectWillChange.send()
        archive.stop(at: now())
        persist()
    }

    func clearAll() {
        objectWillChange.send()
        defaults.removeObject(forKey: Self.storageKey)
        archive.clear(at: now())
        storageError = nil
        persist()
    }

    func endSession() {
        guard archive.isEnabled, storageError == nil else { return }
        archive.endSession(at: now())
        persist()
    }

    /// Called only by ItemOpener's once-per-operation, successful AX callback.
    func recordConfirmedOpen(key: ItemKey) {
        guard archive.isEnabled, storageError == nil else { return }
        objectWillChange.send()
        archive.recordConfirmedOpen(key: key, at: now())
        persist()
    }

    /// Consumes the existing successful snapshot only. Never scans or prompts for permissions.
    func refreshMeasurements(from items: ItemsModel) {
        guard archive.isEnabled, storageError == nil,
              !items.snapshotContextIsStale, items.scanError == nil,
              let observedAt = items.lastRefreshed else { return }
        let date = now()
        objectWillChange.send()
        // These keys are safe panel selectors, not the positional keys on ItemsModel.rows.
        // Mirrored copies share one count and contribute just one latest, explicitly labelled measurement.
        var measured = Set<ItemKey>()
        let rows = items.panelCandidates.sorted {
            if $0.display != $1.display { return ($0.display ?? Int.max) < ($1.display ?? Int.max) }
            return $0.id < $1.id
        }
        for row in rows where measured.insert(row.key).inserted {
            let displayName = row.display.flatMap { index in
                items.snapshotDisplayNames.indices.contains(index) ? items.snapshotDisplayNames[index] : nil
            }
            let measurement = UsageReviewMeasurement(
                widthPoints: Double(row.item.frame.width),
                observedAt: observedAt,
                displayName: displayName,
                foregroundApp: items.snapshotFrontmostApp
            )
            let title = [row.panelTitle, row.key.detail == row.panelTitle ? nil : row.key.detail]
                .compactMap { $0 }.joined(separator: " — ")
            archive.observe(key: row.key, title: title, measurement: measurement, at: date)
        }
        archive.prune(at: date)
        persist()
    }

    func refreshRetention() {
        objectWillChange.send()
        pruneAndSave()
    }

    private func pruneAndSave() {
        guard storageError == nil else { return }
        let previous = archive
        archive.prune(at: now())
        if previous != archive { persist() }
    }

    private func persist() {
        guard storageError == nil else { return }
        archive.prune(at: now())
        do {
            let data = try JSONEncoder().encode(archive)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            archive.stop(at: now())
            storageError = String(localized: "The local review data could not be saved. Recording has stopped. Clear the review data to start a new period.")
        }
    }
}
