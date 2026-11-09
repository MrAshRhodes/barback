import AppKit
import BarbackCore
import Combine

@MainActor
final class ProfileCoordinator {
    private let model: AppModel
    private let contextProvider: @MainActor () -> ProfileContext
    private let applyVisibility: (ProfileVisibility) -> Void
    private let observeSystem: Bool
    private var observers: Set<AnyCancellable> = []
    private var context: ProfileContext?
    private var applying = false
    private var started = false

    init(
        model: AppModel, observeSystem: Bool = true,
        context: @escaping @MainActor () -> ProfileContext = ProfileCoordinator.currentContext,
        applyVisibility: @escaping (ProfileVisibility) -> Void
    ) {
        self.model = model
        self.observeSystem = observeSystem
        self.contextProvider = context
        self.applyVisibility = applyVisibility
    }

    func start() {
        guard !started, !model.settings.profiles.isEmpty else { return }
        started = true
        context = contextProvider()
        if observeSystem {
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.contextChanged() }
                .store(in: &observers)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] notification in
                    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
                    self?.contextChanged()
                }
                .store(in: &observers)
        }
        if model.activeProfile != nil {
            applyCurrent()
        } else if let context, let match = VisibilityProfiles.match(in: model.settings.profiles, context: context) {
            select(match)
        }
        // With no saved or matching profile, the current sections stay as they are.
    }

    func stop() {
        observers.removeAll()
        started = false
        context = nil
    }

    func select(_ id: UUID?) {
        guard id == nil || model.settings.profiles.contains(where: { $0.id == id }) else {
            Log.app.error("Cannot select a profile that no longer exists")
            return
        }
        let changed = model.settings.activeProfileID != id
        applying = true
        model.settings.activeProfileID = id
        applying = false
        // Choosing the base configuration again leaves the current sections alone.
        if changed || id != nil { applyCurrent() }
    }

    func contextChanged() {
        guard started else { return }
        let next = contextProvider()
        guard next != context else { return }
        context = next
        let match = VisibilityProfiles.match(in: model.settings.profiles, context: next)
        // Staying on the same profile keeps any sections the user has changed since.
        guard match != model.settings.activeProfileID else { return }
        select(match)
    }

    func settingsDidChange(from old: BarbackSettings, to new: BarbackSettings) {
        guard !applying else { return }
        if new.profiles.isEmpty {
            stop()
            if old.activeProfileID != nil { applyVisibility(new.baseVisibility) }
            return
        }
        if !started { start(); return }
        // Renaming or editing rules must not re-apply sections the user changed since.
        if old.activeProfileID != new.activeProfileID || Self.target(old) != Self.target(new) {
            applyCurrent()
        }
    }

    private func applyCurrent() {
        guard !model.settings.profiles.isEmpty else { return }
        applyVisibility(Self.target(model.settings))
    }

    private static func target(_ settings: BarbackSettings) -> ProfileVisibility {
        settings.profiles.first { $0.id == settings.activeProfileID }?.visibility ?? settings.baseVisibility
    }

    static func currentContext() -> ProfileContext {
        let ids = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let builtIn = ids.filter { CGDisplayIsBuiltin($0) != 0 }.count
        return ProfileContext(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            builtInDisplayCount: builtIn, externalDisplayCount: ids.count - builtIn, displayIDs: ids
        )
    }
}
