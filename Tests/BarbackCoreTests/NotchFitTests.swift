import CoreGraphics
import Testing
@testable import BarbackCore

@Suite("Observed notch fit")
struct NotchFitTests {
    private let builtIn = MenuBarDisplay(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notch: CGRect(x: 656, y: 0, width: 200, height: 32)
    )

    private func item(
        _ id: UInt32, x: CGFloat, width: CGFloat = 24, y: CGFloat = 0,
        display: Int? = 0, section: MenuBarSection = .hidden, drawn: Bool = true
    ) -> NotchFit.Item {
        .init(id: id, frame: CGRect(x: x, y: y, width: width, height: 24),
              display: display, section: section, isOnScreen: drawn)
    }

    @Test func comparesWholeFramesNotJustNotchIntersection() throws {
        let result = try #require(NotchFit.evaluate(
            items: [item(1, x: 900), item(2, x: 850), item(3, x: 610), item(4, x: -40)],
            displays: [builtIn], state: .shown
        ).first)
        #expect(result.availableWidth == 656)
        #expect(result.unreachableIDs == [2, 3, 4])
        #expect(result.unreachableCount == 3)
        #expect(result.unknownIDs.isEmpty)
    }

    @Test func exactEdgesFitButPartialItemsDoNot() throws {
        let result = try #require(NotchFit.evaluate(
            items: [item(1, x: 856), item(2, x: 1488), item(3, x: 855.5), item(4, x: 1489)],
            displays: [builtIn], state: .shown
        ).first)
        #expect(result.unreachableIDs == [3, 4])
    }

    @Test func hiddenSectionsAreNotMisreportedAsNotchOverflow() {
        let rows = [item(1, x: 700), item(2, x: -9000, section: .alwaysHidden)]
        #expect(NotchFit.evaluate(items: rows, displays: [builtIn], state: .hidden).isEmpty)
        #expect(NotchFit.evaluate(items: rows, displays: [builtIn], state: .shown).first?.unreachableIDs == [1])
        #expect(NotchFit.evaluate(items: rows, displays: [builtIn], state: .shownAll).first?.unreachableIDs == [1, 2])
    }

    @Test func notDrawnAndInvalidFramesAreUnknownNotConfirmedOverflow() throws {
        let result = try #require(NotchFit.evaluate(
            items: [item(1, x: 700, drawn: false), item(2, x: 900, drawn: false),
                    item(3, x: 700, width: 0), item(4, x: 700, y: 100),
                    item(5, x: .infinity), item(6, x: 700, width: -2),
                    item(7, x: .greatestFiniteMagnitude, width: .greatestFiniteMagnitude)],
            displays: [builtIn], state: .shown
        ).first)
        #expect(result.unreachableCount == 0)
        #expect(result.unknownIDs == [1, 2, 3, 4, 5, 6, 7])
    }

    @Test func externalAndUnassignedItemsCannotInflateBuiltInCount() throws {
        let external = MenuBarDisplay(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let result = try #require(NotchFit.evaluate(
            items: [item(1, x: 700), item(2, x: -100, display: 1), item(3, x: 700, display: nil),
                    item(4, x: 700, display: 9)],
            displays: [builtIn, external], state: .shown
        ).first)
        #expect(result.unreachableIDs == [1])
        #expect(NotchFit.evaluate(items: [item(1, x: -100)], displays: [external], state: .shown).isEmpty)
    }

    @Test func differentDisplayOriginsAndNotchesUseTheirOwnCapacity() {
        let above = MenuBarDisplay(
            frame: CGRect(x: -1512, y: -982, width: 1512, height: 982),
            notch: CGRect(x: -856, y: -982, width: 200, height: 32)
        )
        let results = NotchFit.evaluate(
            items: [item(1, x: 700), item(2, x: -650, y: -982, display: 1),
                    item(3, x: -700, y: -982, display: 1)],
            displays: [builtIn, above], state: .shown
        )
        #expect(results.map(\.availableWidth) == [656, 656])
        #expect(results.map(\.unreachableIDs) == [[1], [3]])
    }

    @Test func unknownSectionUsesObservedGeometryWithoutGuessingAHiddenTier() {
        let results = NotchFit.evaluate(
            items: [item(1, x: 700, section: .unknown), item(2, x: 900, section: .unknown)],
            displays: [builtIn], state: .shown
        )
        #expect(results.first?.unreachableIDs == [1])
    }

    @Test func duplicateWindowIDsCountOnlyOncePerDisplay() {
        let results = NotchFit.evaluate(
            items: [item(1, x: 700), item(1, x: 700)], displays: [builtIn], state: .shown
        )
        #expect(results.first?.unreachableCount == 1)
    }

    @Test func invalidDisplayGeometryDoesNotProduceAMeasurement() {
        let bad = [
            MenuBarDisplay(frame: builtIn.frame, notch: CGRect(x: 1500, y: 0, width: 200, height: 32)),
            MenuBarDisplay(frame: builtIn.frame, notch: .zero),
            MenuBarDisplay(frame: .zero, notch: builtIn.notch),
            MenuBarDisplay(frame: builtIn.frame, notch: CGRect(x: -.infinity, y: 0, width: 200, height: 32)),
        ]
        #expect(NotchFit.evaluate(items: [item(1, x: 700)], displays: bad, state: .shown).isEmpty)
    }

    @Test func panelStaysRightOfNotchAndInsideVisibleScreen() throws {
        let screen = CGRect(x: -1512, y: 1080, width: 1512, height: 982)
        let notch = CGRect(x: -856, y: 2030, width: 200, height: 32)
        let visible = CGRect(x: -1512, y: 1120, width: 1512, height: 910)
        let panel = try #require(NotchFit.panelFrame(screen: screen, visible: visible, notch: notch))
        #expect(panel.minX >= notch.maxX + 8)
        #expect(panel.maxX <= screen.maxX - 8)
        #expect(panel.maxY <= notch.minY - 8)
        #expect(visible.contains(panel))
        #expect(panel.height == 240)
    }

    @Test func insufficientPanelSpaceIsExplicitlyUnavailable() {
        #expect(NotchFit.panelFrame(
            screen: CGRect(x: 0, y: 0, width: 500, height: 200),
            visible: CGRect(x: 0, y: 0, width: 500, height: 170),
            notch: CGRect(x: 200, y: 170, width: 200, height: 30)
        ) == nil)
    }
}
