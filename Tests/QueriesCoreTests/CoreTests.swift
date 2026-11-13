import XCTest
@testable import QueriesCore
@testable import QueriesAppState

final class CoreTests: XCTestCase {
    let window = QueryWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600))
    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!) }
    func testObservedFixtures() throws {
        for name in ["prometheus", "loki-metrics"] {
            let result = try ResultNormalizer.decode(fixture(name), kind: .metrics, window: window)
            XCTAssertFalse(result.isEmpty); XCTAssertFalse(result.series[0].validSamples.isEmpty)
        }
        let logs = try ResultNormalizer.decode(fixture("loki-logs"), kind: .logs, window: window)
        XCTAssertFalse(logs.logs.isEmpty)
        XCTAssertEqual(Set(logs.logs.map(\.id)).count, logs.logs.count)
        XCTAssertTrue(logs.logs[0].sourceTimestamp.count >= 19)
    }
    func testGapsNonFiniteAndSinglePoint() throws {
        let json = #"{"status":"success","warnings":["partial"],"data":{"resultType":"matrix","result":[{"metric":{"a":"b"},"values":[[0,"2"],[10,"NaN"],[20,null],[40,"4"],[50,"+Inf"]]}]}}"#
        let result = try ResultNormalizer.decode(Data(json.utf8), kind: .metrics, window: window)
        let series = result.series[0]
        XCTAssertEqual(series.samples.count, 5); XCTAssertEqual(series.validSamples.map(\.value), [2,4])
        XCTAssertTrue(series.bridges(before: series.validSamples[1], step: 10)); XCTAssertFalse(result.warnings.isEmpty)
        let single = #"{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"5"]}]}}"#
        XCTAssertEqual(try ResultNormalizer.decode(Data(single.utf8), kind: .metrics, window: window).series[0].validSamples.count, 1)
    }
    func testMalformedAndEmpty() throws {
        for json in ["bad", #"{"status":"error"}"#, #"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"values":[[0,"garbage"]]}]}}"#] {
            XCTAssertThrowsError(try ResultNormalizer.decode(Data(json.utf8), kind: .metrics, window: window))
        }
        XCTAssertThrowsError(try ResultNormalizer.decode(fixture("loki-logs"), kind: .metrics, window: window))
        let empty = #"{"status":"success","data":{"resultType":"matrix","result":[]}}"#
        XCTAssertTrue(try ResultNormalizer.decode(Data(empty.utf8), kind: .metrics, window: window).isEmpty)
    }
    func testDuplicateLogsAndNanosecondOrder() throws {
        let json = #"{"status":"success","data":{"resultType":"streams","result":[{"stream":{"a":"b"},"values":[{"timestamp":"1794540000000000001","line":"same"},{"timestamp":"1794540000000000002","line":"same"},{"timestamp":"1794540000000000002","line":"same"}]}]}}"#
        let result = try ResultNormalizer.decode(Data(json.utf8), kind: .logs, window: window, limit: 3)
        XCTAssertEqual(result.logs.count, 3); XCTAssertEqual(Set(result.logs.map(\.id)).count, 3)
        XCTAssertEqual(result.logs.first?.sourceTimestamp, "1794540000000000002"); XCTAssertTrue(result.possiblyTruncated)
    }
    func testPersistenceAndRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QueryStore(url: dir.appendingPathComponent("collection.json"))
        var collection = QueryCollection(); var query = SavedQuery(); query.title = "Test"; query.text = "up\n| $HOME `touch /tmp/no`"; query.datasourceUID = "p"; collection.queries = [query]
        try store.save(collection); XCTAssertEqual(try store.load(), collection)
        XCTAssertEqual(try store.decode(store.encode(collection)), collection)
        var invalid = collection; invalid.schemaVersion = 99
        XCTAssertThrowsError(try store.replace(with: JSONEncoder().encode(invalid)))
        XCTAssertEqual(try store.load(), collection)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(QueryCollection()))
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "broken")
        XCTAssertEqual(try store.replace(with: store.encode(collection)), collection)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("collection-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8), "broken")
    }
    func testArgumentsAndRouting() throws {
        var query = SavedQuery(); query.text = "-up | '$HOME'\n`echo hi`"; query.datasourceUID = "p"
        let args = QueryExecutor.arguments(query, context: "explicit", window: window)
        XCTAssertEqual(args[args.firstIndex(of: "--expr")! + 1], query.text)
        XCTAssertEqual(args[args.firstIndex(of: "--context")! + 1], "explicit")
        XCTAssertEqual(window.step, 10)
        query.language = .logQL; query.kind = .metrics
        XCTAssertEqual(Array(QueryExecutor.arguments(query, context: "x", window: window).prefix(4)), ["logs","metrics","--datasource","p"])
        query.kind = .logs
        XCTAssertTrue(QueryExecutor.arguments(query, context: "x", window: window).contains("--limit"))
    }
    func testProcessLiteralArgumentsAndExit() async throws {
        let runner = GCXRunner()
        let literal = "quotes ' \" | $HOME\n`touch /tmp/queries-should-not-exist`"
        let output = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s",literal], timeout: 3, outputLimit: 10000)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), literal)
        let failed = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 3, outputLimit: 10000)
        XCTAssertNotEqual(failed.code, 0); XCTAssertThrowsError(try QueryExecutor.check(failed))
    }
    func testTimeoutCancellationAndBoundedOutput() async throws {
        let runner = GCXRunner()
        do { _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05, outputLimit: 1000); XCTFail("Expected timeout") } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 10, outputLimit: 1000) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], timeout: 3, outputLimit: 1000); XCTFail("Expected output bound") } catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
    }
    func testConcurrentPipeDrain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("pipes.sh")
        // Test-only executable. Production never invokes a shell or assembles command strings.
        try "#!/bin/sh\ni=0; while [ $i -lt 6000 ]; do echo 12345678901234567890; echo abcdefghijklmnopqrst >&2; i=$((i+1)); done\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try await GCXRunner().run(executable: script, arguments: [], timeout: 10, outputLimit: 500000)
        XCTAssertEqual(result.code, 0); XCTAssertGreaterThan(result.stdout.count, 100000); XCTAssertGreaterThan(result.stderr.count, 100000)
    }
}
