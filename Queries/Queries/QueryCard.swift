import SwiftUI
import Charts
import AppKit

struct QueryCard: View {
    let query: SavedQuery
    let state: CardState
    let window: QueryWindow
    let datasource: String
    let run: () -> Void
    let edit: () -> Void
    let duplicate: () -> Void
    let up: () -> Void
    let down: () -> Void
    let delete: () -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(query.title).font(.title3.weight(.semibold)).lineLimit(1)
                            Text("\(query.language.rawValue) · \(datasource)")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse query results" : "Expand query results")
                .accessibilityLabel(query.title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide query results")
                Spacer()
                if !isExpanded, let error = state.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).help(error)
                        .accessibilityLabel("Query error: \(error)")
                }
                if state.loading { ProgressView().controlSize(.small) }
                if state.stale { Label("Stale", systemImage: "clock.badge.exclamationmark").font(.callout.weight(.medium)).foregroundStyle(.orange).padding(.horizontal, 8).padding(.vertical, 3).background(.orange.opacity(0.12), in: Capsule()) }
                Button(action: run) { Label("Run", systemImage: "play.fill").labelStyle(.iconOnly) }.disabled(state.loading).help("Run query")
                Button(action: edit) { Label("Edit", systemImage: "pencil").labelStyle(.iconOnly) }.help("Edit query")
                Menu {
                    Button("Copy Query", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(query.text, forType: .string)
                    }
                    Divider()
                    Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
                    Button("Move Up", systemImage: "arrow.up", action: up); Button("Move Down", systemImage: "arrow.down", action: down)
                    Divider(); Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Query actions").help("Copy, duplicate, reorder, or delete query")
            }.buttonStyle(.borderless).labelStyle(.titleAndIcon).controlSize(.large)
            if isExpanded {
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if let result = state.result {
                    if result.isEmpty { ContentUnavailableView("No results", systemImage: "tray", description: Text("The query returned no valid samples in this time range.")).frame(maxWidth: .infinity).frame(height: 180) }
                    else if query.kind == .logs { LogResults(entries: result.logs).frame(height: 300) }
                    else { MetricChart(series: result.series, window: window, step: result.window.step, unit: query.unit).frame(height: 260) }
                    ForEach(result.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                    if query.kind == .logs { Text("Limit: 1,000 entries\(result.possiblyTruncated ? " · Limit reached. More entries may exist." : "")").font(.callout).foregroundStyle(result.possiblyTruncated ? .orange : .secondary) }
                } else {
                    ContentUnavailableView(state.loading ? "Running query…" : "Ready to run", systemImage: "chart.xyaxis.line", description: Text("Use Run or Refresh All to fetch results.")).frame(maxWidth: .infinity).frame(height: 180)
                }
                if let last = state.lastSuccess {
                    Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}
struct MetricChart: View {
    let series: [TimeSeries]
    let window: QueryWindow
    let step: Int
    let unit: String
    @State private var selectedDate: Date?
    private func color(_ id: String) -> Color {
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo, .red, .mint]
        return palette[Int(hash % UInt64(palette.count))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(series) { line in
                    ForEach(line.validSamples) { sample in
                        LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.value!), series: .value("Series", line.id))
                            .interpolationMethod(.monotone).foregroundStyle(color(line.id)).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        if line.validSamples.count == 1 { PointMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.value!)).foregroundStyle(color(line.id)) }
                    }
                }
                if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            }
            .chartXScale(domain: window.start...max(window.end, window.start.addingTimeInterval(1)))
            .chartYAxisLabel(unit)
            .chartYAxis { AxisMarks { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(.quaternary); AxisValueLabel().font(.callout).foregroundStyle(.secondary) } }
            .chartXAxis { AxisMarks { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary.opacity(0.5)); AxisValueLabel(format: .dateTime.hour().minute()).font(.callout).foregroundStyle(.secondary) } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let frame = proxy.plotFrame { selectedDate = proxy.value(atX: location.x - geometry[frame].origin.x) }
                        case .ended: selectedDate = nil
                        }
                    }
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(series) { line in
                        HStack(spacing: 5) {
                            Circle().fill(color(line.id)).frame(width: 8, height: 8)
                            Text(line.label.isEmpty ? "Value" : line.label).lineLimit(1)
                        }.help(line.label)
                    }
                }.font(.callout).foregroundStyle(.secondary)
            }
            if let selectedDate {
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(series) { line in
                            if let sample = line.validSamples.min(by: { abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate)) }) {
                                Text("\(line.label.isEmpty ? "Value" : line.label): \(sample.value!.formatted()) \(unit) at \(sample.timestamp.formatted(date: .omitted, time: .standard))\(line.isBridged(at: selectedDate, step: step) ? " · Cursor is over a bridged missing interval" : "")")
                            }
                        }
                    }.font(.callout).textSelection(.enabled)
                }.frame(minHeight: 22)
            } else { Text("Smoothed curve · Missing intervals connected · Hover for recorded samples").font(.callout).foregroundStyle(.secondary).frame(minHeight: 22) }
        }
        .accessibilityLabel("Smoothed time series chart. Missing samples are connected. \(series.count) series.")
    }
}
struct LogResults: View {
    let entries: [LogEntry]
    private func tint(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("level=err") { return .red }
        if lower.contains("warn") { return .orange }
        return .primary
    }
    @State private var expanded: Set<String> = []
    var body: some View {
        List(entries) { entry in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Button { if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) } } label: { Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right") }.buttonStyle(.plain).accessibilityLabel(expanded.contains(entry.id) ? "Collapse log details" : "Expand log details").help(expanded.contains(entry.id) ? "Collapse log details" : "Show full message and labels")
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text(entry.text).foregroundStyle(tint(entry.text)).lineLimit(expanded.contains(entry.id) ? nil : 2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                if expanded.contains(entry.id) {
                    Text("Timestamp (ns): \(entry.sourceTimestamp)\n" + entry.labels.keys.sorted().map { "\($0)=\(entry.labels[$0]!)" }.joined(separator: "\n")).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.font(.system(.body, design: .monospaced)).padding(.vertical, 3)
        }.listStyle(.plain)
    }
}
