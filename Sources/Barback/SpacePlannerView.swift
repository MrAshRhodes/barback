import SwiftUI
import BarbackCore

/// A local what-if preview. The only model operation here is the user's explicit refresh.
struct SpacePlannerView: View {
    @ObservedObject var items: ItemsModel
    @StateObject private var state = SpacePlannerPreviewState()

    private var snapshot: SpacePlanner.Snapshot {
        SpacePlanner.snapshot(
            observations: items.rows.filter { $0.barbackRole == nil }.map { .init(item: $0.item) },
            displays: items.snapshotDisplays
        )
    }

    var body: some View {
        let snapshot = snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                context
                status(snapshot)

                ForEach(snapshot.displays) { display in
                    displaySection(display, snapshot: snapshot)
                }

                let unplaced = snapshot.rankedMeasurements(on: nil)
                if !unplaced.isEmpty {
                    GroupBox("Display unavailable or ambiguous") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("These widths are listed, but are not assigned to a display or added to any region’s preview.")
                                .foregroundStyle(.secondary)
                            measurementList(unplaced)
                        }
                        .padding(8)
                    }
                }
                limits
            }
            .padding(24)
        }
        .frame(minWidth: 580, idealWidth: 700, minHeight: 480, idealHeight: 640)
        .onChange(of: items.lastRefreshed) { _, _ in state.preview.reset() }
        .onChange(of: items.rows) { _, _ in state.preview.reset() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Space Planner")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("A measured snapshot, not an arrangement tool. Exclude items below to explore a hypothetical visible set.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    items.refresh()
                } label: {
                    Label("Refresh snapshot", systemImage: "arrow.clockwise")
                }
                .disabled(items.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Take a new on-demand snapshot. Successful refresh resets this preview.")
                Button("Reset preview") { state.preview.reset() }
                    .disabled(state.preview.excludedIDs.isEmpty)
                    .help("Include every measured item again. No settings or real items change.")
                Spacer()
                Text("LOGICAL POINTS")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("All measurements are in logical points, not pixels")
            }
        }
    }

    private var context: some View {
        GroupBox("Snapshot context") {
            VStack(alignment: .leading, spacing: 7) {
                if let date = items.lastRefreshed {
                    LabeledContent("Captured") {
                        Text(date.formatted(date: .abbreviated, time: .standard))
                    }
                } else {
                    LabeledContent("Captured", value: "Not yet captured")
                }
                LabeledContent("Foreground app", value: items.snapshotFrontmostApp ?? "Unavailable")
                if let bundleID = items.snapshotFrontmostBundleID {
                    LabeledContent("App identifier", value: bundleID)
                }
                LabeledContent("Observed displays", value: "\(items.snapshotDisplays.count)")
                Text("Frames use global CoreGraphics coordinates converted from AppKit screen coordinates. Each diagram uses points from that display’s left edge; no pixel scaling is applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func status(_ snapshot: SpacePlanner.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.isRefreshing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(items.lastRefreshed == nil ? "Taking a snapshot…" : "Refreshing… Previous snapshot remains below.")
                }
                .accessibilityElement(children: .combine)
            }
            if let error = items.scanError {
                Label("Snapshot refresh failed", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error)
                    .textSelection(.enabled)
                Text(items.lastRefreshed == nil
                     ? "No successful snapshot is available. Try Refresh snapshot."
                     : "The last successful snapshot is preserved, not evidence that any item disappeared. Try Refresh snapshot.")
            }
            if items.snapshotContextIsStale {
                Label("Stale snapshot — context changed", systemImage: "clock.badge.exclamationmark")
                    .font(.headline)
                Text("The display, foreground app, or known layout differs from this capture. Refresh before relying on its measurements.")
            }
            if items.lastRefreshed == nil, snapshot.measurements.isEmpty, items.scanError == nil, !items.isRefreshing {
                Label("No snapshot yet. Choose Refresh snapshot to begin.", systemImage: "ruler")
            } else if snapshot.measurements.isEmpty, items.scanError == nil, !items.isRefreshing {
                Label("No external status items were observed.", systemImage: "rectangle.dashed")
                Text("An empty scan does not prove that the menu bar is empty or that its width is available.")
            }
            if !snapshot.measurements.isEmpty, snapshot.hasPartialData {
                Label("Partial estimate", systemImage: "info.circle")
                    .font(.headline)
                Text("Application-menu boundaries are not measured by this scan, so usable capacity and new free space remain unknown. Unidentified items can still have measurable widths; unavailable or ambiguous frames stay outside the preview.")
            }
            if !items.accessibilityTrusted {
                Text("Accessibility access is not enabled. Basic width measurements still work; some identities may be unavailable. This planner does not request permission.")
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func displaySection(_ display: SpacePlanner.Display, snapshot: SpacePlanner.Snapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                if display.geometryAvailable {
                    Text("Origin: \(points(display.frame.minX)), \(points(display.frame.minY)) · Display width: \(points(display.frame.width)) logical points — not status-item capacity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let notch = display.notch {
                        Text("Camera housing: \(points(notch.lowerBound))–\(points(notch.upperBound)) points from the left. The regions below are disconnected and are never combined.")
                            .font(.callout)
                    }
                    ForEach(display.regions) { region in
                        regionSection(region, display: display, snapshot: snapshot)
                    }
                    if display.regions.isEmpty {
                        Text("No unobscured region can be measured on this display.")
                    }
                } else {
                    Label("Display or camera-housing geometry is unavailable. No capacity is inferred.", systemImage: "exclamationmark.triangle")
                }

                Divider()
                Text("Largest observed widths")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Ranked within this display. Checked means excluded only from the hypothetical preview. Unplaced widths are not part of the before/after totals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let measurements = snapshot.rankedMeasurements(on: display.id)
                if measurements.isEmpty {
                    Text("No items could be assigned to this display.")
                        .foregroundStyle(.secondary)
                } else {
                    measurementList(measurements)
                }
            }
            .padding(8)
            .fixedSize(horizontal: false, vertical: true)
        } label: {
            Text(displayName(display.id))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func regionSection(
        _ region: SpacePlanner.Region, display: SpacePlanner.Display, snapshot: SpacePlanner.Snapshot
    ) -> some View {
        let comparison = snapshot.comparison(in: region, preview: state.preview)
        let measurements = snapshot.measurements.filter { region.measurementIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(regionName(region, display: display))
                .font(.subheadline.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Notch-safe span: \(points(region.safeInterval.lowerBound))–\(points(region.safeInterval.upperBound)) (\(points(region.safeInterval.width)) logical points). Usable status-item capacity: unknown.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let observed = region.observedInterval {
                Text("Observed item span: \(points(observed.lowerBound))–\(points(observed.upperBound)) points. Blank areas are unmeasured, not promised free space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Before").font(.caption.bold())
            SpacePlannerDiagram(region: region, measurements: measurements, excludedIDs: [])
            Text("Before: \(comparison.beforeCount) items, \(points(comparison.beforeMeasuredWidth)) points of combined measured widths; \(points(comparison.beforeOccupiedWidth)) points of occupied footprint.")
                .font(.callout)

            Text("What-if").font(.caption.bold())
            SpacePlannerDiagram(region: region, measurements: measurements, excludedIDs: state.preview.excludedIDs)
            Text("What-if: \(comparison.afterCount) kept items, \(points(comparison.afterMeasuredWidth)) points of combined measured widths; \(points(comparison.afterOccupiedWidth)) points of occupied footprint. Excluded measured width: \(points(comparison.excludedMeasuredWidth)) points. New usable space: unknown.")
                .font(.callout)
            Text("Solid blocks remain at observed positions. Dashed outlines are hypothetical exclusions, not moved or hidden items. Overlapping frames count only once in the footprint.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func measurementList(_ measurements: [SpacePlanner.Measurement]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(measurements) { measurement in
                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { state.preview.excludedIDs.contains(measurement.id) },
                        set: { state.preview.setExcluded($0, measurement: measurement) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(itemName(measurement))
                            Text("Window \(measurement.observation.windowID) · \(placementDescription(measurement))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!measurement.canExclude)
                    .accessibilityLabel("Exclude \(itemName(measurement)), window \(measurement.observation.windowID), from the hypothetical preview")
                    .accessibilityHint(measurement.canExclude ? "Changes only this preview." : placementDescription(measurement))
                    Spacer(minLength: 8)
                    Text(measurement.width.map { "\(points($0)) pt" } ?? "Unavailable")
                        .font(.body.monospacedDigit())
                        .accessibilityLabel(measurement.width.map { "\(points($0)) logical points wide" } ?? "Width unavailable")
                }
            }
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What this can — and cannot — tell you")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Widths can change with clocks, text, menus, or app state. Unobserved live changes may invalidate this snapshot even when no stale warning appears. Refresh is on demand and has a processing cost; this view does not poll.")
            Text("A width reduction is not guaranteed free space. macOS controls placement, spacing and overflow. Barback hides contiguous sections; actual arrangement is still manual ⌘-drag. This preview does not move icons, hide or show anything, change panels, or save settings.")
            Text("Barback’s own layout controls are omitted, including expanded separators; their occupied space is not reclaimed. No Screen Recording, capture, synthetic dragging or network telemetry is used.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func displayName(_ index: Int) -> String {
        let name = items.snapshotDisplayNames.indices.contains(index) ? items.snapshotDisplayNames[index] : ""
        return name.isEmpty ? "Display \(index + 1)" : "\(name) · Display \(index + 1)"
    }

    private func itemName(_ measurement: SpacePlanner.Measurement) -> String {
        measurement.observation.name ?? String(localized: "Unidentified item")
    }

    private func regionName(_ region: SpacePlanner.Region, display: SpacePlanner.Display) -> String {
        guard let notch = display.notch else { return "Observed menu-bar region" }
        return region.safeInterval.upperBound <= notch.lowerBound ? "Left of camera housing" : "Right of camera housing"
    }

    private func placementDescription(_ measurement: SpacePlanner.Measurement) -> String {
        switch measurement.placement {
        case .measured: return "Measured in region \((measurement.regionIndex ?? 0) + 1)"
        case .unavailableFrame: return "Frame unavailable or invalid; not included"
        case .notOnScreen: return "Not drawn on screen; not included"
        case .unknownDisplay: return "No reliable display; not included"
        case .ambiguousDisplay: return "Ambiguous display ownership; not included"
        case .outsideMenuBar: return "Outside the observed menu-bar row; not included"
        case .crossesDisplayEdge: return "Frame crosses a display edge; not included"
        case .unavailableDisplayGeometry: return "Display geometry unavailable; not included"
        case .overlapsNotch: return "Overlaps camera housing; not included"
        case .overlapsApplicationMenus: return "Overlaps measured application menus; not included"
        }
    }
}

@MainActor
private final class SpacePlannerPreviewState: ObservableObject {
    @Published var preview = SpacePlanner.Preview()
}

private struct SpacePlannerDiagram: View {
    let region: SpacePlanner.Region
    let measurements: [SpacePlanner.Measurement]
    let excludedIDs: Set<Int>

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                ForEach(measurements) { measurement in
                    if let interval = measurement.localInterval {
                        let scale = geometry.size.width / max(1, region.safeInterval.width)
                        let excluded = excludedIDs.contains(measurement.id)
                        Rectangle()
                            .fill(excluded ? Color.clear : Color.accentColor)
                            .overlay {
                                Rectangle().strokeBorder(
                                    Color.primary.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 1, dash: excluded ? [3, 2] : [])
                                )
                            }
                            .frame(width: max(0, interval.width * scale))
                            .offset(x: (interval.lowerBound - region.safeInterval.lowerBound) * scale)
                    }
                }
            }
        }
        .frame(height: 24)
        .clipped()
        .accessibilityHidden(true)
    }
}

private func points(_ value: CGFloat) -> String {
    Double(value).formatted(.number.precision(.fractionLength(0...1)))
}
