import Foundation

/// Why a settings file couldn't be imported. Messages are shown to the user as-is.
public enum SettingsTransferError: Error, Equatable, LocalizedError, Sendable {
    case fileTooLarge(bytes: Int)
    case malformedJSON
    case notASettingsFile
    case unsupportedFormatVersion(found: Int, supported: Int)
    case invalidValue(path: String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The file is too large to be a Barback settings file."
        case .malformedJSON:
            return "The file isn’t valid JSON."
        case .notASettingsFile:
            return "The file isn’t a Barback settings file (it has no “formatVersion”)."
        case let .unsupportedFormatVersion(found, supported):
            return "The file uses settings format \(found), but this version of Barback only reads format \(supported) or earlier. Update Barback and try again."
        case let .invalidValue(path):
            return "The file has an invalid value for “\(path)”."
        }
    }

    public var recoverySuggestion: String? {
        "Your current settings were not changed."
    }
}

/// Converts settings to and from a human-readable JSON file:
///
/// ```json
/// { "app": "Barback", "appVersion": "1.2.0", "formatVersion": 1, "settings": { … } }
/// ```
///
/// `settings` mirrors `BarbackSettings`' Codable shape. On import, keys missing from the file keep the current
/// value (objects such as `appearance` are merged key by key; arrays such as `groups` are replaced whole),
/// unknown keys are ignored, and the result is sanitized like any saved settings. Machine-specific state
/// (menu bar icon positions, the welcome tip flag, Launch at Login) isn't part of the file.
public enum SettingsTransfer {
    /// Bump when the file changes in a way older versions can't read.
    public static let formatVersion = 1
    public static let maxFileSize = 1_000_000
    public static let fileExtension = "json"

    public static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Barback Settings \(formatter.string(from: date)).\(fileExtension)"
    }

    /// Pretty-printed, key-sorted JSON for `settings`.
    public static func encode(_ settings: BarbackSettings, appVersion: String) throws -> Data {
        let s = settings.sanitized()
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any] else {
            throw SettingsTransferError.malformedJSON
        }
        // Codable leaves nil out; write an explicit null so "no shortcut" survives an import.
        if s.hotkey == nil { object["hotkey"] = NSNull() }
        let document: [String: Any] = [
            "app": BarbackInfo.name,
            "appVersion": appVersion,
            "formatVersion": formatVersion,
            "settings": object,
        ]
        var data = try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    /// The settings in `data`, with anything the file leaves out taken from `current`. Throws without side
    /// effects on any problem, so the caller can apply the result in one step or not at all.
    public static func decode(_ data: Data, current: BarbackSettings) throws -> BarbackSettings {
        guard data.count <= maxFileSize else { throw SettingsTransferError.fileTooLarge(bytes: data.count) }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SettingsTransferError.malformedJSON
        }
        guard let document = root as? [String: Any], let rawVersion = document["formatVersion"] else {
            throw SettingsTransferError.notASettingsFile
        }
        guard let number = rawVersion as? NSNumber, !isBool(number),
              let version = Int(exactly: number.doubleValue), version >= 1 else {
            throw SettingsTransferError.invalidValue(path: "formatVersion")
        }
        guard version <= formatVersion else {
            throw SettingsTransferError.unsupportedFormatVersion(found: version, supported: formatVersion)
        }
        let settingsObject: [String: Any]
        if let raw = document["settings"] {
            guard let object = raw as? [String: Any] else { throw SettingsTransferError.invalidValue(path: "settings") }
            settingsObject = object
        } else {
            settingsObject = [:]
        }

        guard let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any] else {
            throw SettingsTransferError.malformedJSON
        }
        let merged = merge(settingsObject, into: base)
        do {
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            return try JSONDecoder().decode(BarbackSettings.self, from: mergedData).sanitized()
        } catch let error as DecodingError {
            throw SettingsTransferError.invalidValue(path: path(of: error))
        } catch {
            throw SettingsTransferError.malformedJSON
        }
    }

    /// Overlays `patch` on `base`: nested objects merge, everything else (arrays, scalars, null) replaces.
    static func merge(_ patch: [String: Any], into base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in patch {
            if let patchObject = value as? [String: Any], let baseObject = base[key] as? [String: Any] {
                result[key] = merge(patchObject, into: baseObject)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// e.g. "settings.groups[0].name".
    private static func path(of error: DecodingError) -> String {
        let codingPath: [CodingKey]
        var last: CodingKey?
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            codingPath = context.codingPath
        case let .keyNotFound(key, context):
            codingPath = context.codingPath
            last = key
        @unknown default:
            codingPath = []
        }
        var text = "settings"
        for key in codingPath + (last.map { [$0] } ?? []) {
            if let index = key.intValue { text += "[\(index)]" } else { text += ".\(key.stringValue)" }
        }
        return text
    }
}
