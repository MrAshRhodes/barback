import CoreGraphics
import Testing
@testable import BarbackCore

@Suite("Hover throttle and exit")
struct HoverThrottleTests {
    @Test func firstEventProcessesImmediately() {
        var t = HoverThrottle(interval: 0.05)
        #expect(t.eventArrived(at: 10) == .processNow)
        #expect(t.eventArrived(at: 10.06) == .processNow)
    }

    @Test func eventsInsideWindowScheduleOneTrailingCheck() {
        var t = HoverThrottle(interval: 0.05)
        #expect(t.eventArrived(at: 10) == .processNow)
        guard case .scheduleTrailing(let delay) = t.eventArrived(at: 10.02) else {
            Issue.record("expected a trailing check")
            return
        }
        #expect(abs(delay - 0.03) < 1e-9)
        #expect(t.eventArrived(at: 10.03) == .trailingPending, "only one trailing check at a time")
        #expect(t.eventArrived(at: 10.04) == .trailingPending)
        t.trailingFired(at: 10.05)
        #expect(!t.trailingScheduled)
        // The trailing check counts as processed, so the throttle window restarts from it.
        guard case .scheduleTrailing(let next) = t.eventArrived(at: 10.06) else {
            Issue.record("expected a new trailing check after the window restarted")
            return
        }
        #expect(abs(next - 0.04) < 1e-9)
        #expect(t.eventArrived(at: 10.2) == .processNow)
    }

    @Test func resetForgetsState() {
        var t = HoverThrottle(interval: 0.05)
        _ = t.eventArrived(at: 1)
        _ = t.eventArrived(at: 1.01)
        t.reset()
        #expect(!t.trailingScheduled)
        #expect(t.eventArrived(at: 1.02) == .processNow)
    }

    @Test func exitWhileMenuOpenIsRetriedNotDropped() {
        let d = HoverPolicy.exitDecision(state: .shown, revealedByHover: true, mouseInMenuBar: false, menuOpen: true)
        #expect(d == .retry(after: HoverPolicy.menuOpenRetryInterval))
        #expect(HoverPolicy.exitDecision(state: .shown, revealedByHover: true, mouseInMenuBar: false, menuOpen: false) == .hide)
    }

    @Test func exitIgnoredWhenNotHoverRevealedOrPointerBack() {
        #expect(HoverPolicy.exitDecision(state: .shown, revealedByHover: false, mouseInMenuBar: false, menuOpen: true) == .none)
        #expect(HoverPolicy.exitDecision(state: .shown, revealedByHover: true, mouseInMenuBar: true, menuOpen: true) == .none)
        #expect(HoverPolicy.exitDecision(state: .hidden, revealedByHover: true, mouseInMenuBar: false, menuOpen: false) == .none)
        #expect(HoverPolicy.exitDecision(state: .shownAll, revealedByHover: true, mouseInMenuBar: false, menuOpen: false) == .none)
    }

    @Test func appSwitchRehide() {
        #expect(RehidePolicy.shouldRehideOnAppSwitch(enabled: true, state: .shown, activatedBarback: false, mouseInMenuBar: false, menuOpen: false))
        #expect(RehidePolicy.shouldRehideOnAppSwitch(enabled: true, state: .shownAll, activatedBarback: false, mouseInMenuBar: false, menuOpen: false))
        #expect(!RehidePolicy.shouldRehideOnAppSwitch(enabled: false, state: .shown, activatedBarback: false, mouseInMenuBar: false, menuOpen: false))
        #expect(!RehidePolicy.shouldRehideOnAppSwitch(enabled: true, state: .hidden, activatedBarback: false, mouseInMenuBar: false, menuOpen: false))
        #expect(!RehidePolicy.shouldRehideOnAppSwitch(enabled: true, state: .shown, activatedBarback: true, mouseInMenuBar: false, menuOpen: false))
        #expect(!RehidePolicy.shouldRehideOnAppSwitch(enabled: true, state: .shown, activatedBarback: false, mouseInMenuBar: true, menuOpen: false),
                "clicking a revealed item activates its app; don't hide it from under the pointer")
        #expect(!RehidePolicy.shouldRehideOnAppSwitch(enabled: true, state: .shown, activatedBarback: false, mouseInMenuBar: false, menuOpen: true))
    }
}

@Suite("Item classification")
struct ItemClassifierTests {
    // Ultra-wide main display plus a portrait display to its right (CG coordinates), as on the dev Mac.
    let main = MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 3440, height: 1440))
    let portrait = MenuBarDisplay(frame: CGRect(x: 3440, y: -367, width: 1080, height: 1920))
    let hiddenSep = CGRect(x: 2600, y: 0, width: 14, height: 30)
    let alwaysSep = CGRect(x: 2300, y: 0, width: 14, height: 30)

    func item(_ x: CGFloat, y: CGFloat = 0, width: CGFloat = 32, onScreen: Bool = true) -> MenuBarItem {
        MenuBarItem(windowID: UInt32(abs(x) + 1), ownerName: "Control Centre", ownerPID: 1,
                    frame: CGRect(x: x, y: y, width: width, height: 30), isOnScreen: onScreen)
    }

    @Test func classifiesOnSeparatorDisplay() {
        let displays = [main, portrait]
        let visible = ItemClassifier.classify(item(2700), displays: displays, hiddenSeparator: hiddenSep, alwaysHiddenSeparator: alwaysSep)
        #expect(visible == ItemPlacement(display: 0, section: .visible, visibility: .shown, overlapsNotch: false))
        let hidden = ItemClassifier.classify(item(2400), displays: displays, hiddenSeparator: hiddenSep, alwaysHiddenSeparator: alwaysSep)
        #expect(hidden.section == .hidden && hidden.visibility == .shown)
        let always = ItemClassifier.classify(item(2000), displays: displays, hiddenSeparator: hiddenSep, alwaysHiddenSeparator: alwaysSep)
        #expect(always.section == .alwaysHidden)
    }

    @Test func itemsOnOtherDisplaysAreUnknown() {
        // A menu bar item on the portrait display's menu bar (its top is y = -367).
        let other = item(3600, y: -367)
        let p = ItemClassifier.classify(other, displays: [main, portrait], hiddenSeparator: hiddenSep, alwaysHiddenSeparator: alwaysSep)
        #expect(p.display == 1)
        #expect(p.section == .unknown, "never compare with another display's separators")
        #expect(p.visibility == .shown)
    }

    @Test func noSeparatorsMeansUnknown() {
        let p = ItemClassifier.classify(item(2700), displays: [main], hiddenSeparator: nil, alwaysHiddenSeparator: nil)
        #expect(p.section == .unknown)
    }

    @Test func pushedOffItemsBelongToTheDisplayOnTheirRight() {
        // Collapsed: the separator is expanded leftwards and items left of it now sit at negative x.
        let expanded = CGRect(x: hiddenSep.maxX - SectionLayout.expandedLength, y: 0, width: SectionLayout.expandedLength, height: 30)
        let pushed = item(-7500)
        let p = ItemClassifier.classify(pushed, displays: [main, portrait], hiddenSeparator: expanded, alwaysHiddenSeparator: nil)
        #expect(p.display == 0)
        #expect(p.section == .hidden)
        #expect(p.visibility == .offScreen)
    }

    @Test func expandedSeparatorIsLocatedByItsRightEdge() {
        // A display to the left of main: the expanded separator overlaps it more than main, but it lives on main.
        let left = MenuBarDisplay(frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
        let expanded = CGRect(x: 500 - SectionLayout.expandedLength, y: 0, width: SectionLayout.expandedLength, height: 30)
        let p = ItemClassifier.classify(item(700), displays: [left, main], hiddenSeparator: expanded, alwaysHiddenSeparator: nil)
        #expect(p.display == 1)
        #expect(p.section == .visible)
    }

    @Test func windowInsideMenuBarButNotDrawnIsNotDrawn() {
        // Regression: an undrawn window at x = 2357 among visible items was labelled "Hidden".
        let ghost = item(2357, width: 48, onScreen: false)
        let p = ItemClassifier.classify(ghost, displays: [main], hiddenSeparator: CGRect(x: 2200, y: 0, width: 14, height: 30), alwaysHiddenSeparator: nil)
        #expect(p.visibility == .notDrawn)
        #expect(p.section == .visible)
    }

    @Test func notchIsCheckedOnTheItemsOwnDisplayOnly() {
        // Built-in notched display below an external display that shares the same x range.
        let builtIn = MenuBarDisplay(frame: CGRect(x: 0, y: 1440, width: 1512, height: 982),
                                     notch: CGRect(x: 662, y: 1440, width: 188, height: 37))
        let external = MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        let onExternal = item(700, y: 0)
        let onBuiltIn = item(700, y: 1440)
        let a = ItemClassifier.classify(onExternal, displays: [external, builtIn], hiddenSeparator: nil, alwaysHiddenSeparator: nil)
        let b = ItemClassifier.classify(onBuiltIn, displays: [external, builtIn], hiddenSeparator: nil, alwaysHiddenSeparator: nil)
        #expect(!a.overlapsNotch, "x overlaps the notch, but this item is on the external display")
        #expect(b.overlapsNotch)
    }

    @Test func displayIndexPrefersLargestOverlap() {
        let a = MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let b = MenuBarDisplay(frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        #expect(ItemClassifier.displayIndex(for: CGRect(x: 90, y: 0, width: 30, height: 20), in: [a, b]) == 1)
        #expect(ItemClassifier.displayIndex(for: CGRect(x: 500, y: 0, width: 30, height: 20), in: [a, b]) == nil)
    }
}
