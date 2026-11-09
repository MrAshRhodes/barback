import Foundation
import CoreGraphics

/// Read-only, snapshot-local measurements. All coordinates and widths are logical points.
public enum SpacePlanner {
    public struct Interval: Equatable, Sendable {
        public let lowerBound: CGFloat
        public let upperBound: CGFloat
        public var width: CGFloat { max(0, upperBound - lowerBound) }

        public init(_ lowerBound: CGFloat, _ upperBound: CGFloat) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }
    }

    public struct Observation: Equatable, Sendable {
        public let windowID: UInt32
        /// Nil means unidentified; a system host's name is not an item's identity.
        public let name: String?
        public let frame: CGRect?
        public let isOnScreen: Bool

        public init(windowID: UInt32, name: String? = nil, frame: CGRect?, isOnScreen: Bool = true) {
            self.windowID = windowID
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.name = trimmed?.isEmpty == false ? trimmed : nil
            self.frame = frame
            self.isOnScreen = isOnScreen
        }

        public init(item: MenuBarItem) {
            func nonempty(_ value: String?) -> String? {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            let name: String?
            if item.isSystemItem, let detail = nonempty(item.detail) {
                name = detail
            } else if let resolved = nonempty(item.resolvedName) {
                name = resolved
            } else if item.isHostedBySystem {
                name = nonempty(item.title)
            } else {
                let owner = nonempty(item.ownerName)
                name = owner == "Unknown" ? nil : owner
            }
            self.init(windowID: item.windowID, name: name, frame: item.frame, isOnScreen: item.isOnScreen)
        }
    }

    public enum Placement: Equatable, Sendable {
        case measured
        case unavailableFrame
        case notOnScreen
        case unknownDisplay
        case ambiguousDisplay
        case outsideMenuBar
        case crossesDisplayEdge
        case unavailableDisplayGeometry
        case overlapsNotch
        case overlapsApplicationMenus
    }

    public struct Measurement: Identifiable, Equatable, Sendable {
        /// An index in this snapshot, not an app identity or a persistent selector.
        public let id: Int
        public let observation: Observation
        public let width: CGFloat?
        public let displayIndex: Int?
        public let regionIndex: Int?
        public let localInterval: Interval?
        public let placement: Placement
        public var canExclude: Bool { placement == .measured }
    }

    public struct Region: Identifiable, Equatable, Sendable {
        public let id: Int
        /// Display-local, physically clear of the notch; not necessarily available to status items.
        public let safeInterval: Interval
        /// Nil unless a measured application-menu boundary was supplied.
        public let usableInterval: Interval?
        public let observedInterval: Interval?
        public let measurementIDs: [Int]
    }

    public struct Display: Identifiable, Equatable, Sendable {
        public let id: Int
        public let frame: CGRect
        public let notch: Interval?
        public let geometryAvailable: Bool
        public let regions: [Region]
    }

    public struct Snapshot: Equatable, Sendable {
        public let displays: [Display]
        public let measurements: [Measurement]

        public var hasPartialData: Bool {
            displays.isEmpty
                || displays.contains { !$0.geometryAvailable || $0.regions.contains { $0.usableInterval == nil } }
                || measurements.contains { $0.placement != .measured || $0.observation.name == nil }
        }

        /// Ranking is independent for each display. Nil selects measurements with no reliable display.
        public func rankedMeasurements(on displayIndex: Int?) -> [Measurement] {
            measurements.filter { $0.displayIndex == displayIndex }.sorted {
                switch ($0.width, $1.width) {
                case let (left?, right?): return left == right ? $0.id < $1.id : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.id < $1.id
                }
            }
        }

        public func comparison(in region: Region, preview: Preview) -> Comparison {
            let ids = Set(region.measurementIDs)
            let before = measurements.filter { ids.contains($0.id) }
            let kept = before.filter { !preview.excludedIDs.contains($0.id) }
            let excluded = before.filter { preview.excludedIDs.contains($0.id) }
            let beforeWidth = before.reduce(CGFloat.zero) { $0 + ($1.width ?? 0) }
            let afterWidth = kept.reduce(CGFloat.zero) { $0 + ($1.width ?? 0) }
            let beforeFootprint = SpacePlanner.unionWidth(before.compactMap(\.localInterval))
            let afterFootprint = SpacePlanner.unionWidth(kept.compactMap(\.localInterval))
            return Comparison(
                beforeCount: before.count, afterCount: kept.count,
                beforeMeasuredWidth: beforeWidth, afterMeasuredWidth: afterWidth,
                excludedMeasuredWidth: excluded.reduce(0) { $0 + ($1.width ?? 0) },
                beforeOccupiedWidth: beforeFootprint, afterOccupiedWidth: afterFootprint,
                estimatedUnoccupiedBefore: region.usableInterval.map { max(0, $0.width - beforeFootprint) },
                estimatedUnoccupiedAfter: region.usableInterval.map { max(0, $0.width - afterFootprint) }
            )
        }
    }

    public struct Preview: Equatable, Sendable {
        public private(set) var excludedIDs: Set<Int> = []

        public init() {}

        public mutating func setExcluded(_ excluded: Bool, measurement: Measurement) {
            guard measurement.canExclude else { return }
            if excluded {
                excludedIDs.insert(measurement.id)
            } else {
                excludedIDs.remove(measurement.id)
            }
        }

        public mutating func reset() { excludedIDs.removeAll() }
    }

    public struct Comparison: Equatable, Sendable {
        public let beforeCount: Int
        public let afterCount: Int
        /// Sums of individual window widths, which can overlap.
        public let beforeMeasuredWidth: CGFloat
        public let afterMeasuredWidth: CGFloat
        public let excludedMeasuredWidth: CGFloat
        /// Union widths at the observed positions, without double-counting overlaps.
        public let beforeOccupiedWidth: CGFloat
        public let afterOccupiedWidth: CGFloat
        /// Unknown without a measured application-menu boundary; never a placement guarantee.
        public let estimatedUnoccupiedBefore: CGFloat?
        public let estimatedUnoccupiedAfter: CGFloat?
    }

    /// Input display, notch, item and optional application-menu boundary coordinates must all be global
    /// CoreGraphics points. AppKit screen rectangles must be converted by the caller before entering here.
    /// No screen scale factor is applied. Output intervals are local to the individual display's left edge.
    public static func snapshot(
        observations: [Observation],
        displays: [MenuBarDisplay],
        applicationMenuBoundaries: [Int: CGFloat] = [:]
    ) -> Snapshot {
        let geometryPlans = displays.enumerated().map { index, display in
            geometry(for: display, index: index, boundary: applicationMenuBoundaries[index])
        }
        let measurements = observations.enumerated().map { index, observation in
            measure(observation, id: index, displays: displays, geometry: geometryPlans)
        }
        let plans = geometryPlans.map { display in
            Display(
                id: display.id, frame: display.frame, notch: display.notch,
                geometryAvailable: display.geometryAvailable,
                regions: display.regions.map { region in
                    let members = measurements.filter {
                        $0.displayIndex == display.id && $0.regionIndex == region.id && $0.canExclude
                    }
                    let intervals = members.compactMap(\.localInterval)
                    let observed: Interval?
                    if let lower = intervals.map(\.lowerBound).min(), let upper = intervals.map(\.upperBound).max() {
                        observed = Interval(lower, upper)
                    } else {
                        observed = nil
                    }
                    return Region(
                        id: region.id, safeInterval: region.safeInterval, usableInterval: region.usableInterval,
                        observedInterval: observed, measurementIDs: members.map(\.id)
                    )
                }
            )
        }
        return Snapshot(displays: plans, measurements: measurements)
    }

    private static func geometry(for display: MenuBarDisplay, index: Int, boundary: CGFloat?) -> Display {
        func unavailable() -> Display {
            Display(id: index, frame: display.frame, notch: nil, geometryAvailable: false, regions: [])
        }
        guard valid(display.frame) else { return unavailable() }
        let width = display.frame.width
        var notch: Interval?
        if let frame = display.notch {
            guard valid(frame), frame.minX >= display.frame.minX, frame.maxX <= display.frame.maxX,
                  frame.minY <= display.frame.minY + 1, frame.maxY > display.frame.minY else {
                return unavailable()
            }
            notch = Interval(frame.minX - display.frame.minX, frame.maxX - display.frame.minX)
        }
        let safe: [Interval]
        if let notch {
            safe = [Interval(0, notch.lowerBound), Interval(notch.upperBound, width)].filter { $0.width > 0 }
        } else {
            safe = [Interval(0, width)]
        }
        let localBoundary: CGFloat?
        if let boundary, boundary.isFinite, boundary >= display.frame.minX, boundary <= display.frame.maxX {
            localBoundary = boundary - display.frame.minX
        } else {
            localBoundary = nil
        }
        return Display(
            id: index, frame: display.frame, notch: notch, geometryAvailable: true,
            regions: safe.enumerated().map { regionIndex, interval in
                Region(
                    id: regionIndex, safeInterval: interval,
                    usableInterval: localBoundary.map {
                        Interval(min(interval.upperBound, max(interval.lowerBound, $0)), interval.upperBound)
                    },
                    observedInterval: nil, measurementIDs: []
                )
            }
        )
    }

    private static func measure(
        _ observation: Observation, id: Int, displays: [MenuBarDisplay], geometry: [Display]
    ) -> Measurement {
        var width: CGFloat?
        var displayIndex: Int?
        var localInterval: Interval?
        func result(_ placement: Placement, region: Int? = nil) -> Measurement {
            Measurement(
                id: id, observation: observation, width: width,
                displayIndex: displayIndex, regionIndex: region, localInterval: localInterval, placement: placement
            )
        }
        guard let frame = observation.frame, valid(frame) else { return result(.unavailableFrame) }
        width = frame.width
        let candidates = displays.indices.filter {
            let display = displays[$0].frame
            return valid(display) && abs(frame.minY - display.minY) <= 1
                && frame.minX < display.maxX && frame.maxX > display.minX
        }
        guard candidates.count <= 1 else { return result(.ambiguousDisplay) }
        guard let index = candidates.first else {
            if !observation.isOnScreen { return result(.notOnScreen) }
            let onADisplay = displays.contains { valid($0.frame) && $0.frame.intersects(frame) }
            return result(onADisplay ? .outsideMenuBar : .unknownDisplay)
        }
        displayIndex = index
        localInterval = Interval(frame.minX - displays[index].frame.minX, frame.maxX - displays[index].frame.minX)
        guard observation.isOnScreen else { return result(.notOnScreen) }
        guard frame.height <= MenuBarItemParser.maxItemHeight else { return result(.outsideMenuBar) }
        guard frame.minX >= displays[index].frame.minX, frame.maxX <= displays[index].frame.maxX,
              frame.maxY <= displays[index].frame.maxY else { return result(.crossesDisplayEdge) }
        guard geometry[index].geometryAvailable else { return result(.unavailableDisplayGeometry) }
        guard let interval = localInterval,
              let region = geometry[index].regions.first(where: {
                  interval.lowerBound >= $0.safeInterval.lowerBound && interval.upperBound <= $0.safeInterval.upperBound
              }) else { return result(.overlapsNotch) }
        if let usable = region.usableInterval, interval.lowerBound < usable.lowerBound {
            return result(.overlapsApplicationMenus)
        }
        return result(.measured, region: region.id)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    private static func unionWidth(_ intervals: [Interval]) -> CGFloat {
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return 0 }
        var width: CGFloat = 0
        for interval in sorted.dropFirst() {
            if interval.lowerBound <= current.upperBound {
                current = Interval(current.lowerBound, max(current.upperBound, interval.upperBound))
            } else {
                width += current.width
                current = interval
            }
        }
        return width + current.width
    }
}
