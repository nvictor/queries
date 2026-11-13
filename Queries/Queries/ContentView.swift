import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = StackViewModel()
    @State private var editing: SavedQuery?
    @State private var deleting: SavedQuery?
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            if model.customRange {
                HStack {
                    DatePicker("From", selection: $model.customStart)
                    DatePicker("To", selection: $model.customEnd)
                    Button("Apply Range") { model.rangeChanged() }
                }.padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            }
            if model.collection.queries.isEmpty {
                ContentUnavailableView {
                    Label("Your queries, together", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Save a PromQL or LogQL query to start your stack.")
                } actions: {
                    Button("Add Query") { editing = SavedQuery() }.buttonStyle(.borderedProminent)
                    Button("Add Local Examples") { model.addLocalExamples() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(model.collection.queries) { query in
                            QueryCard(query: query, state: model.states[query.id] ?? CardState(), window: model.window,
                                      datasource: model.datasources.first { $0.uid == query.datasourceUID }?.name ?? query.datasourceUID,
                                      run: { model.run(query) }, edit: { editing = query }, duplicate: { model.duplicate(query) },
                                      up: { model.move(query, by: -1) }, down: { model.move(query, by: 1) }, delete: { deleting = query })
                        }
                    }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
                }.background(Color(nsColor: .windowBackgroundColor).opacity(0.6)).scrollContentBackground(.hidden)
            }
            Divider()
            HStack(spacing: 8) {
                if model.runningCount > 0 { ProgressView().controlSize(.mini) }
                Text(model.runningCount > 0 ? "Refreshing \(model.runningCount) \(model.runningCount == 1 ? "query" : "queries")…" : "\(model.collection.queries.count) saved \(model.collection.queries.count == 1 ? "query" : "queries")")
                Spacer()
                if model.collection.refreshSeconds > 0 { Label("Auto-refresh \(model.nextRefresh == nil ? "paused" : "on")", systemImage: model.nextRefresh == nil ? "pause.circle" : "arrow.triangle.2.circlepath") }
                Text("\(model.window.start.formatted(date: .omitted, time: .standard)) – \(model.window.end.formatted(date: .omitted, time: .standard))").monospacedDigit()
            }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
        }
        .frame(minWidth: 680, minHeight: 360)
        .navigationTitle("Queries")
        .toolbar {
            ToolbarItemGroup {
                Button { editing = SavedQuery() } label: { Label("Add Query", systemImage: "plus") }.keyboardShortcut("n").help("Add a saved query (⌘N)")
                Picker("Time Range", selection: rangeBinding) {
                    Text("15m").tag(900.0); Text("1h").tag(3600.0); Text("6h").tag(21600.0); Text("24h").tag(86400.0); Text("Custom…").tag(-1.0)
                }.frame(width: 125).help("Choose the time range for all queries")
                Button { model.refreshAll() } label: { Label("Refresh All", systemImage: "arrow.clockwise") }.keyboardShortcut("r").help("Refresh all queries (⌘R)")
                Picker("Auto-refresh", selection: $model.collection.refreshSeconds) {
                    Text("Auto: Off").tag(0); Text("30s").tag(30); Text("1m").tag(60); Text("5m").tag(300)
                }.frame(width: 130).help("Choose how often all queries refresh automatically").onChange(of: model.collection.refreshSeconds) { model.persist(); model.scheduleNext() }
                Menu {
                    Button("Import Collection…") { model.importCollection() }
                    Button("Export Collection…") { model.exportCollection() }
                } label: { Label("Collection", systemImage: "folder") }.help("Import or export a query collection")
                Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }.keyboardShortcut(",").help("Configure gcx and your connection (⌘,)")
            }
        }
        .sheet(isPresented: $model.showSettings) { SetupView(model: model) }
        .sheet(item: $editing) { query in QueryEditor(query: query, datasources: model.datasources) { model.save($0) } }
        .alert("Queries", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete \(deleting?.title ?? "query")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
        }
        .onReceive(clock) { _ in model.tick() }
        .onChange(of: scenePhase) { model.activityChanged(scenePhase == .active) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.activityChanged(false) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.activityChanged(NSApp.isActive) }
        .task { await model.testConnection(); model.scheduleNext() }
    }
    private var rangeBinding: Binding<Double> { Binding(get: { model.customRange ? -1 : model.collection.rangeSeconds }, set: { value in model.customRange = value == -1; if value > 0 { model.collection.rangeSeconds = value }; model.rangeChanged() }) }
}

struct SetupView: View {
    @ObservedObject var model: StackViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Connect gcx", systemImage: "terminal").font(.title2.bold())
            Text("Queries reuses your gcx authentication. Credentials stay in gcx.").foregroundStyle(.secondary)
            HStack {
                TextField("Absolute gcx executable path", text: $model.executablePath).onChange(of: model.executablePath) { model.settingsChanged() }
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { model.executablePath = url.path }
                }
            }
            Text(model.version).font(.callout).textSelection(.enabled)
            HStack {
                TextField("Authenticated context", text: $model.collection.context).onChange(of: model.collection.context) { model.settingsChanged() }
                Menu("Contexts") { ForEach(model.contexts, id: \.self) { context in Button(context) { model.collection.context = context } } }
            }
            Text("Install and authenticate in Terminal:").font(.headline)
            HStack {
                Text("brew install gcx\ngcx login CONTEXT_NAME").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install gcx\ngcx login CONTEXT_NAME", forType: .string) }
            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text(model.setupStatus).textSelection(.enabled)
            if !model.datasources.isEmpty { ForEach(model.datasources) { source in Text("\(source.name) · \(source.type)").font(.callout).foregroundStyle(.secondary) } }
            HStack {
                Button("Retry / Test Connection") { Task { await model.testConnection() } }.disabled(model.setupBusy)
                if model.setupBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 600)
    }
}
struct QueryEditor: View {
    @State var query: SavedQuery
    let datasources: [Datasource]
    let save: (SavedQuery) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Edit Query", systemImage: "square.and.pencil").font(.title2.bold())
            TextField("Title", text: $query.title)
            HStack {
                Picker("Language", selection: $query.language) { ForEach(QueryLanguage.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .onChange(of: query.language) { if query.language == .promQL { query.kind = .metrics } }
                Picker("Result", selection: $query.kind) { ForEach(ResultKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.disabled(query.language == .promQL)
            }
            HStack {
                TextField("Data source UID", text: $query.datasourceUID)
                Menu("Data Sources") {
                    ForEach(datasources.filter { $0.type == (query.language == .promQL ? "prometheus" : "loki") }) { source in Button(source.name) { query.datasourceUID = source.uid } }
                }
            }
            Text("Expression").font(.headline)
            TextEditor(text: $query.text).font(.system(.body, design: .monospaced)).frame(minHeight: 200).scrollContentBackground(.hidden).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            TextField("Unit (optional, display label)", text: $query.unit)
            Text("Notes (optional)").font(.headline)
            TextEditor(text: $query.notes)
                .font(.body).frame(height: 80).scrollContentBackground(.hidden)
                .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Query notes")
                .help("Add context, expected values, or tips for interpreting results")
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
            HStack {
                Text("Runs only when requested or on auto-refresh.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { do { try query.validate(); save(query); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 680)
    }
}
