import SwiftUI
import BarbackCore

/// A deliberately unranked ledger: interaction counts are evidence, not an importance score.
struct UsageReviewView: View {
    @ObservedObject var review: UsageReviewModel
    @ObservedObject var items: ItemsModel
    @StateObject private var presentation = UsageReviewPresentation()

    var body: some View {
        let snapshot = review.snapshot
        let candidates = items.panelCandidates
        let currentKeys = Set(candidates.map(\.key))
        let recordedKeys = Set(snapshot.entries.map(\.key))
        let unrecorded = candidates.filter { !recordedKeys.contains($0.key) }
        let unidentified = items.unidentifiedPanelItemCount

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(snapshot)
                controls(snapshot)
                if let error = review.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityLabel(String(localized: "Review storage error: \(error)"))
                }
                period(snapshot)
                Divider()
                if snapshot.entries.isEmpty {
                    emptyState(snapshot)
                } else {
                    ForEach(snapshot.entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { entry in
                        entryRow(entry, currentKeys: currentKeys)
                        Divider()
                    }
                }
                ForEach(unrecorded.sorted { $0.panelTitle.localizedStandardCompare($1.panelTitle) == .orderedAscending }) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.panelTitle).font(.headline)
                        Text("Recorded openings, width and context: unavailable for this item in the recorded period.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
                if unidentified > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Identity unavailable", systemImage: "questionmark.circle")
                            .font(.headline)
                        Text("\(unidentified) current item copies cannot be identified uniquely. Their counts are unavailable, not zero. They are excluded rather than merged or assigned another item's history.")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                caveats
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 660, minHeight: 420)
        .textSelection(.enabled)
        .onAppear { review.refreshRetention() }
        .confirmationDialog("Start a local review?", isPresented: $presentation.confirmingStart, titleVisibility: .visible) {
            Button("Start Recording") { review.startRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Record only confirmed successful item openings through Barback panels/search, shortcuts and item links. Counts are stored locally as daily totals for today and the previous 29 UTC dates, plus the latest on-demand width and display/foreground context. No click timeline, telemetry or background scanning. Direct clicks, failed or uncertain attempts, and background app activity are not counted. You can stop or clear at any time. Counts do not measure an item's importance.")
        }
        .alert("Clear all review data and stop recording?", isPresented: $presentation.confirmingClear) {
            Button("Clear and Stop", role: .destructive) { review.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes retained counts, measurements and recorded intervals. Only a cleared-state date remains. Settings and panel membership are unchanged; starting another period requires your consent.")
        }
    }

    private func header(_ snapshot: UsageReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Item Review")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Openings through Barback · Measured space")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label(snapshot.isEnabled ? "Recording through Barback" : "Recording is off",
                  systemImage: snapshot.isEnabled ? "record.circle" : "pause.circle")
                .font(.headline)
                .foregroundStyle(snapshot.isEnabled ? Color.accentColor : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func controls(_ snapshot: UsageReview) -> some View {
        HStack {
            if snapshot.isEnabled {
                Button("Stop Recording", systemImage: "stop.circle") { review.stopRecording() }
                    .accessibilityHint("Stops immediately and keeps retained review data.")
            } else {
                Button("Review and Enable…", systemImage: "record.circle") { presentation.confirmingStart = true }
                    .disabled(review.storageError != nil)
                    .accessibilityHint("Explains collection and asks for consent before recording.")
            }
            Button("Clear Review Data…", systemImage: "trash", role: .destructive) { presentation.confirmingClear = true }
                .accessibilityHint("Deletes retained review data and stops recording after confirmation.")
            Spacer()
            Button("Refresh Items", systemImage: "arrow.clockwise") { items.refresh() }
                .disabled(items.isRefreshing)
                .accessibilityHint("Uses the existing on-demand item scan; does not request new permissions.")
        }

    }

    private func period(_ snapshot: UsageReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Retention: today and the previous 29 UTC calendar dates.")
                .font(.subheadline.weight(.medium))
            Text("Only the intervals below were recorded. Gaps, app downtime and the part of a day before consent are not a complete month of observation. After an unclean exit, the previous interval ends at its last saved update.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let clearedAt = snapshot.lastClearedAt {
                Text("Review data cleared \(timestamp(clearedAt)). A new period starts only after consent.")
                    .font(.caption)
            }
            if let firstInterval = snapshot.intervals.first {
                Text("Retained recorded period begins \(timestamp(firstInterval.startedAt)).")
                    .font(.subheadline.monospacedDigit())
                DisclosureGroup("Recorded intervals (\(snapshot.intervals.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(snapshot.intervals.enumerated()), id: \.offset) { _, interval in
                            Text("\(timestamp(interval.startedAt)) → \(interval.endedAt.map(timestamp) ?? String(localized: "now (recording)"))")
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                Text("Interval and measurement timestamps use your local time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No recorded interval is available.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func emptyState(_ snapshot: UsageReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.lastClearedAt != nil && snapshot.intervals.isEmpty
                 ? "Review data was cleared." : "No retained item data.")
                .font(.headline)
            Text(snapshot.isEnabled
                 ? "Open an item through Barback or refresh Items to take an on-demand measurement. Empty data is not evidence that items are unused."
                 : "Collection is off by default. Review the privacy explanation before starting; no earlier openings can be reconstructed.")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func entryRow(_ entry: UsageReviewEntry, currentKeys: Set<ItemKey>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).font(.headline)
                Spacer()
                Text(entry.openings.formatted())
                    .font(.title3.monospacedDigit().weight(.medium))
                    .accessibilityLabel(String(localized: "\(entry.openings) confirmed openings through Barback during the recorded intervals"))
            }
            Text(entry.openings == 0
                 ? "No recorded openings through Barback during the recorded intervals."
                 : String(localized: "Opened through Barback \(entry.openings) times during the recorded intervals."))
                .font(.subheadline)
            Text([entry.key.owner, entry.key.detail].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let measurement = entry.measurement {
                Text("Last measured width: \(measurement.widthPoints.formatted(.number.precision(.fractionLength(0...1)))) pt.")
                    .font(.subheadline.weight(.medium))
                Text("Measured \(timestamp(measurement.observedAt)) · Display: \(measurement.displayName ?? String(localized: "unavailable")) · Foreground: \(measurement.foregroundApp ?? String(localized: "unavailable"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if items.snapshotContextIsStale || items.scanError != nil || items.lastRefreshed != measurement.observedAt {
                    Label("Historical measurement; the current layout or foreground context may differ.", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Measured width and context: unavailable.")
                    .foregroundStyle(.secondary)
            }
            if !currentKeys.contains(entry.key) {
                Text("Not safely identified in the current snapshot. This retained history has not been reassigned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var caveats: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Frequency is not importance", systemImage: "info.circle")
                .font(.headline)
            Text("VPN, battery, sync and other status-only indicators can be important with zero recorded openings. Direct menu-bar clicks and background activity are outside this review. Searching, selecting, revealing, previews and unsuccessful or uncertain attempts are not openings.")
            Text("Widths are in points from one latest identified display copy, not a live measurement; other displays can differ. Nothing is ranked, hidden, moved or removed from panels. Review data stays on this Mac, is excluded from settings exports, and is pruned when loaded, read or saved. No review-specific timers, activity observers or permission prompts are installed.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private final class UsageReviewPresentation: ObservableObject {
    @Published var confirmingStart = false
    @Published var confirmingClear = false
}
