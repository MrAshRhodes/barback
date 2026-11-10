import BarbackCore
import Testing
@testable import Barback

@Suite("Launch hide")
struct LaunchHideTests {
    @Test func theLaunchHideRunsWhenNothingHasChosenTheSections() {
        #expect(StatusBarController.shouldRunLaunchHide(userActed: false, activeProfile: nil))
    }

    @Test func aHiddenProfileKeepsTheLaunchHideBecauseItRetriesAnUnvalidatedHide() {
        #expect(StatusBarController.shouldRunLaunchHide(userActed: false, activeProfile: .hidden))
    }

    @Test func aProfileThatShowsSectionsIsNotUndoneByTheLaunchHide() {
        #expect(!StatusBarController.shouldRunLaunchHide(userActed: false, activeProfile: .shown))
        #expect(!StatusBarController.shouldRunLaunchHide(userActed: false, activeProfile: .shownAll))
    }

    @Test func aUserActionAlwaysCancelsTheLaunchHide() {
        for profile in [nil, .hidden, .shown, .shownAll] as [ProfileVisibility?] {
            #expect(!StatusBarController.shouldRunLaunchHide(userActed: true, activeProfile: profile))
        }
    }
}
