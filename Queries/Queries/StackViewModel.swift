#if canImport(QueriesCore)
import QueriesCore
#endif
import AppKit
import UniformTypeIdentifiers
import Combine
import SwiftUI

struct CardState {
    var requestID = UUID()
    var loading = false
    var result: QueryResult?
    var error: String?
    var lastSuccess: Date?
    var stale = false
}
@MainActor final class StackViewModel: ObservableObject {
    @Published var collection = QueryCollection()
    @Published var states: [UUID:CardState] = [:]
    @Published var datasources: [Datasource] = []
    @Published var contexts: [String] = []
    @Published var executablePath: String
    @Published var version = "Not checked"
    @Published var setupStatus = "Choose a context and test the connection."
    @Published var setupBusy = false
    @Published var error: String?
    @Published var showSettings = false
    @Published var window: QueryWindow
    @Published var customRange = false
    @Published var customStart = Date().addingTimeInterval(-3600)
    @Published var customEnd = Date()
    @Published var nextRefresh: Date?
    private static let collapsedKey = "collapsedQueries"
    @Published var collapsed: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(collapsed.map(\.uuidString), forKey: Self.collapsedKey) }
    }
    @Published var editing: SavedQuery?
    @Published var showImporter = false
    @Published var showExporter = false
    @Published var pendingImport: Data?
    func collapseAll() { collapsed = Set(collection.queries.map(\.id)) }
    func expandAll() { collapsed = [] }
    private let store: QueryStore
    private var executorOverride: (any QueryExecuting)?
    private struct Job { let query: SavedQuery; let token: UUID; let window: QueryWindow; let context: String; let executor: any QueryExecuting }
    private var queue: [Job] = []
    private var tasks: [UUID:Task<Void,Never>] = [:]
    private var activeQueries: [UUID:UUID] = [:]
    private var active = true
    var runningCount: Int { states.values.filter(\.loading).count }
    init(store: QueryStore = QueryStore(), executor: (any QueryExecuting)? = nil) {
        self.store = store; executorOverride = executor
        executablePath = GCXRunner.discover(preferred: UserDefaults.standard.string(forKey: "gcxPath") ?? "") ?? ""
        window = QueryWindow(start: Date().addingTimeInterval(-3600), end: Date())
        collapsed = Set((UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []).compactMap(UUID.init(uuidString:)))
        do { collection = try store.load() } catch { self.error = error.localizedDescription }
        if collection.context.isEmpty { showSettings = true }
        resolveWindow()
    }
    func persist() { do { try store.save(collection) } catch { self.error = error.localizedDescription } }
    func executor() -> any QueryExecuting { executorOverride ?? QueryExecutor(executable: URL(fileURLWithPath: executablePath)) }
    func resolveWindow() {
        if customRange { window = QueryWindow(start: customStart, end: customEnd) }
        else { let end = Date(); window = QueryWindow(start: end.addingTimeInterval(-collection.rangeSeconds), end: end) }
    }
    func rangeChanged() { cancelAll(); resolveWindow(); persist() }
    func refreshAll() {
        guard validWindow() else { return }
        cancelAll(); resolveWindow()
        for query in collection.queries { enqueue(query) }
        pump(); scheduleNext()
    }
    func run(_ query: SavedQuery) {
        guard states[query.id]?.loading != true, validWindow() else { return }
        if !customRange && runningCount == 0 { resolveWindow() }
        enqueue(query); pump()
    }
    private func validWindow() -> Bool {
        guard !customRange || customStart < customEnd else { error = "The start time must be before the end time."; return false }
        guard executorOverride != nil || GCXRunner.discover(preferred: executablePath) == executablePath && !executablePath.isEmpty else { error = "Choose an executable gcx path in Settings."; return false }
        guard !collection.context.isEmpty else { showSettings = true; return false }
        return true
    }
    private func enqueue(_ query: SavedQuery) {
        var state = states[query.id] ?? CardState()
        state.requestID = UUID(); state.loading = true; state.error = nil; state.stale = state.result != nil
        states[query.id] = state
        queue.append(Job(query: query, token: state.requestID, window: window, context: collection.context, executor: executor()))
    }
    private func pump() {
        while tasks.count < 3, let index = queue.firstIndex(where: { !activeQueries.values.contains($0.query.id) }) {
            let job = queue.remove(at: index)
            activeQueries[job.token] = job.query.id
            tasks[job.token] = Task { [weak self] in
                do {
                    let result = try await job.executor.execute(job.query, context: job.context, window: job.window)
                    guard let self else { return }
                    if !Task.isCancelled && self.states[job.query.id]?.requestID == job.token {
                        self.states[job.query.id]?.result = result
                        self.states[job.query.id]?.lastSuccess = Date()
                        self.states[job.query.id]?.stale = false
                        self.states[job.query.id]?.error = nil
                    }
                } catch {
                    if let self, self.states[job.query.id]?.requestID == job.token {
                        self.states[job.query.id]?.error = error is CancellationError ? "Cancelled. Run to retry." : error.localizedDescription
                        self.states[job.query.id]?.stale = self.states[job.query.id]?.result != nil
                    }
                }
                guard let self else { return }
                if self.states[job.query.id]?.requestID == job.token { self.states[job.query.id]?.loading = false }
                self.tasks.removeValue(forKey: job.token); self.activeQueries.removeValue(forKey: job.token); self.pump()
            }
        }
    }
    func cancel(_ id: UUID) {
        guard var state = states[id] else { return }
        tasks[state.requestID]?.cancel()
        queue.removeAll { $0.query.id == id }
        state.requestID = UUID(); state.loading = false; state.stale = state.result != nil
        states[id] = state
    }
    func cancelAll() { for id in Array(states.keys) { cancel(id) }; queue.removeAll() }
    func save(_ query: SavedQuery) {
        do { try query.validate() } catch { self.error = error.localizedDescription; return }
        cancel(query.id)
        if let index = collection.queries.firstIndex(where: { $0.id == query.id }) { collection.queries[index] = query }
        else { collection.queries.append(query) }
        persist()
    }
    func duplicate(_ query: SavedQuery) { var copy = query; copy.id = UUID(); copy.title += " copy"; save(copy) }
    func delete(_ query: SavedQuery) { cancel(query.id); states.removeValue(forKey: query.id); collection.queries.removeAll { $0.id == query.id }; persist() }
    func move(_ query: SavedQuery, by offset: Int) {
        guard let index = collection.queries.firstIndex(where: { $0.id == query.id }), collection.queries.indices.contains(index + offset) else { return }
        collection.queries.swapAt(index, index + offset); persist()
    }
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = collection.queries.firstIndex(where: { $0.id == id }),
              collection.queries.contains(where: { $0.id == target }) else { return }
        let item = collection.queries.remove(at: from)
        let to = collection.queries.firstIndex(where: { $0.id == target }) ?? collection.queries.endIndex
        collection.queries.insert(item, at: to); persist()
    }
    func scheduleNext() { nextRefresh = collection.refreshSeconds > 0 && active ? Date().addingTimeInterval(Double(collection.refreshSeconds)) : nil }
    func tick() { if active, let nextRefresh, Date() >= nextRefresh, runningCount == 0 { refreshAll() } }
    func activityChanged(_ isActive: Bool) {
        let returning = !active && isActive; active = isActive
        if returning && collection.refreshSeconds > 0 { refreshAll() }
        else { scheduleNext() }
    }
    func settingsChanged() { cancelAll(); datasources = []; UserDefaults.standard.set(executablePath, forKey: "gcxPath"); persist(); scheduleNext() }
    func testConnection() async {
        guard !setupBusy else { return }
        setupBusy = true; defer { setupBusy = false }
        guard let path = GCXRunner.discover(preferred: executablePath) else { setupStatus = "gcx was not found. Install it in Terminal, then Retry."; return }
        executablePath = path
        let executor = QueryExecutor(executable: URL(fileURLWithPath: path))
        do {
            let output = try await executor.inspect(arguments: ["--version"])
            version = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let contextData = try await executor.inspect(arguments: ["config", "list-contexts", "-o", "json"])
            if let root = try JSONSerialization.jsonObject(with: contextData) as? [String:Any], let rows = root["contexts"] as? [[String:Any]] { contexts = rows.compactMap { $0["name"] as? String } }
            if collection.context.isEmpty { setupStatus = "Select or enter an authenticated context, then Test Connection."; return }
            datasources = try await executor.datasources(context: collection.context)
            setupStatus = "Connected. \(datasources.count) supported data source(s)."
            UserDefaults.standard.set(path, forKey: "gcxPath"); persist()
        } catch { setupStatus = error.localizedDescription + " Authenticate in Terminal and retry." }
    }
    func importCollection(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { let data = try Data(contentsOf: url); _ = try store.decode(data); pendingImport = data }
        catch { self.error = error.localizedDescription }
    }
    func confirmImport() {
        guard let data = pendingImport else { return }
        pendingImport = nil
        do {
            let imported = try store.replace(with: data)
            cancelAll(); states = [:]; collapsed = []; collection = imported; datasources = []; customRange = false; resolveWindow(); scheduleNext()
        } catch { self.error = error.localizedDescription }
    }
    func exportData() throws -> Data { try store.encode(collection) }
    func addLocalExamples() {
        for (title, text, language, kind, uid) in [
            ("Demo load", "queries_demo_load", QueryLanguage.promQL, ResultKind.metrics, "queries-prometheus"),
            ("Demo request rate", "sum(rate({job=\"queries-demo\"}[1m]))", .logQL, .metrics, "queries-loki"),
            ("Demo logs", "{job=\"queries-demo\"}", .logQL, .logs, "queries-loki")
        ] { var query = SavedQuery(); query.title = title; query.text = text; query.language = language; query.kind = kind; query.datasourceUID = uid; save(query) }
    }
}
