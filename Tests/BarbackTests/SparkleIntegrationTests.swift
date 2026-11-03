import AppKit
import BarbackCore
import CryptoKit
import Foundation
import Network
import Sparkle
import Testing
@testable import Barback

/// Runs the real Sparkle updater (`SPUUpdater`) against a feed served from loopback, using the shipping
/// `Resources/Info.plist` for its defaults. Nothing is installed: the recording user driver always dismisses and
/// the archive URL in the test feed never resolves. These tests use a public RFC 8032 test key, never a release key.
@Suite("Sparkle integration", .serialized)
@MainActor
struct SparkleIntegrationTests {
    @Test func shippingInfoPlistKeepsEveryAutomaticBehaviorOff() throws {
        let plist = try HostBundle.shippingInfoPlist()
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(plist["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SUFeedURL"] as? String == "https://github.com/MrAshRhodes/barback/releases/latest/download/appcast.xml")
        // Release builds inject the key (Scripts/build_app.sh); the source template must never carry one.
        #expect(plist["SUPublicEDKey"] == nil)
    }

    @Test func testKeyIsThePublicRFC8032Vector() {
        #expect(TestKey.publicBase64 == "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
    }

    @Test func offByDefaultNeverContactsTheFeed() async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        let controller = scenario.makeController()
        #expect(controller.availability == .ready)
        #expect(controller.frequency == .never)
        #expect(!controller.isStarted)
        await pump(for: 1)
        #expect(scenario.schedule.isEmpty)
        #expect(scenario.server.requests.isEmpty)

        // Even a running updater stays quiet with the shipping defaults: Sparkle decides not to schedule a check.
        try #require(scenario.engine).start()
        #expect(await pump(until: { !scenario.schedule.isEmpty }))
        await pump(for: 1.5)
        #expect(scenario.schedule == [nil])
        #expect(scenario.server.requests.isEmpty)
        #expect(scenario.driver.events.isEmpty)
    }

    @Test func neverAsksPermissionToCheckEvenWithoutThePlistDefault() async throws {
        let scenario = try Scenario(removing: ["SUEnableAutomaticChecks"])
        defer { scenario.tearDown() }
        // Sparkle asks on the second launch unless told not to.
        scenario.host.setDefault("SUHasLaunchedBefore", true)
        _ = scenario.makeController()
        try #require(scenario.engine).start()
        #expect(await pump(until: { !scenario.schedule.isEmpty || !scenario.driver.events.isEmpty }))
        await pump(for: 1)
        #expect(!scenario.driver.events.contains(.permissionRequest))
        #expect(scenario.schedule == [nil])
        #expect(scenario.server.requests.isEmpty)
        #expect(try #require(scenario.engine).automaticallyChecksForUpdates == false)
    }

    @Test func manualCheckSendsOnePlainRequestAndRejectsAnUnsignedFeed() async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.server.feed = TestFeed.unsigned()
        let controller = scenario.makeController()
        controller.checkForUpdates(nil)
        #expect(await pump(until: { scenario.driver.finished && controller.canCheckNow }))

        let request = try #require(scenario.server.requests.first)
        #expect(scenario.server.requests.count == 1)
        #expect(request.method == "GET")
        // No query string: system profiling is off, so no OS or hardware details are appended.
        #expect(request.target == "/appcast.xml")
        // Sparkle identifies the running main bundle (the test runner here), not the supplied host bundle.
        let expectedUserAgent = try #require(scenario.engine).updater.userAgentString
        #expect(request.headers["user-agent"] == expectedUserAgent)
        #expect(request.headers["cookie"] == nil)
        #expect(scenario.driver.events.first == .checking)
        #expect(scenario.driver.failed)
        #expect(!scenario.driver.offeredUpdate)
        #expect(controller.lastCheck != nil)
    }

    @Test func signedFeedIsOfferedWithoutDownloadingOrInstalling() async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.server.feed = TestFeed.signed()
        let controller = scenario.makeController()
        controller.checkForUpdates(nil)
        #expect(await pump(until: { scenario.driver.finished && controller.canCheckNow }))

        #expect(scenario.driver.events.contains(.found("1.0.0")))
        #expect(!scenario.driver.failed)
        #expect(!scenario.driver.events.contains(.download))
        #expect(!scenario.driver.events.contains(.install))
        // Only the feed was fetched: never the archive.
        #expect(scenario.server.requests.map(\.target) == ["/appcast.xml"])
    }

    @Test(arguments: [FeedTampering.editedAfterSigning, .signedWithAnotherKey, .missingSignature])
    func untrustedFeedsAreRejected(_ tampering: FeedTampering) async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.server.feed = tampering.feed()
        let controller = scenario.makeController()
        controller.checkForUpdates(nil)
        #expect(await pump(until: { scenario.driver.finished && controller.canCheckNow }))

        #expect(scenario.server.requests.count == 1)
        #expect(!scenario.driver.offeredUpdate, "\(tampering) feed was offered as an update")
        #expect(scenario.driver.failed)
        #expect(!scenario.driver.events.contains(.download))
    }

    @Test(arguments: UpdateCheckFrequency.allCases.filter { $0 != .never })
    func schedulesUseTheExactChosenInterval(_ frequency: UpdateCheckFrequency) async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.host.setDefault("SULastCheckTime", Date())
        let controller = scenario.makeController()
        controller.setFrequency(frequency)

        let interval = try #require(frequency.interval)
        let engine = try #require(scenario.engine)
        #expect(controller.frequency == frequency)
        #expect(engine.automaticallyChecksForUpdates)
        #expect(engine.updateCheckInterval == interval)
        #expect(scenario.host.value("SUScheduledCheckInterval") as? Double == interval)
        #expect(scenario.host.value("SUEnableAutomaticChecks") as? Bool == true)
        // Let Sparkle's launch cycle and its delayed settings-change reset both run.
        #expect(await pump(until: { scenario.schedule.count >= 2 }))
        await pump(for: 0.5)
        // Every scheduled check is one full interval after the last one, never sooner.
        #expect(!scenario.schedule.isEmpty)
        for delay in scenario.schedule {
            let delay = try #require(delay)
            #expect(delay > interval - 120 && delay <= interval)
        }
        #expect(scenario.server.requests.isEmpty)
    }

    @Test func choosingAScheduleForTheFirstTimeChecksRightAway() async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.server.feed = TestFeed.signed()
        let controller = scenario.makeController()
        controller.setFrequency(.monthly)
        // Never checked before, so the first scheduled check is already due.
        #expect(await pump(until: { scenario.driver.finished && controller.canCheckNow }))
        await pump(for: 1.5)
        #expect(scenario.server.requests.map(\.target) == ["/appcast.xml"])
        // Background checks never show "checking" UI; they still never download or install.
        #expect(!scenario.driver.events.contains(.checking))
        #expect(!scenario.driver.events.contains(.download))
        #expect(!scenario.driver.events.contains(.install))
    }

    @Test func choosingNeverAfterASchedulePersistsAndCancelsTheNextCheck() async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.host.setDefault("SULastCheckTime", Date())
        let controller = scenario.makeController()
        controller.setFrequency(.weekly)
        #expect(await pump(until: { scenario.schedule.count >= 2 }))
        #expect(scenario.schedule.allSatisfy { $0 != nil })

        controller.setFrequency(.never)
        #expect(controller.frequency == .never)
        #expect(try #require(scenario.engine).automaticallyChecksForUpdates == false)
        #expect(scenario.host.value("SUEnableAutomaticChecks") as? Bool == false)
        #expect(await pump(until: { scenario.schedule.last == .some(nil) }))
        await pump(for: 1.5)
        #expect(scenario.schedule.last == .some(nil))
        #expect(scenario.server.requests.isEmpty)
    }

    @Test func aPersistedScheduleResumesAtLaunchWithoutAnImmediateRequest() async throws {
        let scenario = try Scenario()
        defer { scenario.tearDown() }
        scenario.host.setDefault("SUEnableAutomaticChecks", true)
        scenario.host.setDefault("SUScheduledCheckInterval", 604_800.0)
        scenario.host.setDefault("SULastCheckTime", Date())
        let controller = scenario.makeController()
        #expect(controller.frequency == .weekly)
        #expect(controller.isStarted)
        #expect(await pump(until: { !scenario.schedule.isEmpty }))
        await pump(for: 1)
        let delay = try #require(scenario.schedule.last ?? nil)
        #expect(delay > 604_800 - 120 && delay <= 604_800)
        #expect(scenario.server.requests.isEmpty)
    }
}

// MARK: - Scenario

@MainActor
private final class Scenario {
    let server: LoopbackServer
    let host: HostBundle
    let driver = RecordingUserDriver()
    private(set) var engine: SparkleUpdateEngine?
    /// Every scheduling decision Sparkle reported: the delay before the next check, or nil when none is scheduled.
    private(set) var schedule: [TimeInterval?] = []

    init(removing removedKeys: [String] = []) throws {
        server = try LoopbackServer()
        host = try HostBundle.make(feedURL: "http://127.0.0.1:\(server.port)/appcast.xml", removing: removedKeys)
    }

    func makeController() -> UpdateController {
        UpdateController(
            source: .direct,
            configuration: UpdateConfiguration.resolve(from: [
                "SUFeedURL": "https://example.com/appcast.xml",
                "SUPublicEDKey": TestKey.publicBase64,
            ]),
            makeEngine: {
                let engine = SparkleUpdateEngine(hostBundle: host.bundle, userDriver: driver)
                engine.onSchedule = { [weak self] delay in self?.schedule.append(delay) }
                self.engine = engine
                return engine
            },
            presentNotice: { _ in }
        )
    }

    func tearDown() {
        engine?.automaticallyChecksForUpdates = false
        engine = nil
        server.stop()
        host.cleanUp()
    }
}

// MARK: - Test keys and feeds

private enum TestKey {
    /// RFC 8032 section 7.1, test vector 1. Public; not a release credential.
    static let signing: Curve25519.Signing.PrivateKey = {
        let seed = Data([
            0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
            0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
        ])
        return try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }()

    static var publicBase64: String { signing.publicKey.rawRepresentation.base64EncodedString() }
}

enum FeedTampering: CustomTestStringConvertible, Sendable {
    case editedAfterSigning
    case signedWithAnotherKey
    case missingSignature

    var testDescription: String {
        switch self {
        case .editedAfterSigning: "edited after signing"
        case .signedWithAnotherKey: "signed with another key"
        case .missingSignature: "unsigned"
        }
    }

    @MainActor func feed() -> Data {
        switch self {
        case .editedAfterSigning:
            Data(String(decoding: TestFeed.signed(), as: UTF8.self).replacingOccurrences(of: "<title>1.0.0", with: "<title>9.9.9").utf8)
        case .signedWithAnotherKey:
            TestFeed.signed(by: Curve25519.Signing.PrivateKey())
        case .missingSignature:
            TestFeed.unsigned()
        }
    }
}

/// An appcast shaped like the one `Scripts/generate_appcast.sh` publishes: one item whose enclosure carries an
/// EdDSA archive signature, with the whole feed signed in a trailing comment.
private enum TestFeed {
    static let archive = Data("Barback fixture archive".utf8)

    static func body(signingArchiveWith key: Curve25519.Signing.PrivateKey) -> String {
        let archiveSignature = try! key.signature(for: archive).base64EncodedString()
        return """
        <?xml version="1.0" standalone="yes"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>Barback</title>
                <item>
                    <title>1.0.0</title>
                    <pubDate>Tue, 03 Nov 2026 12:00:00 +0100</pubDate>
                    <sparkle:version>999999</sparkle:version>
                    <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
                    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                    <enclosure url="https://updates.invalid/Barback-1.0.0.zip" length="\(archive.count)" type="application/octet-stream" sparkle:edSignature="\(archiveSignature)"></enclosure>
                </item>
            </channel>
        </rss>
        """
    }

    static func unsigned() -> Data {
        Data(body(signingArchiveWith: TestKey.signing).utf8)
    }

    static func signed(by key: Curve25519.Signing.PrivateKey = TestKey.signing) -> Data {
        let body = body(signingArchiveWith: key)
        let signature = try! key.signature(for: Data(body.utf8)).base64EncodedString()
        return Data("\(body)<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(body.utf8.count)\n-->\n".utf8)
    }
}

// MARK: - Host bundle

/// A throwaway app bundle standing in for Barback: the shipping Info.plist with a unique identifier, the test
/// public key and a loopback feed. Sparkle keeps its state for a non-main bundle in that identifier's preferences.
private struct HostBundle {
    let directory: URL
    let bundle: Bundle
    let identifier: String

    static func shippingInfoPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static func make(feedURL: String, removing removedKeys: [String]) throws -> HostBundle {
        let identifier = "io.github.mrashrhodes.barback.tests.\(UUID().uuidString.lowercased())"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("barback-updater-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Host.app", isDirectory: true)
        let contents = directory.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist = try shippingInfoPlist()
        plist["CFBundleIdentifier"] = identifier
        plist["CFBundleVersion"] = "1"
        plist["CFBundleShortVersionString"] = "0.1.0"
        plist["SUPublicEDKey"] = TestKey.publicBase64
        plist["SUFeedURL"] = feedURL
        for key in removedKeys { plist[key] = nil }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        return HostBundle(directory: directory, bundle: bundle, identifier: identifier)
    }

    func setDefault(_ key: String, _ value: Any) {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList, identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(identifier as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func value(_ key: String) -> Any? {
        CFPreferencesAppSynchronize(identifier as CFString)
        return CFPreferencesCopyAppValue(key as CFString, identifier as CFString)
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: identifier)
        CFPreferencesAppSynchronize(identifier as CFString)
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(identifier).plist")
        try? FileManager.default.removeItem(at: preferences)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

// MARK: - Recording user driver

/// Sparkle's user-interface seam. Records what Sparkle asks for and always declines to download or install.
@MainActor
private final class RecordingUserDriver: NSObject, SPUUserDriver {
    enum Event: Equatable {
        case permissionRequest
        case checking
        case found(String)
        case notFound
        case error(Int)
        case download
        case install
        case dismissed
    }

    private(set) var events: [Event] = []

    var offeredUpdate: Bool {
        events.contains { if case .found = $0 { true } else { false } }
    }

    var failed: Bool {
        events.contains { if case .error = $0 { true } else { false } }
    }

    /// True once Sparkle has reported an outcome for a check.
    var finished: Bool {
        events.contains(.dismissed) || events.contains(.notFound)
            || events.contains { if case .error = $0 { true } else { false } }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        events.append(.permissionRequest)
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        events.append(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append(.found(appcastItem.displayVersionString))
        reply(.dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        events.append(.notFound)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        events.append(.error((error as NSError).code))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        events.append(.download)
        cancellation()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {
        events.append(.install)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append(.install)
        reply(.dismiss)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        events.append(.install)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        events.append(.install)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        events.append(.dismissed)
    }
}

// MARK: - Loopback server

/// A minimal HTTP/1.1 server bound to 127.0.0.1 that records every request and answers with `feed`.
private final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "barback.tests.loopback-server")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var body = Data()
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw ServerError.didNotStart
        }
        self.port = port
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            receive(on: connection, buffered: Data())
        }
    }

    enum ServerError: Error { case didNotStart }

    var feed: Data {
        get { lock.withLock { body } }
        set { lock.withLock { body = newValue } }
    }

    var requests: [Request] { lock.withLock { recorded } }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let request = Self.parse(String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                lock.withLock { self.recorded.append(request) }
                respond(to: request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffered: buffer)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let found = request.target == "/appcast.xml"
        let payload = found ? feed : Data("not found".utf8)
        let head = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: application/xml\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parse(_ head: String) -> Request {
        let lines = head.components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: start.first ?? "", target: start.count > 1 ? start[1] : "", headers: headers)
    }
}

// MARK: - Run loop helpers

/// Sparkle works through both main-queue blocks and run-loop timers. Suspending the main actor lets the main
/// queue drain; spinning the run loop fires timers such as its delayed settings-change reset.
@MainActor
private func pump(for seconds: TimeInterval) async {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end {
        await spin()
    }
}

/// Spins until `condition` holds or `timeout` passes.
@MainActor
private func pump(until condition: () -> Bool, timeout: TimeInterval = 20) async -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while !condition(), Date() < end {
        await spin()
    }
    return condition()
}

@MainActor
private func spin() async {
    drainMainRunLoop()
    try? await Task.sleep(for: .milliseconds(10))
}

@MainActor
private func drainMainRunLoop() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
}
