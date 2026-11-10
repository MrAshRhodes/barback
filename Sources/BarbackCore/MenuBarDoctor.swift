import Foundation
import CoreGraphics

/// Read-only evidence from requested menu-bar snapshots; none of these states establish a root cause.
public enum MenuBarDoctor {
    public static let currentEvidenceLifetime: TimeInterval = 120

    public struct Entry: Equatable, Sendable {
        public var item: MenuBarItem
        public var section: MenuBarSection
        public var visibility: ItemVisibility
        public var display: Int?

        public init(item: MenuBarItem, section: MenuBarSection, visibility: ItemVisibility, display: Int?) {
            self.item = item
            self.section = section
            self.visibility = visibility
            self.display = display
        }
    }

    public struct Snapshot: Sendable {
        public var entries: [Entry]
        public var displays: [MenuBarDisplay]
        public var displayNames: [String]
        public var scannedAt: Date?
        public var attemptedAt: Date
        public var failure: String?
        public var accessibilityTrusted: Bool
        public var contextIsStale: Bool
        public var sectionState: SectionState?
        public var frontmostApp: String?
        public var runningBundleIDs: Set<String>

        public init(
            entries: [Entry] = [], displays: [MenuBarDisplay] = [], displayNames: [String] = [],
            scannedAt: Date? = nil, attemptedAt: Date, failure: String? = nil,
            accessibilityTrusted: Bool = false, contextIsStale: Bool = false,
            sectionState: SectionState? = nil, frontmostApp: String? = nil,
            runningBundleIDs: Set<String> = []
        ) {
            self.entries = entries
            self.displays = displays
            self.displayNames = displayNames
            self.scannedAt = scannedAt
            self.attemptedAt = attemptedAt
            self.failure = failure
            self.accessibilityTrusted = accessibilityTrusted
            self.contextIsStale = contextIsStale
            self.sectionState = sectionState
            self.frontmostApp = frontmostApp
            self.runningBundleIDs = runningBundleIDs
        }

        /// These are the same conservative selectors used by panels, including undrawn windows.
        /// Ordinary scan keys and window positions are deliberately never accepted as identities.
        public var reliableKeys: [UInt32: ItemKey] {
            let indices = Dictionary(entries.map { ($0.item.windowID, $0.display) }, uniquingKeysWith: { first, _ in first })
            return ItemKeyAssigner.panelKeys(for: entries.map(\.item)) { indices[$0.windowID] ?? nil }
        }
    }

    public enum EvidenceStatus: Equatable, Sendable {
        case current, stale, failed, notScanned
    }

    public enum Presence: Equatable, Sendable {
        case observed, notObserved, ambiguous, unknown
    }

    public enum Confidence: Equatable, Sendable {
        case identified, limited, unknown
    }

    public enum HiddenState: Equatable, Sendable {
        case hiddenSectionCollapsed, alwaysHiddenSectionCollapsed, sectionRevealed, notManaged, unknown
    }

    public enum NotchClue: Equatable, Sendable {
        case geometryUnavailable, noNotch, clearOfNotch, overlapsNotch, outsideDisplay
    }

    public struct GeometryEvidence: Equatable, Sendable {
        public var notch: NotchClue
        /// nil means peer geometry was unavailable; false is not a claim that the whole menu bar fits.
        public var overlapsCapturedPeer: Bool?
    }

    public struct Observation: Equatable, Sendable {
        public var key: ItemKey
        public var title: String
        public var observedAt: Date
        public var entry: Entry
        public var displayName: String?
        public var display: MenuBarDisplay?
        public var hiddenState: HiddenState
        public var geometry: GeometryEvidence
        public var frontmostApp: String?
    }

    public struct Report: Sendable {
        public var status: EvidenceStatus
        public var presence: Presence
        public var confidence: Confidence
        public var current: Observation?
        public var previous: Observation?
        public var sourceBundleID: String?
        /// Application state at the requested check, not an inference about icon state.
        public var sourceAppRunning: Bool?
        public var unidentifiedCount: Int

        public var lastObservedAt: Date? { current?.observedAt ?? previous?.observedAt }
    }

    public struct Target: Identifiable, Equatable, Sendable {
        public var key: ItemKey
        public var title: String
        public var isSaved: Bool
        public var wasPreviouslyObserved: Bool
        public var id: ItemKey { key }
    }

    public static func status(of snapshot: Snapshot?, now: Date) -> EvidenceStatus {
        guard let snapshot else { return .notScanned }
        if snapshot.failure != nil { return .failed }
        guard let scannedAt = snapshot.scannedAt else { return .notScanned }
        let age = now.timeIntervalSince(scannedAt)
        if snapshot.contextIsStale || age < 0 || age > currentEvidenceLifetime { return .stale }
        return .current
    }

    public static func report(
        for key: ItemKey, snapshot: Snapshot?, history: MenuBarDoctorHistory, now: Date
    ) -> Report {
        let status = status(of: snapshot, now: now)
        let previous = history.observation(for: key, now: now)
        let keys = snapshot?.reliableKeys ?? [:]
        let unidentified = snapshot?.entries.filter { keys[$0.item.windowID] == nil }.count ?? 0
        var current: Observation?
        var presence: Presence = .unknown
        if status == .current, let snapshot {
            let matches = snapshot.entries.filter { keys[$0.item.windowID] == key }
            if let entry = matches.first(where: { $0.visibility == .shown }) ?? matches.first {
                current = observation(key: key, entry: entry, snapshot: snapshot)
                presence = .observed
            } else if key.ordinal != 0 || snapshot.entries.contains(where: {
                let identity = ItemKeyAssigner.identity(of: $0.item)
                return identity.owner == key.owner
                    && (identity.detail == key.detail || key.detail == nil || identity.detail == nil)
            }) {
                presence = .ambiguous
            } else {
                presence = .notObserved
            }
        }
        let source = sourceBundleID(for: current ?? previous)
        let confidence: Confidence
        if status != .current || presence == .ambiguous {
            confidence = .unknown
        } else if snapshot?.accessibilityTrusted != true || unidentified > 0 || current == nil {
            confidence = .limited
        } else {
            confidence = .identified
        }
        return Report(
            status: status, presence: presence, confidence: confidence, current: current, previous: previous,
            sourceBundleID: source,
            sourceAppRunning: source.flatMap { bundle in snapshot.map { $0.runningBundleIDs.contains(bundle) } },
            unidentifiedCount: unidentified
        )
    }

    public static func targets(
        snapshot: Snapshot?, savedKeys: [ItemKey], history: MenuBarDoctorHistory, now: Date
    ) -> [Target] {
        let saved = Set(savedKeys)
        var result: [ItemKey: Target] = [:]
        for key in saved {
            result[key] = Target(key: key, title: savedTitle(key), isSaved: true, wasPreviouslyObserved: false)
        }
        for observation in history.observations(now: now) {
            result[observation.key] = Target(
                key: observation.key, title: observation.title,
                isSaved: saved.contains(observation.key), wasPreviouslyObserved: true
            )
        }
        if let snapshot, snapshot.failure == nil, snapshot.scannedAt != nil {
            let keys = snapshot.reliableKeys
            for entry in snapshot.entries {
                guard let key = keys[entry.item.windowID] else { continue }
                result[key] = Target(
                    key: key, title: title(entry.item), isSaved: saved.contains(key),
                    wasPreviouslyObserved: result[key]?.wasPreviouslyObserved ?? false
                )
            }
        }
        return result.values.sorted {
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return savedTitle($0.key) < savedTitle($1.key)
        }
    }

    public static func sourceBundleID(for observation: Observation?) -> String? {
        guard let bundle = observation?.entry.item.bundleID,
              !bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !MenuBarItemParser.systemHostBundleIDs.contains(bundle.lowercased()),
              observation?.key.owner == bundle else { return nil }
        return bundle
    }

    public static func geometry(for entry: Entry, in snapshot: Snapshot) -> GeometryEvidence {
        guard usable(entry.item.frame),
              let index = entry.display, snapshot.displays.indices.contains(index),
              usable(snapshot.displays[index].frame) else {
            return GeometryEvidence(notch: .geometryUnavailable, overlapsCapturedPeer: nil)
        }
        let display = snapshot.displays[index]
        guard entry.visibility == .shown, entry.item.isOnScreen,
              overlaps(display.frame, entry.item.frame) else {
            return GeometryEvidence(notch: .outsideDisplay, overlapsCapturedPeer: nil)
        }
        let peers = snapshot.entries.filter {
            $0.item.windowID != entry.item.windowID && $0.display == index && $0.visibility == .shown
        }
        let overlap: Bool? = peers.allSatisfy({ usable($0.item.frame) })
            ? peers.contains { overlaps($0.item.frame, entry.item.frame) } : nil
        guard let notch = display.notch else {
            return GeometryEvidence(notch: .noNotch, overlapsCapturedPeer: overlap)
        }
        guard usable(notch), overlaps(display.frame, notch) else {
            return GeometryEvidence(notch: .geometryUnavailable, overlapsCapturedPeer: overlap)
        }
        return GeometryEvidence(
            notch: overlaps(notch, entry.item.frame) ? .overlapsNotch : .clearOfNotch,
            overlapsCapturedPeer: overlap
        )
    }

    public static func hiddenState(section: MenuBarSection, state: SectionState?) -> HiddenState {
        switch section {
        case .unknown: return .unknown
        case .visible: return .notManaged
        case .hidden:
            guard let state else { return .unknown }
            return state == .hidden ? .hiddenSectionCollapsed : .sectionRevealed
        case .alwaysHidden:
            guard let state else { return .unknown }
            return state == .shownAll ? .sectionRevealed : .alwaysHiddenSectionCollapsed
        }
    }

    static func observation(key: ItemKey, entry: Entry, snapshot: Snapshot) -> Observation? {
        guard let date = snapshot.scannedAt else { return nil }
        let display = entry.display.flatMap { snapshot.displays.indices.contains($0) ? snapshot.displays[$0] : nil }
        let name = entry.display.flatMap { snapshot.displayNames.indices.contains($0) ? snapshot.displayNames[$0] : nil }
        return Observation(
            key: key, title: title(entry.item), observedAt: date, entry: entry, displayName: name,
            display: display, hiddenState: hiddenState(section: entry.section, state: snapshot.sectionState),
            geometry: geometry(for: entry, in: snapshot), frontmostApp: snapshot.frontmostApp
        )
    }

    private static func title(_ item: MenuBarItem) -> String {
        if let detail = item.detail, !detail.isEmpty, detail != item.panelName { return "\(item.panelName) — \(detail)" }
        return item.panelName
    }

    private static func savedTitle(_ key: ItemKey) -> String {
        let base = key.detail.map { "\(key.owner) — \($0)" } ?? key.owner
        return key.ordinal == 0 ? base : "\(base) (legacy position \(key.ordinal + 1))"
    }

    private static func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    private static func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

/// One latest reliable observation per identity, held only for this process's lifetime.
public struct MenuBarDoctorHistory: Sendable {
    public static let maximumCount = 256
    public static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private var latest: [ItemKey: MenuBarDoctor.Observation] = [:]

    public init() {}

    public mutating func record(_ snapshot: MenuBarDoctor.Snapshot, now: Date) {
        latest = latest.filter { isRecent($0.value, now: now) }
        guard snapshot.failure == nil, let date = snapshot.scannedAt,
              date <= now, now.timeIntervalSince(date) <= Self.maximumAge else { return }
        let keys = snapshot.reliableKeys
        let ordered = snapshot.entries.filter { $0.visibility != .shown } + snapshot.entries.filter { $0.visibility == .shown }
        for entry in ordered {
            guard let key = keys[entry.item.windowID],
                  let observation = MenuBarDoctor.observation(key: key, entry: entry, snapshot: snapshot),
                  latest[key].map({ $0.observedAt <= date }) ?? true else { continue }
            latest[key] = observation
        }
        if latest.count > Self.maximumCount {
            let keep = latest.values.sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
                if $0.key.owner != $1.key.owner { return $0.key.owner < $1.key.owner }
                return ($0.key.detail ?? "") < ($1.key.detail ?? "")
            }.prefix(Self.maximumCount)
            latest = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
        }
    }

    public func observation(for key: ItemKey, now: Date) -> MenuBarDoctor.Observation? {
        latest[key].flatMap { isRecent($0, now: now) ? $0 : nil }
    }

    public func observations(now: Date) -> [MenuBarDoctor.Observation] {
        latest.values.filter { isRecent($0, now: now) }
    }

    private func isRecent(_ observation: MenuBarDoctor.Observation, now: Date) -> Bool {
        let age = now.timeIntervalSince(observation.observedAt)
        return age >= 0 && age <= Self.maximumAge
    }
}
