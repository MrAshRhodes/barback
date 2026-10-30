import CoreGraphics
import Foundation

/// A menu bar item's identity that survives relaunches, unlike its window ID.
///
/// `owner` is the bundle identifier of the app that owns the item (its process name when there is none), `detail`
/// is the item's own Accessibility title or description when known (an app can have several items; macOS 26
/// hosts most of them in Control Center), and `ordinal` tells items with the same owner and detail apart by
/// their position, left to right. Without Accessibility, system-hosted items share one owner, so their
/// ordinals follow the menu bar's current order.
public struct ItemKey: Hashable, Codable, Sendable {
    public var owner: String
    public var detail: String?
    public var ordinal: Int

    public init(owner: String, detail: String? = nil, ordinal: Int = 0) {
        self.owner = owner
        self.detail = detail
        self.ordinal = ordinal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(String.self, forKey: .owner)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        ordinal = max(0, try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0)
    }
}

/// Assigns `ItemKey`s to a scan's items.
public enum ItemKeyAssigner {
    /// The owner and detail half of an item's key.
    public static func identity(of item: MenuBarItem) -> (owner: String, detail: String?) {
        let owner = item.bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? item.ownerName
        let raw = item.detail ?? (item.isHostedBySystem ? item.title : nil)
        let detail = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (owner, detail?.isEmpty == false ? detail : nil)
    }

    /// Keys by window ID. Ordinals are counted per display, so the same item has the same key whichever
    /// display's menu bar is being looked at; items whose display can't be told share one bucket.
    public static func keys(for items: [MenuBarItem], displays: [MenuBarDisplay] = []) -> [UInt32: ItemKey] {
        struct Bucket: Hashable {
            var display: Int
            var owner: String
            var detail: String?
        }
        var buckets: [Bucket: [MenuBarItem]] = [:]
        var identities: [UInt32: (owner: String, detail: String?)] = [:]
        for item in items {
            let id = identity(of: item)
            identities[item.windowID] = id
            let display = ItemClassifier.displayIndex(for: item.frame, in: displays) ?? -1
            buckets[Bucket(display: display, owner: id.owner, detail: id.detail), default: []].append(item)
        }
        var result: [UInt32: ItemKey] = [:]
        result.reserveCapacity(items.count)
        for (bucket, members) in buckets {
            let ordered = members.sorted {
                $0.frame.minX == $1.frame.minX ? $0.windowID < $1.windowID : $0.frame.minX < $1.frame.minX
            }
            for (ordinal, item) in ordered.enumerated() {
                result[item.windowID] = ItemKey(owner: bucket.owner, detail: bucket.detail, ordinal: ordinal)
            }
        }
        return result
    }

    /// The item carrying `key` in a fresh scan. Several displays can show the same item, so `display` narrows
    /// the search to one of them.
    public static func item(
        for key: ItemKey,
        in items: [MenuBarItem],
        displays: [MenuBarDisplay] = [],
        display: Int? = nil
    ) -> MenuBarItem? {
        let keys = keys(for: items, displays: displays)
        return items.first {
            keys[$0.windowID] == key
                && (display == nil || ItemClassifier.displayIndex(for: $0.frame, in: displays) == display)
        }
    }
}
