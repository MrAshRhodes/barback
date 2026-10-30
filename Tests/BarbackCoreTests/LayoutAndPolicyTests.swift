import CoreGraphics
import Testing
@testable import BarbackCore

@Suite("Section layout")
struct SectionLayoutTests {
    // Typical layout, left to right: [always │][hidden │][chevron]
    let chevron = CGRect(x: 2000, y: 0, width: 24, height: 24)
    let hidden = CGRect(x: 1980, y: 0, width: 14, height: 24)
    let always = CGRect(x: 1900, y: 0, width: 14, height: 24)

    @Test func validOrder() {
        #expect(SectionLayout.validate(chevron: chevron, hiddenSeparator: hidden, alwaysHiddenSeparator: always) == .valid)
        #expect(SectionLayout.validate(chevron: chevron, hiddenSeparator: hidden, alwaysHiddenSeparator: nil) == .valid)
    }

    @Test func hiddenSeparatorRightOfChevronIsMisordered() {
        let misplaced = CGRect(x: 2030, y: 0, width: 14, height: 24)
        let v = SectionLayout.validate(chevron: chevron, hiddenSeparator: misplaced, alwaysHiddenSeparator: always)
        #expect(v == .hiddenSeparatorMisplaced)
        #expect(!v.canHideHiddenSection)
    }

    @Test func alwaysHiddenRightOfHiddenIsMisordered() {
        let misplaced = CGRect(x: 1995, y: 0, width: 4, height: 24)
        let v = SectionLayout.validate(chevron: chevron, hiddenSeparator: hidden, alwaysHiddenSeparator: misplaced)
        #expect(v == .alwaysHiddenSeparatorMisplaced)
        #expect(v.canHideHiddenSection, "the hidden section still works; only always-hidden is disabled")
    }

    @Test func expandedSeparatorStillValidatesByRightEdge() {
        // Expanded to 10_000pt the separator grows leftwards; its right edge stays left of the chevron.
        let expanded = CGRect(x: 1994 - SectionLayout.expandedLength, y: 0, width: SectionLayout.expandedLength, height: 24)
        #expect(SectionLayout.validate(chevron: chevron, hiddenSeparator: expanded, alwaysHiddenSeparator: nil) == .valid)
    }

    @Test func missingOrEmptyFramesAreUnknown() {
        #expect(SectionLayout.validate(chevron: nil, hiddenSeparator: hidden, alwaysHiddenSeparator: nil) == .unknown)
        #expect(SectionLayout.validate(chevron: chevron, hiddenSeparator: nil, alwaysHiddenSeparator: nil) == .unknown)
        #expect(SectionLayout.validate(chevron: .zero, hiddenSeparator: hidden, alwaysHiddenSeparator: nil) == .unknown)
        #expect(!LayoutValidation.unknown.canHideHiddenSection)
    }

    @Test func lengthsForEachState() {
        let e = SectionLayout.expandedLength, n = SectionLayout.separatorLength
        #expect(SectionLayout.lengths(for: .hidden, validation: .valid, alwaysHiddenEnabled: true) == SeparatorLengths(hidden: e, alwaysHidden: e))
        #expect(SectionLayout.lengths(for: .shown, validation: .valid, alwaysHiddenEnabled: true) == SeparatorLengths(hidden: n, alwaysHidden: e))
        #expect(SectionLayout.lengths(for: .shownAll, validation: .valid, alwaysHiddenEnabled: true) == SeparatorLengths(hidden: n, alwaysHidden: n))
        #expect(SectionLayout.lengths(for: .shown, validation: .valid, alwaysHiddenEnabled: false) == SeparatorLengths(hidden: n, alwaysHidden: n))
    }

    @Test func neverExpandsWhenMisorderedOrUnknown() {
        let n = SectionLayout.separatorLength
        for v in [LayoutValidation.hiddenSeparatorMisplaced, .unknown] {
            #expect(SectionLayout.lengths(for: .hidden, validation: v, alwaysHiddenEnabled: true) == SeparatorLengths(hidden: n, alwaysHidden: n))
        }
        let partial = SectionLayout.lengths(for: .hidden, validation: .alwaysHiddenSeparatorMisplaced, alwaysHiddenEnabled: true)
        #expect(partial == SeparatorLengths(hidden: SectionLayout.expandedLength, alwaysHidden: n))
    }

    @Test func stateTransitions() {
        #expect(SectionLayout.nextState(from: .hidden, action: .toggle, alwaysHiddenEnabled: true) == .shown)
        #expect(SectionLayout.nextState(from: .shown, action: .toggle, alwaysHiddenEnabled: true) == .hidden)
        #expect(SectionLayout.nextState(from: .shownAll, action: .toggle, alwaysHiddenEnabled: true) == .hidden)
        #expect(SectionLayout.nextState(from: .hidden, action: .toggleAll, alwaysHiddenEnabled: true) == .shownAll)
        #expect(SectionLayout.nextState(from: .shown, action: .toggleAll, alwaysHiddenEnabled: true) == .shownAll)
        #expect(SectionLayout.nextState(from: .shownAll, action: .toggleAll, alwaysHiddenEnabled: true) == .hidden)
        #expect(SectionLayout.nextState(from: .hidden, action: .toggleAll, alwaysHiddenEnabled: false) == .shown)
        #expect(SectionLayout.nextState(from: .shownAll, action: .show, alwaysHiddenEnabled: true) == .shownAll)
        #expect(SectionLayout.nextState(from: .hidden, action: .showAll, alwaysHiddenEnabled: false) == .shown)
        #expect(SectionLayout.nextState(from: .shownAll, action: .hide, alwaysHiddenEnabled: true) == .hidden)
    }

    @Test func classifiesItemsBySeparatorPosition() {
        #expect(SectionLayout.section(ofItemMinX: 2100, hiddenSeparatorMaxX: hidden.maxX, alwaysHiddenSeparatorMaxX: always.maxX) == .visible)
        #expect(SectionLayout.section(ofItemMinX: 1950, hiddenSeparatorMaxX: hidden.maxX, alwaysHiddenSeparatorMaxX: always.maxX) == .hidden)
        #expect(SectionLayout.section(ofItemMinX: 1800, hiddenSeparatorMaxX: hidden.maxX, alwaysHiddenSeparatorMaxX: always.maxX) == .alwaysHidden)
        #expect(SectionLayout.section(ofItemMinX: 1800, hiddenSeparatorMaxX: hidden.maxX, alwaysHiddenSeparatorMaxX: nil) == .hidden)
        #expect(SectionLayout.section(ofItemMinX: 1800, hiddenSeparatorMaxX: nil, alwaysHiddenSeparatorMaxX: nil) == .visible)
    }
}

@Suite("Rehide policy")
struct RehidePolicyTests {
    func ctx(_ state: SectionState = .shown, seconds: Int = 10, mouse: Bool = false, menu: Bool = false) -> RehideContext {
        RehideContext(state: state, autoRehideSeconds: seconds, mouseInMenuBar: mouse, menuOpen: menu)
    }

    @Test func rehidesWhenIdle() {
        #expect(RehidePolicy.decide(ctx()) == .rehideNow)
        #expect(RehidePolicy.decide(ctx(.shownAll)) == .rehideNow)
    }

    @Test func zeroMeansNever() {
        #expect(RehidePolicy.initialDelay(autoRehideSeconds: 0) == nil)
        #expect(RehidePolicy.initialDelay(autoRehideSeconds: -1) == nil)
        #expect(RehidePolicy.initialDelay(autoRehideSeconds: 10) == 10)
        #expect(RehidePolicy.decide(ctx(seconds: 0)) == .none)
    }

    @Test func alreadyHiddenDoesNothing() {
        #expect(RehidePolicy.decide(ctx(.hidden)) == .none)
    }

    @Test func postponesWhileMouseInMenuBarOrMenuOpen() {
        #expect(RehidePolicy.decide(ctx(mouse: true)) == .postpone(RehidePolicy.postponeInterval))
        #expect(RehidePolicy.decide(ctx(menu: true)) == .postpone(RehidePolicy.postponeInterval))
        #expect(RehidePolicy.decide(ctx(seconds: 1, mouse: true)) == .postpone(1), "never wait longer than the delay itself")
    }
}

@Suite("Menu bar geometry")
struct MenuBarGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func menuBarHeightUsesLargestSignal() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        #expect(MenuBarGeometry.menuBarHeight(screenFrame: screen, visibleFrame: visible, safeAreaTop: 32, statusBarThickness: 22) == 37)
        // Auto-hidden menu bar: visibleFrame reaches the top → fall back to thickness.
        #expect(MenuBarGeometry.menuBarHeight(screenFrame: screen, visibleFrame: screen, safeAreaTop: 0, statusBarThickness: 22) == 22)
    }

    @Test func pointInMenuBarEdges() {
        #expect(MenuBarGeometry.isPoint(CGPoint(x: 100, y: 982), inMenuBarOf: screen, menuBarHeight: 24))
        #expect(MenuBarGeometry.isPoint(CGPoint(x: 100, y: 958), inMenuBarOf: screen, menuBarHeight: 24))
        #expect(!MenuBarGeometry.isPoint(CGPoint(x: 100, y: 957.9), inMenuBarOf: screen, menuBarHeight: 24))
        #expect(!MenuBarGeometry.isPoint(CGPoint(x: 1600, y: 980), inMenuBarOf: screen, menuBarHeight: 24), "other screen")
        #expect(!MenuBarGeometry.isPoint(CGPoint(x: 100, y: 980), inMenuBarOf: screen, menuBarHeight: 0))
    }

    @Test func hoverZoneAvoidsNotchAndLeftHalf() {
        let notch = CGRect(x: 662, y: 950, width: 188, height: 32)
        #expect(!MenuBarGeometry.isInHoverZone(CGPoint(x: 700, y: 970), screenFrame: screen, menuBarHeight: 32, notch: notch))
        #expect(!MenuBarGeometry.isInHoverZone(CGPoint(x: 300, y: 970), screenFrame: screen, menuBarHeight: 32, notch: notch))
        #expect(MenuBarGeometry.isInHoverZone(CGPoint(x: 900, y: 970), screenFrame: screen, menuBarHeight: 32, notch: notch))
        #expect(MenuBarGeometry.isInHoverZone(CGPoint(x: 800, y: 970), screenFrame: screen, menuBarHeight: 24, notch: nil))
        #expect(!MenuBarGeometry.isInHoverZone(CGPoint(x: 900, y: 500), screenFrame: screen, menuBarHeight: 32, notch: notch))
    }
}

@Suite("Notch geometry")
struct NotchGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let left = CGRect(x: 0, y: 950, width: 662, height: 32)
    let right = CGRect(x: 850, y: 950, width: 662, height: 32)

    @Test func computesNotchBetweenAuxiliaryAreas() throws {
        let notch = try #require(NotchGeometry.notchRect(screenFrame: screen, auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right))
        #expect(notch == CGRect(x: 662, y: 950, width: 188, height: 32))
    }

    @Test func noNotchWithoutAuxiliaryAreasOrGap() {
        #expect(NotchGeometry.notchRect(screenFrame: screen, auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: right) == nil)
        #expect(NotchGeometry.notchRect(screenFrame: screen, auxiliaryTopLeftArea: left, auxiliaryTopRightArea: left) == nil)
        #expect(NotchGeometry.notchRect(screenFrame: screen, auxiliaryTopLeftArea: .zero, auxiliaryTopRightArea: right) == nil)
    }

    @Test func screenLocalAuxiliaryAreasAreGlobalized() throws {
        let secondary = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let notch = try #require(NotchGeometry.notchRect(screenFrame: secondary, auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right))
        #expect(notch.minX == CGFloat(-1512 + 662))
        #expect(notch.maxY == secondary.maxY)
    }

    @Test func overlapDetection() {
        let notch = CGRect(x: 662, y: 950, width: 188, height: 32)
        #expect(NotchGeometry.overlapsNotch(CGRect(x: 640, y: 0, width: 30, height: 24), notch: notch), "straddles left edge")
        #expect(NotchGeometry.overlapsNotch(CGRect(x: 700, y: 0, width: 20, height: 24), notch: notch), "fully under")
        #expect(!NotchGeometry.overlapsNotch(CGRect(x: 850, y: 0, width: 30, height: 24), notch: notch), "touching right edge")
        #expect(!NotchGeometry.overlapsNotch(CGRect(x: 600, y: 0, width: 62, height: 24), notch: notch), "touching left edge")
        #expect(!NotchGeometry.overlapsNotch(minX: 700, maxX: 700, notch: notch), "zero width")
    }
}

@Suite("Hover policy")
struct HoverPolicyTests {
    @Test func timingMatchesDesign() {
        #expect(HoverPolicy.exitDelay == 0.4, "same MouseExitDelay as Bartender")
        #expect(HoverPolicy.dwell > 0 && HoverPolicy.dwell < HoverPolicy.exitDelay)
        #expect(HoverPolicy.throttle > 0 && HoverPolicy.throttle <= 1.0 / 20)
    }

    @Test func hidesHoverRevealAfterPointerLeaves() {
        #expect(HoverPolicy.shouldHideAfterExit(state: .shown, revealedByHover: true, mouseInMenuBar: false, menuOpen: false))
    }

    @Test func keepsItemsWhilePointerIsBackOrMenuIsOpen() {
        #expect(!HoverPolicy.shouldHideAfterExit(state: .shown, revealedByHover: true, mouseInMenuBar: true, menuOpen: false))
        #expect(!HoverPolicy.shouldHideAfterExit(state: .shown, revealedByHover: true, mouseInMenuBar: false, menuOpen: true))
    }

    @Test func leavesExplicitRevealsToAutoRehide() {
        #expect(!HoverPolicy.shouldHideAfterExit(state: .shown, revealedByHover: false, mouseInMenuBar: false, menuOpen: false))
        #expect(!HoverPolicy.shouldHideAfterExit(state: .shownAll, revealedByHover: true, mouseInMenuBar: false, menuOpen: false))
        #expect(!HoverPolicy.shouldHideAfterExit(state: .hidden, revealedByHover: true, mouseInMenuBar: false, menuOpen: false))
    }
}
