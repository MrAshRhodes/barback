import Foundation

/// How often Barback looks for a new version by itself.
///
/// `never` is the default: nothing is requested until the user chooses "Check for Updates…".
public enum UpdateCheckFrequency: String, CaseIterable, Identifiable, Sendable {
    case never, daily, weekly, monthly

    public var id: String { rawValue }

    /// Seconds between automatic checks; nil while automatic checks are off.
    public var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        }
    }

    /// Reads back the persisted updater state. An interval that matches no preset (a hand-edited preference)
    /// maps to the nearest one, so the picker always shows a valid choice.
    public init(automaticChecks: Bool, interval: TimeInterval) {
        guard automaticChecks else {
            self = .never
            return
        }
        let scheduled: [UpdateCheckFrequency] = [.daily, .weekly, .monthly]
        self = scheduled.min { lhs, rhs in
            abs((lhs.interval ?? 0) - interval) < abs((rhs.interval ?? 0) - interval)
        } ?? .weekly
    }
}

/// Whether this copy of Barback may replace itself.
///
/// A copy installed by Homebrew belongs to `brew upgrade`: swapping the app underneath Homebrew would leave its
/// records pointing at a version that is no longer there. Those copies never update themselves.
public enum UpdateInstallSource: Equatable, Sendable {
    case direct
    case homebrew

    public static let caskToken = "barback"
    public static let appName = "Barback.app"
    public static let homebrewUpdateCommand = "brew update && brew upgrade --cask \(caskToken)"

    /// Caskroom folders of the usual Homebrew prefixes (Apple silicon, Intel), plus `HOMEBREW_PREFIX` when set.
    public static func defaultCaskroomRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var prefixes = ["/opt/homebrew", "/usr/local"]
        if let custom = environment["HOMEBREW_PREFIX"], custom.hasPrefix("/") {
            prefixes.insert(custom, at: 0)
        }
        var seen = Set<String>()
        return prefixes
            .filter { seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Caskroom", isDirectory: true) }
    }

    /// Homebrew-managed means the running app *is* the copy a cask installed. Two layouts exist:
    /// the cask stages the app in `Caskroom/barback/<version>/` and links it into /Applications, or it moves the app
    /// to /Applications and leaves a symlink in the Caskroom. A separate direct download elsewhere is not affected
    /// merely because the cask is also installed.
    public static func detect(
        bundleURL: URL,
        caskroomRoots: [URL] = defaultCaskroomRoots(),
        fileManager: FileManager = .default
    ) -> UpdateInstallSource {
        let bundle = normalized(bundleURL)
        for root in caskroomRoots {
            let caskDirectory = root.appendingPathComponent(caskToken, isDirectory: true)
            let stagedPrefix = normalized(caskDirectory).path + "/"
            if bundle.path.hasPrefix(stagedPrefix) { return .homebrew }
            guard let versions = try? fileManager.contentsOfDirectory(atPath: caskDirectory.path) else { continue }
            for version in versions {
                let staged = caskDirectory
                    .appendingPathComponent(version, isDirectory: true)
                    .appendingPathComponent(appName, isDirectory: true)
                if normalized(staged) == bundle { return .homebrew }
            }
        }
        return .direct
    }

    private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

/// The two Info.plist values Sparkle needs: where the signed appcast lives and the public key updates must verify against.
public struct UpdateConfiguration: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable {
        case missingFeedURL
        case feedURLNotHTTPS
        case missingPublicKey
        case invalidPublicKey
    }

    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    /// Length of an Ed25519 public key in bytes.
    public static let publicKeyLength = 32

    public let feedURL: URL
    public let publicKey: String

    public static func resolve(from infoDictionary: [String: Any]?) -> Result<UpdateConfiguration, Problem> {
        guard let rawFeed = trimmed(infoDictionary?[feedURLKey]), let feedURL = URL(string: rawFeed) else {
            return .failure(.missingFeedURL)
        }
        guard feedURL.scheme?.lowercased() == "https", feedURL.host?.isEmpty == false else {
            return .failure(.feedURLNotHTTPS)
        }
        guard let key = trimmed(infoDictionary?[publicKeyKey]) else { return .failure(.missingPublicKey) }
        guard Data(base64Encoded: key)?.count == publicKeyLength else { return .failure(.invalidPublicKey) }
        return .success(UpdateConfiguration(feedURL: feedURL, publicKey: key))
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
