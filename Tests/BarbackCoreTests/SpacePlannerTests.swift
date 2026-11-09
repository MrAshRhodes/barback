import Foundation
import CoreGraphics
import Testing
@testable import BarbackCore

@Suite("Space planner")
struct SpacePlannerTests {
    private let screen = MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))

    private func item(
        _ id: UInt32, x: CGFloat, width: CGFloat, y: CGFloat = 0,
        name: String? = "Example", isOnScreen: Bool = true
    ) -> SpacePlanner.Observation {
        .init(windowID: id, name: name, frame: CGRect(x: x, y: y, width: width, height: 24), isOnScreen: isOnScreen)
    }

    @Test func unknownMenuBoundaryNeverMakesDisplayWidthUsableCapacity() throws {
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: 1100, width: 24), item(2, x: 1140, width: 36)],
            displays: [screen]
        )
        let region = try #require(snapshot.displays.first?.regions.first)
        #expect(region.safeInterval == .init(0, 1200))
        #expect(region.observedInterval == .init(1100, 1176))
        #expect(region.usableInterval == nil)
        #expect(snapshot.hasPartialData)
        let comparison = snapshot.comparison(in: region, preview: .init())
        #expect(comparison.beforeMeasuredWidth == 60)
        #expect(comparison.beforeOccupiedWidth == 60)
        #expect(comparison.estimatedUnoccupiedBefore == nil)
        #expect(comparison.estimatedUnoccupiedAfter == nil)
    }

    @Test func notchSeparatesRegionsAndExclusionsNeverReclaimSpaceOnTheOtherSide() throws {
        let notched = MenuBarDisplay(frame: screen.frame, notch: CGRect(x: 500, y: 0, width: 180, height: 32))
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: 450, width: 40), item(2, x: 700, width: 35), item(3, x: 490, width: 30)],
            displays: [notched],
            applicationMenuBoundaries: [0: 400]
        )
        let display = try #require(snapshot.displays.first)
        #expect(display.regions.map(\.safeInterval) == [.init(0, 500), .init(680, 1200)])
        #expect(display.regions.map(\.usableInterval) == [.init(400, 500), .init(680, 1200)])
        #expect(snapshot.measurements[2].placement == .overlapsNotch)
        #expect(snapshot.measurements[2].width == 30)
        #expect(!snapshot.measurements[2].canExclude)
        var preview = SpacePlanner.Preview()
        preview.setExcluded(true, measurement: snapshot.measurements[0])
        let left = snapshot.comparison(in: display.regions[0], preview: preview)
        let right = snapshot.comparison(in: display.regions[1], preview: preview)
        #expect(left.excludedMeasuredWidth == 40)
        #expect(left.estimatedUnoccupiedAfter == 100)
        #expect(right.excludedMeasuredWidth == 0)
        #expect(right.beforeMeasuredWidth == right.afterMeasuredWidth)
        #expect(right.estimatedUnoccupiedBefore == 485)
        #expect(right.estimatedUnoccupiedAfter == 485)
    }

    @Test func geometryUsesPointsAndDisplayLocalCoordinatesAtDifferentOrigins() throws {
        let external = MenuBarDisplay(
            frame: CGRect(x: -1600, y: -900, width: 1600, height: 900),
            notch: CGRect(x: -900, y: -900, width: 160, height: 32)
        )
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: -700, width: 24.5, y: -900), item(2, x: 1100, width: 30.25)],
            displays: [screen, external],
            applicationMenuBoundaries: [1: -1200]
        )
        #expect(snapshot.measurements[0].displayIndex == 1)
        #expect(snapshot.measurements[0].localInterval == .init(900, 924.5))
        #expect(snapshot.measurements[0].width == 24.5)
        #expect(snapshot.measurements[1].displayIndex == 0)
        #expect(snapshot.measurements[1].localInterval == .init(1100, 1130.25))
        let plan = try #require(snapshot.displays.last)
        #expect(plan.notch == .init(700, 860))
        #expect(plan.regions.map(\.safeInterval) == [.init(0, 700), .init(860, 1600)])
        #expect(plan.regions.map(\.usableInterval) == [.init(400, 700), .init(860, 1600)])
        #expect(snapshot.rankedMeasurements(on: 0).map(\.observation.windowID) == [2])
        #expect(snapshot.rankedMeasurements(on: 1).map(\.observation.windowID) == [1])
    }

    @Test func verticallyStackedDisplaysDoNotShareMeasurements() {
        let above = MenuBarDisplay(frame: CGRect(x: 0, y: -800, width: 1200, height: 800))
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: 1100, width: 20), item(2, x: 1100, width: 30, y: -800)],
            displays: [screen, above]
        )
        #expect(snapshot.measurements.map(\.displayIndex) == [0, 1])
        #expect(snapshot.displays[0].regions[0].measurementIDs == [0])
        #expect(snapshot.displays[1].regions[0].measurementIDs == [1])
    }

    @Test func smallAndLargeMeasuredRegionsDoNotShareCapacity() {
        for (boundary, expected) in [(CGFloat(1190), CGFloat(2)), (CGFloat(200), CGFloat(992))] {
            let snapshot = SpacePlanner.snapshot(
                observations: [item(1, x: 1192, width: 8)], displays: [screen],
                applicationMenuBoundaries: [0: boundary]
            )
            let region = snapshot.displays[0].regions[0]
            let comparison = snapshot.comparison(in: region, preview: .init())
            #expect(comparison.estimatedUnoccupiedBefore == expected)
            #expect(comparison.estimatedUnoccupiedAfter == expected)
        }
        let zero = SpacePlanner.snapshot(observations: [], displays: [screen], applicationMenuBoundaries: [0: 1200])
        #expect(zero.displays[0].regions[0].usableInterval?.width == 0)
        #expect(zero.comparison(in: zero.displays[0].regions[0], preview: .init()).estimatedUnoccupiedBefore == 0)
    }

    @Test func invalidOrMissingMenuBoundariesDoNotBecomeEstimates() {
        for boundary in [CGFloat.nan, .infinity, -1, 1201] {
            let snapshot = SpacePlanner.snapshot(
                observations: [item(1, x: 1100, width: 24)], displays: [screen],
                applicationMenuBoundaries: [0: boundary]
            )
            #expect(snapshot.displays[0].regions[0].usableInterval == nil)
            #expect(snapshot.measurements[0].canExclude)
        }
    }

    @Test func unknownIdentitiesKeepTheirMeasuredRankingAndUnavailableWidthsStayDistinct() {
        let snapshot = SpacePlanner.snapshot(
            observations: [
                item(1, x: 1100, width: 20),
                item(2, x: 1000, width: 80, name: nil),
                item(3, x: 1150, width: 20, name: "   "),
                .init(windowID: 4, name: "Known app", frame: nil),
            ],
            displays: [screen]
        )
        #expect(snapshot.rankedMeasurements(on: 0).map(\.observation.windowID) == [2, 1, 3])
        #expect(snapshot.measurements[1].observation.name == nil)
        #expect(snapshot.measurements[2].observation.name == nil)
        #expect(snapshot.measurements[1].canExclude)
        #expect(snapshot.measurements[3].width == nil)
        #expect(snapshot.rankedMeasurements(on: nil).map(\.observation.windowID) == [4])
    }

    @Test func systemHostsAreNotInventedIdentitiesAndDoNotBlockMeasurement() {
        let hosted = MenuBarItem(
            windowID: 1, ownerName: "Control Center", ownerPID: 20,
            frame: CGRect(x: 1100, y: 0, width: 24, height: 24), isOnScreen: true
        )
        var identified = hosted
        identified.windowID = 2
        identified.resolvedName = "Weather"
        identified.bundleID = "example.weather"
        let snapshot = SpacePlanner.snapshot(observations: [.init(item: hosted), .init(item: identified)], displays: [screen])
        #expect(snapshot.measurements[0].observation.name == nil)
        #expect(snapshot.measurements[0].width == 24)
        #expect(snapshot.measurements[0].canExclude)
        #expect(snapshot.measurements[1].observation.name == "Weather")
        var emptyIdentity = hosted
        emptyIdentity.resolvedName = "  "
        emptyIdentity.title = ""
        #expect(SpacePlanner.Observation(item: emptyIdentity).name == nil)
        var systemItem = hosted
        systemItem.detail = "Wi-Fi"
        #expect(SpacePlanner.Observation(item: systemItem).name == "Wi-Fi")
    }

    @Test func invalidFramesNeverProduceWidthsOrUsablePositions() {
        let frames: [CGRect?] = [
            nil, .zero, CGRect(x: 1100, y: 0, width: -20, height: 24),
            CGRect(x: 1100, y: 0, width: 24, height: -1),
            CGRect(x: CGFloat.nan, y: 0, width: 24, height: 24),
            CGRect(x: 1100, y: 0, width: CGFloat.infinity, height: 24),
        ]
        let snapshot = SpacePlanner.snapshot(
            observations: frames.enumerated().map { .init(windowID: UInt32($0.offset), frame: $0.element) },
            displays: [screen]
        )
        #expect(snapshot.measurements.allSatisfy { $0.width == nil && $0.placement == .unavailableFrame })
        #expect(snapshot.displays[0].regions[0].measurementIDs.isEmpty)
    }

    @Test func ambiguousMirroredDisplaysAreNotGuessed() {
        let snapshot = SpacePlanner.snapshot(observations: [item(1, x: 1100, width: 30)], displays: [screen, screen])
        #expect(snapshot.measurements[0].placement == .ambiguousDisplay)
        #expect(snapshot.measurements[0].displayIndex == nil)
        #expect(snapshot.measurements[0].width == 30)
        #expect(snapshot.displays.allSatisfy { $0.regions[0].measurementIDs.isEmpty })
    }

    @Test func uncertainPositionsAreRankedButNeverUsedForReduction() {
        let snapshot = SpacePlanner.snapshot(
            observations: [
                item(1, x: 1190, width: 30),
                item(2, x: 1000, width: 40, isOnScreen: false),
                item(3, x: 1000, width: 20, y: 100),
                item(4, x: 1300, width: 50),
            ],
            displays: [screen]
        )
        #expect(snapshot.measurements.map(\.placement) == [.crossesDisplayEdge, .notOnScreen, .outsideMenuBar, .unknownDisplay])
        var preview = SpacePlanner.Preview()
        snapshot.measurements.forEach { preview.setExcluded(true, measurement: $0) }
        #expect(preview.excludedIDs.isEmpty)
        #expect(snapshot.displays[0].regions[0].observedInterval == nil)
    }

    @Test func invalidDisplayOrNotchMetadataFailsConservatively() {
        for display in [
            MenuBarDisplay(frame: .zero),
            MenuBarDisplay(frame: screen.frame, notch: .zero),
            MenuBarDisplay(frame: screen.frame, notch: CGRect(x: 1300, y: 0, width: 180, height: 32)),
            MenuBarDisplay(frame: screen.frame, notch: CGRect(x: 500, y: 300, width: 180, height: 32)),
        ] {
            let snapshot = SpacePlanner.snapshot(observations: [item(1, x: 1100, width: 24)], displays: [display])
            #expect(!snapshot.displays[0].geometryAvailable)
            #expect(snapshot.displays[0].regions.isEmpty)
            #expect(!snapshot.measurements[0].canExclude)
            #expect(snapshot.hasPartialData)
        }
    }

    @Test func exactNotchEdgesAndVerySmallRegionsStaySeparate() {
        let display = MenuBarDisplay(
            frame: CGRect(x: 2000, y: 100, width: 100, height: 100),
            notch: CGRect(x: 2005, y: 100, width: 90, height: 32)
        )
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: 2000, width: 5, y: 100), item(2, x: 2095, width: 5, y: 100)],
            displays: [display], applicationMenuBoundaries: [0: 2000]
        )
        #expect(snapshot.displays[0].regions.map(\.safeInterval) == [.init(0, 5), .init(95, 100)])
        #expect(snapshot.measurements.map(\.regionIndex) == [0, 1])
        for region in snapshot.displays[0].regions {
            let comparison = snapshot.comparison(in: region, preview: .init())
            #expect(comparison.beforeMeasuredWidth == 5)
            #expect(comparison.estimatedUnoccupiedBefore == 0)
        }
    }

    @Test func aBoundaryInsideTheNotchDoesNotReclaimAnyOfTheHousing() {
        let display = MenuBarDisplay(frame: screen.frame, notch: CGRect(x: 500, y: 0, width: 180, height: 32))
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: 450, width: 40), item(2, x: 700, width: 30)],
            displays: [display], applicationMenuBoundaries: [0: 600]
        )
        #expect(snapshot.displays[0].regions.map(\.usableInterval) == [.init(500, 500), .init(680, 1200)])
        #expect(snapshot.measurements[0].placement == .overlapsApplicationMenus)
        #expect(!snapshot.measurements[0].canExclude)
        #expect(snapshot.measurements[1].canExclude)
    }

    @Test func overlappingWidthsAreNotMistakenForReclaimedFootprint() {
        let snapshot = SpacePlanner.snapshot(
            observations: [item(1, x: 1100, width: 40), item(2, x: 1120, width: 40)],
            displays: [screen], applicationMenuBoundaries: [0: 1000]
        )
        let region = snapshot.displays[0].regions[0]
        var preview = SpacePlanner.Preview()
        preview.setExcluded(true, measurement: snapshot.measurements[0])
        let comparison = snapshot.comparison(in: region, preview: preview)
        #expect(comparison.beforeMeasuredWidth == 80)
        #expect(comparison.beforeOccupiedWidth == 60)
        #expect(comparison.afterOccupiedWidth == 40)
        #expect(comparison.excludedMeasuredWidth == 40)
        #expect(comparison.estimatedUnoccupiedBefore == 140)
        #expect(comparison.estimatedUnoccupiedAfter == 160)
    }

    @Test func resetExactlyRestoresPreviewWithoutMutatingSnapshot() {
        let observations = [item(1, x: 1100, width: 24), item(2, x: 1140, width: 36)]
        let snapshot = SpacePlanner.snapshot(observations: observations, displays: [screen])
        let original = snapshot
        let region = snapshot.displays[0].regions[0]
        var preview = SpacePlanner.Preview()
        let baseline = snapshot.comparison(in: region, preview: preview)
        for measurement in snapshot.measurements { preview.setExcluded(true, measurement: measurement) }
        let excluded = snapshot.comparison(in: region, preview: preview)
        #expect(excluded.afterCount == 0)
        #expect(excluded.afterMeasuredWidth == 0)
        #expect(excluded.excludedMeasuredWidth == 60)
        #expect(excluded.estimatedUnoccupiedAfter == nil)
        preview.setExcluded(false, measurement: snapshot.measurements[0])
        #expect(snapshot.comparison(in: region, preview: preview).afterMeasuredWidth == 24)
        preview.reset()
        #expect(preview.excludedIDs.isEmpty)
        #expect(snapshot.comparison(in: region, preview: preview) == baseline)
        #expect(snapshot == original)
        #expect(snapshot.measurements.map(\.observation) == observations)
    }

    @Test func emptyAndMissingDisplaySnapshotsRemainExplicit() {
        let empty = SpacePlanner.snapshot(observations: [], displays: [screen])
        #expect(empty.measurements.isEmpty)
        #expect(empty.displays[0].regions[0].observedInterval == nil)
        #expect(empty.displays[0].regions[0].usableInterval == nil)
        let missingDisplay = SpacePlanner.snapshot(observations: [item(1, x: 1100, width: 24)], displays: [])
        #expect(missingDisplay.displays.isEmpty)
        #expect(missingDisplay.measurements[0].placement == .unknownDisplay)
        #expect(missingDisplay.measurements[0].width == 24)
        #expect(missingDisplay.hasPartialData)
    }
}
