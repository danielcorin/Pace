import AppKit
import Charts
import PaceCore
import SwiftUI

/// The Stats settings tab: clipboard pastes and snippet expansions over time,
/// drawn as two small-multiple bar charts. Each metric gets its own chart and
/// y-scale because expansions are typically far rarer than pastes; hovering
/// either chart reads out the same bucket in both.
struct UsageStatsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("usageStatsPeriod") private var periodRawValue = UsagePeriod.last30Days.rawValue
    @State private var report: UsageReport?
    @State private var loadError: String?
    @State private var hoveredBucketID: String?

    private var period: UsagePeriod {
        UsagePeriod(rawValue: periodRawValue) ?? .last30Days
    }

    var body: some View {
        Group {
            if model.vaultState != .unlocked {
                lockedState
            } else {
                Form {
                    if let report {
                        Section {
                            metricRow(.clipboardPaste, report: report)
                        } header: {
                            periodPicker
                        }
                        Section {
                            metricRow(.snippetExpansion, report: report)
                        }
                    } else if let loadError {
                        Section {
                            Text(loadError)
                                .foregroundStyle(.secondary)
                        } header: {
                            periodPicker
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .task(id: ReloadKey(period: period, revision: model.usageRevision, state: model.vaultState)) {
            await load()
        }
    }

    private struct ReloadKey: Equatable {
        var period: UsagePeriod
        var revision: Int
        var state: VaultState
    }

    private func load() async {
        guard model.vaultState == .unlocked else {
            report = nil
            return
        }
        do {
            let loaded = try await model.usageReport(for: period)
            if report?.period != loaded.period { hoveredBucketID = nil }
            report = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var lockedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Unlock Pace to view usage stats")
                .font(.headline)
            Text("Stats are encrypted with the rest of your history.")
                .foregroundStyle(.secondary)
            Button("Unlock") { Task { await model.unlock() } }
                .disabled(model.vaultState == .unlocking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var periodPicker: some View {
        Picker("Period", selection: $periodRawValue) {
            ForEach(UsagePeriod.allCases, id: \.rawValue) { period in
                Text(period.shortTitle).tag(period.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.bottom, 4)
    }

    // MARK: - Metric

    private func metricRow(_ event: UsageEvent, report: UsageReport) -> some View {
        let hovered = report.buckets.first { $0.id == hoveredBucketID }
        let value = hovered.map { $0.counts[event] } ?? report.total[event]
        let caption = hovered.map { bucketTitle($0, granularity: report.granularity) }
            ?? "\(report.period.title) · \(report.allTime[event].formatted()) all time"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.headline)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text(value.formatted())
                    .font(.system(size: 26, weight: .semibold))
            }
            chart(event, report: report)
                .frame(height: 84)
        }
    }

    private func chart(_ event: UsageEvent, report: UsageReport) -> some View {
        let unit = report.granularity.calendarComponent
        let color = event.seriesColor
        let isEmpty = report.buckets.allSatisfy { $0.counts[event] == 0 }

        return Chart(report.buckets) { bucket in
            BarMark(
                x: .value("Date", bucket.startDate, unit: unit),
                y: .value(event.title, bucket.counts[event]),
                width: .ratio(0.78)
            )
            .foregroundStyle(color)
            .cornerRadius(2)
            .opacity(hoveredBucketID == nil || hoveredBucketID == bucket.id ? 1 : 0.4)
            .accessibilityLabel(bucketTitle(bucket, granularity: report.granularity))
            .accessibilityValue("\(bucket.counts[event]) \(event.unitNoun(bucket.counts[event]))")
        }
        .chartYScale(domain: 0...max(isEmpty ? 4 : 1, report.buckets.map { $0.counts[event] }.max() ?? 0))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel()
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisValues(for: report)) { _ in
                AxisValueLabel(format: xAxisFormat(for: report), centered: true)
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                            hoveredBucketID = proxy.value(atX: x, as: Date.self)
                                .flatMap { bucketID(containing: $0, report: report) }
                        case .ended:
                            hoveredBucketID = nil
                        }
                    }
            }
        }
        .overlay {
            if isEmpty, hoveredBucketID == nil {
                Text(report.allTime[event] == 0
                    ? "No \(event.unitNoun(0)) yet"
                    : "No \(event.unitNoun(0)) in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bucketID(containing date: Date, report: UsageReport) -> String? {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: report.granularity.calendarComponent, for: date)?.start else {
            return nil
        }
        let key = UsageDayKey.key(for: start, calendar: calendar)
        return report.buckets.contains { $0.id == key } ? key : nil
    }

    private func xAxisValues(for report: UsageReport) -> AxisMarkValues {
        switch report.period {
        case .last7Days: .stride(by: .day)
        case .last30Days: .stride(by: .day, count: 7)
        case .last90Days: .stride(by: .weekOfYear, count: 3)
        case .last12Months: .stride(by: .month, count: 2)
        }
    }

    private func xAxisFormat(for report: UsageReport) -> Date.FormatStyle {
        switch report.period {
        case .last7Days: .dateTime.weekday(.abbreviated)
        case .last30Days, .last90Days: .dateTime.month(.abbreviated).day()
        case .last12Months: .dateTime.month(.abbreviated)
        }
    }

    private func bucketTitle(_ bucket: UsageBucket, granularity: UsageGranularity) -> String {
        let date = bucket.startDate
        switch granularity {
        case .day:
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week:
            return "Week of \(date.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        }
    }
}

private extension UsagePeriod {
    var shortTitle: String {
        switch self {
        case .last7Days: "7 Days"
        case .last30Days: "30 Days"
        case .last90Days: "90 Days"
        case .last12Months: "12 Months"
        }
    }
}

private extension UsageBucket {
    var startDate: Date {
        UsageDayKey.date(from: date) ?? .distantPast
    }
}

private extension UsageEvent {
    var title: String {
        switch self {
        case .clipboardPaste: "Clipboard pastes"
        case .snippetExpansion: "Snippet expansions"
        }
    }

    func unitNoun(_ count: Int) -> String {
        switch self {
        case .clipboardPaste: count == 1 ? "paste" : "pastes"
        case .snippetExpansion: count == 1 ? "expansion" : "expansions"
        }
    }

    /// Categorical slots 1 and 2, stepped separately for light and dark
    /// surfaces (validated for contrast and color-vision separation).
    var seriesColor: Color {
        switch self {
        case .clipboardPaste: Color(light: 0x2A78D6, dark: 0x3987E5)
        case .snippetExpansion: Color(light: 0xEB6834, dark: 0xD95926)
        }
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        })
    }
}
