import Foundation

/// Static product metadata shared by the app shell and tests.
public enum BarbackInfo {
    public static let name = "Barback"
    public static let bundleIdentifier = "io.github.mrashrhodes.barback"
    public static let logSubsystem = bundleIdentifier
    /// Used when running the bare executable (no Info.plist), e.g. `swift run`.
    public static let fallbackVersion = "0.1.0"
    public static let repositoryURL = URL(string: "https://github.com/MrAshRhodes/barback")!
    public static let copyright = "© 2026 Ashley Rhodes. MIT License."

    /// Reads `CFBundleShortVersionString` from an Info.plist dictionary, falling back to `fallbackVersion`.
    public static func version(from infoDictionary: [String: Any]?) -> String {
        if let v = infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return v
        }
        return fallbackVersion
    }

    /// Reads `CFBundleVersion` (build number), or nil when absent.
    public static func build(from infoDictionary: [String: Any]?) -> String? {
        guard let b = infoDictionary?["CFBundleVersion"] as? String, !b.isEmpty else { return nil }
        return b
    }
}
