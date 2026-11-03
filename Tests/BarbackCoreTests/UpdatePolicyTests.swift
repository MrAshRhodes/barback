import Foundation
import Testing
@testable import BarbackCore

@Suite("Update policy")
struct UpdatePolicyTests {
    @Test func frequenciesMapToExactIntervalsAndNeverDisablesChecking() {
        #expect(UpdateCheckFrequency.allCases == [.never, .daily, .weekly, .monthly])
        #expect(UpdateCheckFrequency.never.interval == nil)
        #expect(UpdateCheckFrequency.daily.interval == 86_400)
        #expect(UpdateCheckFrequency.weekly.interval == 604_800)
        #expect(UpdateCheckFrequency.monthly.interval == 2_592_000)
    }

    @Test func persistedStateRoundTripsEveryChoice() {
        for frequency in UpdateCheckFrequency.allCases {
            let restored = UpdateCheckFrequency(
                automaticChecks: frequency.interval != nil,
                interval: frequency.interval ?? 86_400
            )
            #expect(restored == frequency)
        }
    }

    @Test func automaticChecksOffIsNeverWhateverTheStoredInterval() {
        for interval in [0, 60, 86_400, 604_800, 2_592_000, 31_536_000] as [TimeInterval] {
            #expect(UpdateCheckFrequency(automaticChecks: false, interval: interval) == .never)
        }
    }

    @Test func handEditedIntervalsSnapToTheNearestPreset() {
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 0) == .daily)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 3 * 3_600) == .daily)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 3 * 86_400) == .daily)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 5 * 86_400) == .weekly)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 20 * 86_400) == .monthly)
        #expect(UpdateCheckFrequency(automaticChecks: true, interval: 365 * 86_400) == .monthly)
    }

    // MARK: Configuration

    private static let key = Data((0..<UpdateConfiguration.publicKeyLength).map(UInt8.init)).base64EncodedString()
    private static let feed = "https://github.com/MrAshRhodes/barback/releases/latest/download/appcast.xml"

    @Test func configurationNeedsAnHTTPSFeedAndAnEd25519PublicKey() throws {
        let plist: [String: Any] = ["SUFeedURL": " \(Self.feed) ", "SUPublicEDKey": " \(Self.key)\n"]
        let configuration = try UpdateConfiguration.resolve(from: plist).get()
        #expect(configuration.feedURL.absoluteString == Self.feed)
        #expect(configuration.publicKey == Self.key)
    }

    @Test func configurationReportsEachMissingOrMalformedValue() {
        func problem(_ plist: [String: Any]?) -> UpdateConfiguration.Problem? {
            if case .failure(let problem) = UpdateConfiguration.resolve(from: plist) { return problem }
            return nil
        }
        #expect(problem(nil) == .missingFeedURL)
        #expect(problem([:]) == .missingFeedURL)
        #expect(problem(["SUFeedURL": "  ", "SUPublicEDKey": Self.key]) == .missingFeedURL)
        #expect(problem(["SUFeedURL": 3, "SUPublicEDKey": Self.key]) == .missingFeedURL)
        #expect(problem(["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": Self.key]) == .feedURLNotHTTPS)
        #expect(problem(["SUFeedURL": "file:///tmp/appcast.xml", "SUPublicEDKey": Self.key]) == .feedURLNotHTTPS)
        #expect(problem(["SUFeedURL": "https:///appcast.xml", "SUPublicEDKey": Self.key]) == .feedURLNotHTTPS)
        #expect(problem(["SUFeedURL": Self.feed]) == .missingPublicKey)
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": ""]) == .missingPublicKey)
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": "not base64!"]) == .invalidPublicKey)
        let short = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": short]) == .invalidPublicKey)
        let long = Data(repeating: 1, count: 33).base64EncodedString()
        #expect(problem(["SUFeedURL": Self.feed, "SUPublicEDKey": long]) == .invalidPublicKey)
    }

    // MARK: Install source

    /// A throwaway Homebrew-like tree: `prefix/Caskroom` plus an `Applications` folder.
    private struct Fixture {
        let root: URL
        var caskroom: URL { root.appendingPathComponent("prefix/Caskroom", isDirectory: true) }
        var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BarbackUpdateTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        }

        func app(in folder: URL) throws -> URL {
            let url = folder.appendingPathComponent("Barback.app", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func stagedFolder(token: String = "barback", version: String = "0.3.0") throws -> URL {
            let folder = caskroom.appendingPathComponent("\(token)/\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        func link(_ link: URL, to destination: URL) throws {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func caskThatMovedTheAppIntoApplicationsIsHomebrewManaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app(in: fixture.applications)
        try fixture.link(try fixture.stagedFolder().appendingPathComponent("Barback.app"), to: installed)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: [fixture.caskroom]) == .homebrew)
    }

    @Test func caskThatStagedTheAppAndLinkedItIntoApplicationsIsHomebrewManaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = try fixture.app(in: fixture.stagedFolder())
        let linked = fixture.applications.appendingPathComponent("Barback.app")
        try fixture.link(linked, to: staged)
        #expect(UpdateInstallSource.detect(bundleURL: linked, caskroomRoots: [fixture.caskroom]) == .homebrew)
        #expect(UpdateInstallSource.detect(bundleURL: staged, caskroomRoots: [fixture.caskroom]) == .homebrew)
    }

    @Test func aSeparateDirectCopyStillUpdatesItselfWhileTheCaskIsInstalledElsewhere() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let brewCopy = try fixture.app(in: fixture.applications)
        try fixture.link(try fixture.stagedFolder().appendingPathComponent("Barback.app"), to: brewCopy)
        let downloads = fixture.root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let directCopy = try fixture.app(in: downloads)
        #expect(UpdateInstallSource.detect(bundleURL: directCopy, caskroomRoots: [fixture.caskroom]) == .direct)
    }

    @Test func otherCasksAndMissingCaskroomsDoNotCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app(in: fixture.applications)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: [fixture.caskroom]) == .direct)
        let other = try fixture.stagedFolder(token: "something-else").appendingPathComponent("Barback.app")
        try fixture.link(other, to: installed)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: [fixture.caskroom]) == .direct)
        let missing = fixture.root.appendingPathComponent("nowhere/Caskroom", isDirectory: true)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: [missing]) == .direct)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: []) == .direct)
    }

    @Test func aStaleCaskroomLinkToAnotherLocationDoesNotMarkThisCopyAsHomebrew() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try fixture.app(in: fixture.applications)
        let gone = fixture.root.appendingPathComponent("Removed/Barback.app")
        try fixture.link(try fixture.stagedFolder().appendingPathComponent("Barback.app"), to: gone)
        #expect(UpdateInstallSource.detect(bundleURL: installed, caskroomRoots: [fixture.caskroom]) == .direct)
    }

    @Test func defaultCaskroomRootsCoverBothArchitecturesAndAnExplicitPrefix() {
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: [:]).map(\.path)
            == ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"])
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: ["HOMEBREW_PREFIX": "/opt/brew"]).map(\.path)
            == ["/opt/brew/Caskroom", "/opt/homebrew/Caskroom", "/usr/local/Caskroom"])
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: ["HOMEBREW_PREFIX": "/usr/local"]).map(\.path)
            == ["/usr/local/Caskroom", "/opt/homebrew/Caskroom"])
        #expect(UpdateInstallSource.defaultCaskroomRoots(environment: ["HOMEBREW_PREFIX": "relative"]).map(\.path)
            == ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"])
    }

    @Test func homebrewUpdateCommandMatchesTheDocumentedUpgrade() {
        #expect(UpdateInstallSource.homebrewUpdateCommand == "brew update && brew upgrade --cask barback")
    }
}
