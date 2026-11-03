import AppKit
import ApplicationServices
import BarbackCore

/// A running app, copied off `NSWorkspace` so a scan can run off the main actor.
struct RunningAppInfo: Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String?

    @MainActor
    static func current() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map {
            RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier)
        }
    }
}

/// One scan of the menu bar: the window-list items and, when Accessibility is allowed, the elements behind them.
struct MenuBarScan {
    var items: [MenuBarItem]
    var elements: [(frame: CGRect, element: AXUIElement)]

    func elementIndex(itemAt frame: CGRect) -> Int? {
        let targets = items.indices.filter { items[$0].frame == frame }
        guard targets.count == 1 else { return nil }
        return FrameMatcher.matchIndices(for: items.map(\.frame), among: elements.map(\.frame))[targets[0]]
    }
}

/// Injected at the IPC boundary so failures and slow hosts can be tested without Accessibility permission.
struct AccessibilityReader {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var setTimeout: (AXUIElement, Float) -> AXError = { AXUIElementSetMessagingTimeout($0, $1) }
    var copyAttribute: (AXUIElement, String) -> (error: AXError, value: CFTypeRef?) = { element, attribute in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }
    var press: (AXUIElement) -> AXError = { AXUIElementPerformAction($0, kAXPressAction as CFString) }
}

/// Reads status items through the Accessibility API (`AXExtrasMenuBar`). Everything here blocks on other apps,
/// so call it from a background task only.
enum AccessibilityScanner {
    /// Lists the window-list items and resolves them to apps and names when `trusted`.
    nonisolated static func scan(tops: [CGFloat], trusted: Bool, apps: [RunningAppInfo]) -> MenuBarScan {
        let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return scan(windows: raw, tops: tops, trusted: trusted, apps: apps)
    }

    nonisolated static func scan(
        windows: [[String: Any]], tops: [CGFloat], trusted: Bool, apps: [RunningAppInfo],
        reader: AccessibilityReader = AccessibilityReader()
    ) -> MenuBarScan {
        var items = MenuBarItemParser.parse(windows, menuBarTops: tops)
        // Apps draw their own windows except on macOS 26, where Control Center hosts them all.
        var bundleIDs: [pid_t: String] = [:]
        for app in apps { if let id = app.bundleID { bundleIDs[app.pid] = id } }
        for index in items.indices where !items[index].isHostedBySystem {
            items[index].bundleID = bundleIDs[pid_t(items[index].ownerPID)]
        }
        guard trusted else { return MenuBarScan(items: items, elements: []) }
        let entries = extras(apps: apps, reader: reader)
        for item in items where item.isHostedBySystem {
            Log.items.debug("CG system-hosted item frame=\(String(describing: item.frame), privacy: .private)")
        }
        items = MenuBarItemParser.resolve(items, using: entries.map(\.item))
        return MenuBarScan(items: items, elements: entries.map { ($0.item.frame, $0.element) })
    }

    /// The status item elements of every other running app.
    nonisolated static func extras(
        apps: [RunningAppInfo], reader: AccessibilityReader = AccessibilityReader()
    ) -> [(item: AccessibilityItem, element: AXUIElement)] {
        var result: [(item: AccessibilityItem, element: AXUIElement)] = []
        for app in apps where app.pid != getpid() {
            let systemHost = app.bundleID.map { MenuBarItemParser.systemHostBundleIDs.contains($0) } ?? false
            let started = reader.now()
            let deadline = started + (systemHost ? 1 : 0.3)
            let timeout: TimeInterval = systemHost ? 0.75 : 0.1
            var childCount = 0
            var resolvedCount = 0
            var errorCount = 0
            defer {
                let elapsed = (reader.now() - started) * 1000
                Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) ms=\(elapsed) children=\(childCount) entries=\(resolvedCount) errors=\(errorCount)")
            }
            func attribute(_ element: AXUIElement, _ attribute: String) -> AttributeRead {
                let remaining = deadline - reader.now()
                guard remaining > 0 else {
                    errorCount += 1
                    Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) exhausted scan budget at \(attribute, privacy: .public)")
                    return .failed
                }
                // A timeout on the app root does not apply to the bar or its children.
                let timeoutError = reader.setTimeout(element, Float(min(timeout, remaining)))
                guard timeoutError == .success else {
                    errorCount += 1
                    Log.items.debug("AX timeout setup failed: \(timeoutError.rawValue)")
                    return .failed
                }
                let response = reader.copyAttribute(element, attribute)
                switch response.error {
                case .success:
                    return response.value.map(AttributeRead.value) ?? .absent
                case .noValue, .attributeUnsupported:
                    return .absent
                default:
                    errorCount += 1
                    Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) attribute=\(attribute, privacy: .public) error=\(response.error.rawValue)")
                    return .failed
                }
            }
            func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                attribute(element, name).value
            }
            /// Nil when the read failed; `.some(nil)` when the attribute is absent or not a string.
            func string(_ element: AXUIElement, _ name: String) -> String?? {
                switch attribute(element, name) {
                case .failed: return nil
                case .absent: return .some(nil)
                case .value(let value): return .some(value as? String)
                }
            }
            let root = AXUIElementCreateApplication(app.pid)
            guard let bar = element(read(root, "AXExtrasMenuBar")),
                  let children = read(bar, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            childCount = children.count
            for child in children {
                guard reader.now() < deadline else {
                    Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) scan budget exhausted; remaining children skipped")
                    break
                }
                guard let origin = point(read(child, kAXPositionAttribute)),
                      let size = size(read(child, kAXSizeAttribute)) else {
                    Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) child skipped: missing or invalid frame")
                    continue
                }
                guard size.width > 0, size.height > 0,
                      origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite else {
                    Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) child skipped: empty or non-finite frame=\(String(describing: CGRect(origin: origin, size: size)), privacy: .private)")
                    continue
                }
                // System hosts are identified by AXIdentifier, other apps by description or title. A failed read
                // (unlike an absent attribute) must not publish the item under a different key.
                let identifier: String?
                if systemHost {
                    guard let read = string(child, kAXIdentifierAttribute) else {
                        Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) child skipped: identifier read failed")
                        continue
                    }
                    identifier = read
                } else {
                    identifier = nil
                }
                var label = string(child, kAXDescriptionAttribute)
                if case .some(.none) = label { label = string(child, kAXTitleAttribute) }
                if label == nil, !systemHost {
                    Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) child skipped: description or title read failed")
                    continue
                }
                let description = label ?? nil
                let frame = CGRect(origin: origin, size: size)
                let item = AccessibilityItem(
                    appName: app.name, bundleID: app.bundleID, pid: app.pid,
                    description: description, identifier: identifier, frame: frame
                )
                Log.items.debug("AX host=\(app.bundleID ?? app.name, privacy: .private) identifier=\(identifier ?? "<none>", privacy: .private) description=\(description ?? "<none>", privacy: .private) frame=\(String(describing: frame), privacy: .private) stableDetail=\(item.detail ?? "<unidentified>", privacy: .private)")
                result.append((
                    item,
                    child
                ))
                resolvedCount += 1
            }
        }
        return result
    }

    /// Nil means no action was dispatched. A timeout is an uncertain result, not confirmed success;
    /// callers must not retry a dispatched press because that can close a menu which did open.
    nonisolated static func pressResult(
        itemAt frame: CGRect, in scan: MenuBarScan, reader: AccessibilityReader = AccessibilityReader()
    ) -> AXError? {
        guard let index = scan.elementIndex(itemAt: frame) else { return nil }
        let target = scan.elements[index].element
        let error = reader.setTimeout(target, 2)
        guard error == .success else { return error }
        return reader.press(target)
    }

    // MARK: - Attribute helpers

    /// An attribute that is absent (`noValue`, unsupported, or empty) is different from a read that failed.
    private enum AttributeRead {
        case value(CFTypeRef)
        case absent
        case failed

        var value: CFTypeRef? {
            if case .value(let value) = self { return value }
            return nil
        }
    }

    nonisolated private static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    nonisolated private static func point(_ ref: CFTypeRef?) -> CGPoint? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &p) ? p : nil
    }

    nonisolated private static func size(_ ref: CFTypeRef?) -> CGSize? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &s) ? s : nil
    }
}
