import BarbackCore
import os

enum Log {
    static let app = Logger(subsystem: BarbackInfo.logSubsystem, category: "app")
    static let statusBar = Logger(subsystem: BarbackInfo.logSubsystem, category: "statusbar")
    static let hotkey = Logger(subsystem: BarbackInfo.logSubsystem, category: "hotkey")
    static let hover = Logger(subsystem: BarbackInfo.logSubsystem, category: "hover")
    static let items = Logger(subsystem: BarbackInfo.logSubsystem, category: "items")
    /// Points of Interest in Instruments: wraps show/hide and the on-demand Items scan.
    static let signposter = OSSignposter(subsystem: BarbackInfo.logSubsystem, category: .pointsOfInterest)
}
