import AppKit
import BarbackCore

// `--version` prints and exits before any UI starts (used by packaging/CI smoke checks).
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--version") || arguments.contains("-v") {
    print("\(BarbackInfo.name) \(BarbackInfo.version(from: Bundle.main.infoDictionary))")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // LSUIElement is set in Info.plist for the bundled app; this also covers running the bare executable.
    app.setActivationPolicy(.accessory)
    app.run()
}
