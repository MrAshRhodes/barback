import AppKit
import BarbackCore
import UniformTypeIdentifiers

/// Export… and Import… for Settings: local JSON files chosen with the standard panels; nothing leaves the Mac.
@MainActor
enum SettingsTransferController {
    static func exportSettings(model: AppModel, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Settings")
        panel.message = String(localized: "Barback saves your settings as a readable JSON file.")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SettingsTransfer.defaultFileName()
        run(panel, in: window) { url in
            do {
                let data = try SettingsTransfer.encode(model.settings, appVersion: model.version)
                try data.write(to: url, options: .atomic)
            } catch {
                showError(String(localized: "Couldn’t Export Settings"), error, in: window)
            }
        }
    }

    static func importSettings(model: AppModel, from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Settings")
        panel.message = String(localized: "Choose a Barback settings file. It replaces your current settings.")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        run(panel, in: window) { url in
            let imported: BarbackSettings
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > SettingsTransfer.maxFileSize { throw SettingsTransferError.fileTooLarge(bytes: size) }
                imported = try SettingsTransfer.decode(Data(contentsOf: url), current: model.settings)
            } catch {
                showError(String(localized: "Couldn’t Import Settings"), error, in: window)
                return
            }
            // One assignment: AppModel saves it and the controllers apply it, or nothing changes at all.
            model.settings = imported
        }
    }

    private static func run(_ panel: NSSavePanel, in window: NSWindow?, completion: @escaping (URL) -> Void) {
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private static func showError(_ title: String, _ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        let localized = error as? LocalizedError
        alert.informativeText = [localized?.errorDescription ?? error.localizedDescription, localized?.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: " ")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
