import Foundation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+), with status text matching System Settings wording.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusText: String {
        switch status {
        case .enabled:
            return String(localized: "Barback opens automatically when you log in.")
        case .requiresApproval:
            return String(localized: "Allow Barback in System Settings › General › Login Items & Extensions to finish turning this on.")
        case .notFound:
            return String(localized: "Unavailable. Move Barback to the Applications folder and open it from there.")
        case .notRegistered:
            return String(localized: "Barback doesn’t open automatically when you log in.")
        @unknown default:
            return String(localized: "Status unknown.")
        }
    }
}
