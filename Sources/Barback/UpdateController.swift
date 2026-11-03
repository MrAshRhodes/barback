import AppKit
import BarbackCore

/// The updater operations Barback relies on. Sparkle in the app; a fake in tests.
@MainActor
protocol UpdateEngine: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var canCheckForUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    /// Called when `canCheckForUpdates` or `lastUpdateCheckDate` may have changed.
    var onChange: (() -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

/// Owns "Check for Updates…" and the automatic-check schedule.
///
/// - Automatic checks start off. The updater isn't even started at launch unless the user picked a schedule,
///   so nothing is requested until they choose one or check by hand.
/// - A copy installed by Homebrew never builds an updater; it points to `brew upgrade` instead.
/// - A build without an update signing key (built from source, ad-hoc) explains that it can't update itself.
@MainActor
final class UpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    enum Availability: Equatable {
        case ready
        case homebrew
        case unavailable(String)
    }

    struct Notice: Equatable {
        var title: String
        var message: String
        var copyableCommand: String?
        var link: URL?
    }

    static let releasesURL = BarbackInfo.repositoryURL.appendingPathComponent("releases")

    let availability: Availability
    @Published private(set) var frequency: UpdateCheckFrequency = .never
    @Published private(set) var canCheckNow = true
    @Published private(set) var lastCheck: Date?

    private let engine: UpdateEngine?
    private let presentNotice: @MainActor (Notice) -> Void
    private(set) var isStarted = false

    /// `makeEngine` runs only for a direct install with a valid feed and key.
    init(
        source: UpdateInstallSource,
        configuration: Result<UpdateConfiguration, UpdateConfiguration.Problem>,
        makeEngine: () -> UpdateEngine,
        presentNotice: @escaping @MainActor (Notice) -> Void = UpdateController.presentAlert
    ) {
        self.presentNotice = presentNotice
        switch (source, configuration) {
        case (.homebrew, _):
            availability = .homebrew
            engine = nil
        case (.direct, .failure(let problem)):
            availability = .unavailable(Self.describe(problem))
            engine = nil
        case (.direct, .success):
            availability = .ready
            engine = makeEngine()
        }
        super.init()

        guard let engine else {
            Log.app.info("Updates: \(String(describing: self.availability), privacy: .public)")
            return
        }
        engine.onChange = { [weak self] in self?.refresh() }
        frequency = UpdateCheckFrequency(
            automaticChecks: engine.automaticallyChecksForUpdates,
            interval: engine.updateCheckInterval
        )
        // Only a schedule the user chose needs the updater running at launch.
        if frequency != .never { _ = startIfNeeded(reportingErrors: false) }
        refresh()
    }

    /// The app's own updater: Sparkle, unless Homebrew manages this copy or the build has no update key.
    static func makeDefault() -> UpdateController {
        UpdateController(
            source: UpdateInstallSource.detect(bundleURL: Bundle.main.bundleURL),
            configuration: UpdateConfiguration.resolve(from: Bundle.main.infoDictionary),
            makeEngine: { SparkleUpdateEngine() }
        )
    }

    // MARK: - Actions

    @objc func checkForUpdates(_ sender: Any?) {
        switch availability {
        case .ready:
            guard let engine, startIfNeeded(reportingErrors: true) else { return }
            engine.checkForUpdates()
            refresh()
        case .homebrew:
            presentNotice(Self.homebrewNotice)
        case .unavailable(let reason):
            presentNotice(Notice(
                title: String(localized: "This Copy of Barback Can’t Update Itself"),
                message: reason + "\n\n" + String(localized: "Download the latest version from the releases page."),
                link: Self.releasesURL
            ))
        }
    }

    /// Turns automatic checks on at the chosen interval, or off. Writes only when the user changes it.
    func setFrequency(_ newValue: UpdateCheckFrequency) {
        guard availability == .ready, let engine, newValue != frequency else { return }
        guard startIfNeeded(reportingErrors: true) else { return }
        if let interval = newValue.interval {
            // Interval first, so the cycle Sparkle schedules when checks turn on already uses it.
            engine.updateCheckInterval = interval
            engine.automaticallyChecksForUpdates = true
        } else {
            engine.automaticallyChecksForUpdates = false
        }
        frequency = newValue
        Log.app.info("Automatic update checks: \(newValue.rawValue, privacy: .public)")
        refresh()
    }

    func refresh() {
        guard let engine else {
            canCheckNow = true
            return
        }
        // Before the updater starts, a manual check is always possible: it starts the updater first.
        let canCheck = isStarted ? engine.canCheckForUpdates : true
        if canCheckNow != canCheck { canCheckNow = canCheck }
        let last = engine.lastUpdateCheckDate
        if lastCheck != last { lastCheck = last }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return canCheckNow }
        return true
    }

    /// A "Check for Updates…" item wired to this controller.
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    // MARK: - Private

    private func startIfNeeded(reportingErrors: Bool) -> Bool {
        guard let engine else { return false }
        if isStarted { return true }
        do {
            try engine.start()
            isStarted = true
            return true
        } catch {
            Log.app.error("Updater failed to start: \(error.localizedDescription, privacy: .public)")
            if reportingErrors {
                presentNotice(Notice(
                    title: String(localized: "Couldn’t Check for Updates"),
                    message: error.localizedDescription,
                    link: Self.releasesURL
                ))
            }
            return false
        }
    }

    static var homebrewNotice: Notice {
        Notice(
            title: String(localized: "Homebrew Keeps Barback Up to Date"),
            message: String(localized: "This copy of Barback was installed with Homebrew, so update it with Homebrew instead. In Terminal, run:")
                + "\n\n" + UpdateInstallSource.homebrewUpdateCommand,
            copyableCommand: UpdateInstallSource.homebrewUpdateCommand
        )
    }

    static func describe(_ problem: UpdateConfiguration.Problem) -> String {
        switch problem {
        case .missingPublicKey:
            String(localized: "It was built without an update signing key (for example, built from source), so it can’t verify downloaded updates.")
        case .missingFeedURL, .feedURLNotHTTPS, .invalidPublicKey:
            String(localized: "Its update settings are missing or invalid, so it can’t verify downloaded updates.")
        }
    }

    static func presentAlert(_ notice: Notice) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        if notice.copyableCommand != nil {
            alert.addButton(withTitle: String(localized: "Copy Command"))
        } else if notice.link != nil {
            alert.addButton(withTitle: String(localized: "Open Releases Page"))
        }
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        if let command = notice.copyableCommand {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } else if let link = notice.link {
            NSWorkspace.shared.open(link)
        }
    }
}
