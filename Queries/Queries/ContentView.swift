import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct CollectionDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ContentView: View {
    @ObservedObject var model: StackViewModel
    @State private var deleting: SavedQuery?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            if model.customRange {
                ViewThatFits(in: .horizontal) {
                    HStack { rangeFields }
                    VStack(alignment: .leading) { rangeFields }
                }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
            if model.collection.queries.isEmpty {
                ContentUnavailableView {
                    Label("Your queries, together", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Save a PromQL or LogQL query to start your stack.")
                } actions: {
                    Button("Add Query") { model.editing = SavedQuery() }.buttonStyle(.borderedProminent)
                    Button("Add Local Examples") { model.addLocalExamples() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(model.collection.queries) { query in
                                QueryCard(query: query, state: model.states[query.id] ?? CardState(), window: model.window,
                                          datasource: model.datasources.first { $0.uid == query.datasourceUID }?.name ?? query.datasourceUID,
                                          isExpanded: Binding(get: { !model.collapsed.contains(query.id) },
                                                              set: { if $0 { model.collapsed.remove(query.id) } else { model.collapsed.insert(query.id) } }),
                                          run: { model.run(query) }, edit: { model.editing = query }, duplicate: { model.duplicate(query) },
                                          up: { model.move(query, by: -1) }, down: { model.move(query, by: 1) }, delete: { deleting = query })
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                                    withAnimation(.snappy(duration: 0.2)) { model.move(id, before: query.id) }
                                    return true
                                }
                            }
                        }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
                    }
                    .environment(\.resultHeights, ResultHeights(viewport: proxy.size.height))
                }.background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 360)
        .navigationTitle("Queries")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.editing = SavedQuery() } label: { Label("Add Query", systemImage: "plus") }.help("Add a saved query (⌘N)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Time Range", selection: rangeBinding) {
                    Text("15m").tag(900.0); Text("1h").tag(3600.0); Text("6h").tag(21600.0); Text("24h").tag(86400.0); Text("Custom…").tag(-1.0)
                }.fixedSize().help("Choose the time range for all queries")
                Button { model.refreshAll() } label: { Label("Refresh All", systemImage: "arrow.clockwise") }.help("Refresh all queries (⌘R)")
                Picker("Auto-refresh", selection: $model.collection.refreshSeconds) {
                    Text("Auto off").tag(0); Text("Auto 30s").tag(30); Text("Auto 1m").tag(60); Text("Auto 5m").tag(300)
                }.fixedSize().help("Choose how often all queries refresh automatically").onChange(of: model.collection.refreshSeconds) { model.persist(); model.scheduleNext() }
                Menu {
                    Button("Collapse All", systemImage: "chevron.up.2") { withAnimation(.snappy(duration: 0.2)) { model.collapseAll() } }
                        .disabled(model.collection.queries.isEmpty).help("Collapse all query cards (⇧⌘[)")
                    Button("Expand All", systemImage: "chevron.down.2") { withAnimation(.snappy(duration: 0.2)) { model.expandAll() } }
                        .disabled(model.collection.queries.isEmpty).help("Expand all query cards (⇧⌘])")
                    Divider()
                    Button("Import Collection…") { model.showImporter = true }.help("Replace the current collection from a JSON file")
                    Button("Export Collection…") { model.showExporter = true }.help("Save the current collection to a JSON file")
                } label: { Label("Collection", systemImage: "folder") }.help("Collapse, expand, import or export queries")
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }.help("Configure gcx and your connection (⌘,)")
            }
        }
        .sheet(item: $model.editing) { query in QueryEditor(query: query, datasources: model.datasources) { model.save($0) } }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.importCollection(from: url)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $model.showExporter, document: model.showExporter ? CollectionDocument(data: (try? model.exportData()) ?? Data()) : CollectionDocument(data: Data()), contentType: .json, defaultFilename: "Queries") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
        .alert("Queries", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete \(deleting?.title ?? "query")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
        } message: { Text("This removes the saved query. This can't be undone.") }
        .confirmationDialog("Replace this query collection?", isPresented: Binding(get: { model.pendingImport != nil }, set: { if !$0 { model.pendingImport = nil } }), titleVisibility: .visible) {
            Button("Replace", role: .destructive) { model.confirmImport() }
        } message: { Text("A local backup of the existing collection will be created first.") }
        .onChange(of: model.showSettings) { _, show in if show { model.showSettings = false; openSettings() } }
        .onReceive(clock) { _ in model.tick() }
        .onChange(of: scenePhase) { model.activityChanged(scenePhase == .active) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.activityChanged(false) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.activityChanged(NSApp.isActive) }
        .task { if model.showSettings { model.showSettings = false; openSettings() }; await model.testConnection(); model.scheduleNext() }
    }
    @ViewBuilder private var rangeFields: some View {
        DatePicker("From", selection: $model.customStart)
        DatePicker("To", selection: $model.customEnd)
        Button("Apply Range") { model.rangeChanged() }
    }
    private var countText: String {
        model.runningCount > 0 ? "Refreshing \(model.runningCount) \(model.runningCount == 1 ? "query" : "queries")…" : "\(model.collection.queries.count) saved \(model.collection.queries.count == 1 ? "query" : "queries")"
    }
    private var rangeText: String { "\(model.window.start.formatted(date: .omitted, time: .standard)) – \(model.window.end.formatted(date: .omitted, time: .standard))" }
    private var statusBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if model.runningCount > 0 { ProgressView().controlSize(.mini) }
                Text(countText)
                Spacer(minLength: 12)
                if model.collection.refreshSeconds > 0 { Label("Auto-refresh \(model.nextRefresh == nil ? "paused" : "on")", systemImage: model.nextRefresh == nil ? "pause.circle" : "arrow.triangle.2.circlepath") }
                Text(rangeText).monospacedDigit()
            }
            HStack(spacing: 8) {
                if model.runningCount > 0 { ProgressView().controlSize(.mini) }
                Text(countText).lineLimit(1)
                Spacer(minLength: 12)
                Text(rangeText).monospacedDigit().lineLimit(1)
            }
            HStack(spacing: 8) { Text(countText).lineLimit(1); Spacer(minLength: 0) }
        }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
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
        }.padding(26).frame(width: 600).fixedSize(horizontal: false, vertical: true)
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
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
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
              }.padding(.horizontal, 2)
            }
            HStack {
                Text("Runs only when requested or on auto-refresh.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { do { try query.validate(); save(query); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 680).frame(minHeight: 340, idealHeight: 640, maxHeight: 760)
    }
}
