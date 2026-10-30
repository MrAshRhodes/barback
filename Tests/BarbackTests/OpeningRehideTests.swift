import BarbackCore
import Testing
@testable import Barback

@Suite("Opening rehide suspension")
struct OpeningRehideTests {
    @Test func onlyAutomaticHidingWaitsForAnOpeningItem() {
        for nextState in [SectionState.hidden, .shown, .shownAll] {
            for userInitiated in [false, true] {
                #expect(StatusBarController.shouldDeferAutomaticRehide(
                    nextState: nextState, userInitiated: userInitiated, itemOpening: true
                ) == (nextState == .hidden && !userInitiated))
            }
        }
    }

    @Test func completionOrCancellationAllowsAutomaticRehideAgain() {
        for nextState in [SectionState.hidden, .shown, .shownAll] {
            #expect(!StatusBarController.shouldDeferAutomaticRehide(
                nextState: nextState, userInitiated: false, itemOpening: false
            ))
        }
    }
}
