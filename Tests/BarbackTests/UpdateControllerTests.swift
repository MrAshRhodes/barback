import AppKit
import BarbackCore
import Testing
@testable import Barback

@Suite("Update controller", .serialized)
@MainActor
struct UpdateControllerTests {
    private var configuration: Result<UpdateConfiguration, UpdateConfiguration.Problem> {
        UpdateConfiguration.resolve(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
        ])
    }

    @Test func defaultOffDoesNotStartOrCheck() {
        let engine = FakeUpdateEngine()
        let controller = UpdateController(source: .direct, configuration: configuration, makeEngine: { engine })
        #expect(controller.availability == .ready)
        #expect(controller.frequency == .never)
        #expect(!controller.isStarted)
        #expect(controller.canCheckNow)
        #expect(engine.events.isEmpty)
    }

    @Test(arguments: UpdateCheckFrequency.allCases)
    func manualCheckWorksAtEveryFrequency(_ frequency: UpdateCheckFrequency) {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = frequency != .never
        engine.updateCheckInterval = frequency.interval ?? 86_400
        engine.events = []
        let controller = UpdateController(source: .direct, configuration: configuration, makeEngine: { engine })
        controller.checkForUpdates(nil)
        controller.checkForUpdates(nil)
        #expect(engine.events == ["start", "check", "check"])
        #expect(controller.frequency == frequency)
    }

    @Test func schedulesUseExactIntervalsBeforeEnablingAndNeverDisables() {
        let engine = FakeUpdateEngine()
        let controller = UpdateController(source: .direct, configuration: configuration, makeEngine: { engine })
        for (frequency, seconds) in [(UpdateCheckFrequency.daily, 86_400.0), (.weekly, 604_800.0), (.monthly, 2_592_000.0)] {
            engine.events = []
            controller.setFrequency(frequency)
            #expect(engine.updateCheckInterval == seconds)
            #expect(engine.automaticallyChecksForUpdates)
            #expect(Array(engine.events.suffix(2)) == ["interval", "automatic:true"])
            #expect(controller.frequency == frequency)
        }
        engine.events = []
        controller.setFrequency(.never)
        #expect(engine.events == ["automatic:false"])
        #expect(controller.frequency == .never)
        controller.checkForUpdates(nil)
        #expect(engine.events == ["automatic:false", "check"])
    }

    @Test func persistedScheduleStartsAtLaunchAndNotificationsRefreshUI() {
        let engine = FakeUpdateEngine()
        engine.automaticallyChecksForUpdates = true
        engine.updateCheckInterval = 604_800
        engine.events = []
        let controller = UpdateController(source: .direct, configuration: configuration, makeEngine: { engine })
        #expect(controller.frequency == .weekly)
        #expect(engine.events == ["start"])
        engine.canCheckForUpdates = false
        engine.lastUpdateCheckDate = Date(timeIntervalSince1970: 12345)
        engine.onChange?()
        #expect(!controller.canCheckNow)
        #expect(controller.lastCheck == engine.lastUpdateCheckDate)
        let item = controller.makeMenuItem()
        #expect(item.target === controller)
        #expect(!controller.validateMenuItem(item))
    }

    @Test func startFailureReportsErrorWithoutCheckingOrPersistingSchedule() {
        let engine = FakeUpdateEngine()
        engine.startError = NSError(domain: "UpdaterTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Test start failure",
        ])
        var notices: [UpdateController.Notice] = []
        let controller = UpdateController(
            source: .direct, configuration: configuration, makeEngine: { engine },
            presentNotice: { notices.append($0) }
        )
        controller.checkForUpdates(nil)
        controller.setFrequency(.daily)
        #expect(engine.events == ["start", "start"])
        #expect(!controller.isStarted)
        #expect(controller.frequency == .never)
        #expect(notices.count == 2)
        #expect(notices.allSatisfy { $0.message == "Test start failure" })
    }

    @Test func homebrewNeverConstructsAnUpdaterEvenWithoutAKey() {
        var constructed = false
        var notice: UpdateController.Notice?
        let controller = UpdateController(
            source: .homebrew, configuration: .failure(.missingPublicKey),
            makeEngine: { constructed = true; return FakeUpdateEngine() },
            presentNotice: { notice = $0 }
        )
        controller.setFrequency(.daily)
        controller.checkForUpdates(nil)
        #expect(!constructed)
        #expect(controller.availability == .homebrew)
        #expect(controller.frequency == .never)
        #expect(notice?.copyableCommand == "brew update && brew upgrade --cask barback")
    }

    @Test func unsignedBuildExplainsTheProblemAndLinksToReleases() {
        var constructed = false
        var notice: UpdateController.Notice?
        let controller = UpdateController(
            source: .direct, configuration: .failure(.missingPublicKey),
            makeEngine: { constructed = true; return FakeUpdateEngine() },
            presentNotice: { notice = $0 }
        )
        controller.checkForUpdates(nil)
        #expect(!constructed)
        #expect(notice?.link == UpdateController.releasesURL)
        #expect(notice?.copyableCommand == nil)
        #expect(notice?.message.contains("signing key") == true)
    }
}

@MainActor
private final class FakeUpdateEngine: UpdateEngine {
    var events: [String] = []
    var automaticallyChecksForUpdates = false {
        didSet { events.append("automatic:\(automaticallyChecksForUpdates)") }
    }
    var updateCheckInterval: TimeInterval = 86_400 {
        didSet { events.append("interval") }
    }
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var onChange: (() -> Void)?
    var startError: Error?

    func start() throws {
        events.append("start")
        if let startError { throw startError }
    }

    func checkForUpdates() { events.append("check") }
}
