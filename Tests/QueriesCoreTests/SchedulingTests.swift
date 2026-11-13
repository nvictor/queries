import XCTest
@testable import QueriesCore
@testable import QueriesAppState

actor ControlledExecutor: QueryExecuting {
    struct Request: Sendable { let query: SavedQuery; let context: String; let window: QueryWindow }
    var requests: [Request] = []
    var pending: [UUID:CheckedContinuation<QueryResult, Error>] = [:]
    var peak = 0
    func execute(_ query: SavedQuery, context: String, window: QueryWindow) async throws -> QueryResult {
        requests.append(Request(query: query, context: context, window: window))
        return try await withCheckedThrowingContinuation { continuation in
            pending[query.id] = continuation; peak = max(peak, pending.count)
        }
    }
    func complete(_ id: UUID, fail: Bool = false) {
        guard let continuation = pending.removeValue(forKey: id), let request = requests.last(where: { $0.query.id == id }) else { return }
        if fail { continuation.resume(throwing: QueryError.message("Test connection failure")) }
        else { continuation.resume(returning: QueryResult(series: [TimeSeries(labels: [:], samples: [Sample(timestamp: request.window.end, value: 42)])], window: request.window)) }
    }
    func count() -> Int { requests.count }
    func completeAll() { for id in Array(pending.keys) { complete(id) } }
}
@MainActor final class SchedulingTests: XCTestCase {
    func makeModel(_ executor: ControlledExecutor) -> StackViewModel {
        let model = StackViewModel(store: QueryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/collection.json")), executor: executor)
        model.collection.context = "explicit-context"
        for i in 0..<5 { var query = SavedQuery(); query.title = "Query \(i)"; query.text = "up"; query.datasourceUID = "p"; model.collection.queries.append(query) }
        return model
    }
    func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 { if await predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Condition did not become true")
    }
    func testConcurrencySharedWindowAndIndependentFailures() async throws {
        let executor = ControlledExecutor(), model: StackViewModel
        model = makeModel(executor); model.refreshAll()
        try await waitFor { await executor.count() == 3 }
        let initial = await executor.requests
        XCTAssertEqual(Set(initial.map(\.context)), ["explicit-context"])
        XCTAssertTrue(initial.allSatisfy { $0.window == initial[0].window })
        await executor.complete(initial[0].query.id, fail: true)
        try await waitFor { await executor.count() == 4 }
        await executor.complete(initial[1].query.id)
        try await waitFor { await executor.count() == 5 }
        await executor.completeAll()
        try await waitFor { model.runningCount == 0 }
        let peak = await executor.peak; XCTAssertEqual(peak, 3)
        XCTAssertNotNil(model.states[initial[0].query.id]?.error)
        XCTAssertNotNil(model.states[initial[1].query.id]?.result)
        let all = await executor.requests; XCTAssertTrue(all.allSatisfy { $0.window == initial[0].window })
    }
    func testEditedResponseIgnoredAndStaleDataRetained() async throws {
        let executor = ControlledExecutor(), model: StackViewModel
        model = makeModel(executor); model.collection.queries = [model.collection.queries[0]]
        var query = model.collection.queries[0]; model.run(query)
        try await waitFor { await executor.count() == 1 }
        query.text = "different"; model.save(query)
        await executor.complete(query.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(model.states[query.id]?.result)
        model.run(query); try await waitFor { await executor.count() == 2 }
        await executor.complete(query.id); try await waitFor { model.runningCount == 0 }
        XCTAssertNotNil(model.states[query.id]?.result)
        model.run(query); try await waitFor { await executor.count() == 3 }
        await executor.complete(query.id, fail: true); try await waitFor { model.runningCount == 0 }
        XCTAssertTrue(model.states[query.id]?.stale == true); XCTAssertNotNil(model.states[query.id]?.result)
    }
    func testReplacementWaitsForCancelledExecutionAndIgnoresLateResult() async throws {
        let executor = ControlledExecutor()
        let live = makeModel(executor)
        live.collection.queries = [live.collection.queries[0]]
        let query = live.collection.queries[0]
        live.run(query); try await waitFor { await executor.count() == 1 }
        live.refreshAll()
        try await Task.sleep(nanoseconds: 30_000_000)
        let count = await executor.count(); XCTAssertEqual(count, 1)
        await executor.complete(query.id)
        try await waitFor { await executor.count() == 2 }
        XCTAssertNil(live.states[query.id]?.result)
        await executor.completeAll(); try await waitFor { live.runningCount == 0 }
        XCTAssertNotNil(live.states[query.id]?.result)
    }
    func testNoOverlapAndInactiveRefreshSuspension() async throws {
        let executor = ControlledExecutor(), model: StackViewModel
        model = makeModel(executor); model.collection.queries = [model.collection.queries[0]]
        let query = model.collection.queries[0]
        model.run(query); model.run(query)
        try await waitFor { await executor.count() == 1 }
        let count = await executor.count(); XCTAssertEqual(count, 1)
        await executor.completeAll(); try await waitFor { model.runningCount == 0 }
        model.collection.refreshSeconds = 30; model.activityChanged(false); model.nextRefresh = Date.distantPast; model.tick()
        let inactiveCount = await executor.count(); XCTAssertEqual(inactiveCount, 1)
        model.activityChanged(true); try await waitFor { await executor.count() == 2 }
        await executor.completeAll(); try await waitFor { model.runningCount == 0 }
    }
}
