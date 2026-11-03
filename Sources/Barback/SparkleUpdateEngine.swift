import AppKit
import Sparkle

/// `UpdateEngine` backed by Sparkle. Sparkle keeps the schedule and last-check date in the host bundle's defaults,
/// verifies the signed appcast and archive against `SUPublicEDKey`, and always asks before installing.
@MainActor
final class SparkleUpdateEngine: UpdateEngine {
    let updater: SPUUpdater
    var onChange: (() -> Void)?

    /// Retained here because Sparkle holds its user driver strongly but its delegates weakly.
    private let userDriver: SPUUserDriver
    private let delegate: SparkleUpdaterDelegate
    private var observation: NSKeyValueObservation?

    /// `hostBundle` and `userDriver` are swapped out by tests; the app uses its own bundle and Sparkle's standard UI.
    init(hostBundle: Bundle = .main, userDriver: SPUUserDriver? = nil) {
        let delegate = SparkleUpdaterDelegate()
        let driver = userDriver ?? SPUStandardUserDriver(hostBundle: hostBundle, delegate: delegate)
        self.delegate = delegate
        self.userDriver = driver
        updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: delegate)
        delegate.onCycleFinished = { [weak self] in self?.onChange?() }
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    /// Scheduling callbacks, for tests: the delay before the next automatic check, or nil when none is scheduled.
    var onSchedule: ((TimeInterval?) -> Void)? {
        get { delegate.onSchedule }
        set { delegate.onSchedule = newValue }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var updateCheckInterval: TimeInterval {
        get { updater.updateCheckInterval }
        set { updater.updateCheckInterval = newValue }
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func start() throws {
        try updater.start()
    }

    func checkForUpdates() {
        // An accessory app isn't active when its menu is used; bring Sparkle's window to the front.
        NSApp?.activate()
        updater.checkForUpdates()
    }
}

/// Sparkle delegate callbacks. A separate object because the standard user driver needs its delegate up front.
@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var onSchedule: ((TimeInterval?) -> Void)?
    var onCycleFinished: (() -> Void)?

    /// Never ask "Check for updates automatically?": the choice lives in Settings and starts off.
    /// (Info.plist already sets `SUEnableAutomaticChecks`, which also suppresses the prompt.)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.app.info("Next update check in \(Int(delay), privacy: .public)s")
        onSchedule?(delay)
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        Log.app.info("Automatic update checks are off")
        onSchedule?(nil)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error = error as NSError?, error.code != Int(SUError.noUpdateError.rawValue) {
            Log.app.error("Update check ended: \(error.localizedDescription, privacy: .public)")
        }
        onCycleFinished?()
    }

    /// Scheduled update alerts from a menu bar app shouldn't steal focus; Sparkle shows them behind the active app.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
