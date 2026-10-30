import AppKit
import BarbackCore

/// Optional "show on hover": watches pointer movement (no permission needed) and fires when the pointer
/// dwells briefly in the status-item part of the menu bar, and again shortly after it leaves the menu bar.
/// Only installed while the setting is on; both timers are one-shot.
@MainActor
final class HoverMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var throttle = HoverThrottle()
    /// Trailing check for events dropped by the throttle, so the last position is never lost.
    private var trailingTimer: Timer?
    private var wasInZone = false
    private var wasInMenuBar = false
    private var dwellTimer: Timer?
    private var exitTimer: Timer?

    var onEnterZone: (() -> Void)?
    /// Fired `HoverPolicy.exitDelay` after the pointer leaves the menu bar (if it hasn't come back).
    var onExitMenuBar: (() -> Void)?

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        Log.hover.info("Hover monitor started")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancel(&dwellTimer)
        cancel(&exitTimer)
        cancel(&trailingTimer)
        throttle.reset()
        wasInZone = false
        wasInMenuBar = false
        Log.hover.info("Hover monitor stopped")
    }

    private func pointerMoved() {
        switch throttle.eventArrived(at: ProcessInfo.processInfo.systemUptime) {
        case .processNow:
            check(NSEvent.mouseLocation)
        case .scheduleTrailing(let delay):
            trailingTimer = oneShot(delay) { [weak self] in
                guard let self else { return }
                self.trailingTimer = nil
                self.throttle.trailingFired(at: ProcessInfo.processInfo.systemUptime)
                self.check(NSEvent.mouseLocation)
            }
        case .trailingPending:
            break
        }
    }

    private func check(_ location: CGPoint) {
        let inMenuBar = ScreenInfo.isMouseInMenuBar(location)
        if inMenuBar != wasInMenuBar {
            wasInMenuBar = inMenuBar
            cancel(&exitTimer)
            if !inMenuBar {
                exitTimer = oneShot(HoverPolicy.exitDelay) { [weak self] in
                    guard let self else { return }
                    self.exitTimer = nil
                    if !ScreenInfo.isMouseInMenuBar() { self.onExitMenuBar?() }
                }
            }
        }

        let inZone = inMenuBar && ScreenInfo.isInHoverZone(location)
        guard inZone != wasInZone else { return }
        wasInZone = inZone
        cancel(&dwellTimer)
        guard inZone else { return }
        dwellTimer = oneShot(HoverPolicy.dwell) { [weak self] in
            guard let self else { return }
            self.dwellTimer = nil
            if ScreenInfo.isInHoverZone(NSEvent.mouseLocation) { self.onEnterZone?() }
        }
    }

    private func oneShot(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func cancel(_ timer: inout Timer?) {
        timer?.invalidate()
        timer = nil
    }
}
