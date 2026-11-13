import Foundation

public protocol QueryExecuting: Sendable {
    func execute(_ query: SavedQuery, context: String, window: QueryWindow) async throws -> QueryResult
}
public struct QueryExecutor: QueryExecuting {
    public var executable: URL
    public var runner: any ProcessRunning
    public init(executable: URL, runner: any ProcessRunning = GCXRunner()) { self.executable = executable; self.runner = runner }
    public static func arguments(_ query: SavedQuery, context: String, window: QueryWindow) -> [String] {
        var args: [String]
        if query.language == .logQL && query.kind == .metrics { args = ["logs", "metrics", "--datasource", query.datasourceUID] }
        else { args = ["datasources", "query", query.datasourceUID] }
        args += ["--expr", query.text, "--context", context, "--from", ISO8601DateFormatter().string(from: window.start), "--to", ISO8601DateFormatter().string(from: window.end), "-o", "json", "--no-color"]
        if query.kind == .logs { args += ["--limit", "1000"] }
        else { args += ["--step", "\(window.step)s"] }
        return args
    }
    public func execute(_ query: SavedQuery, context: String, window: QueryWindow) async throws -> QueryResult {
        try query.validate()
        guard !context.isEmpty else { throw QueryError.message("Choose an authenticated gcx context in Settings.") }
        let output = try await runner.run(executable: executable, arguments: Self.arguments(query, context: context, window: window), timeout: 30, outputLimit: 16 * 1024 * 1024)
        try Self.check(output)
        return try ResultNormalizer.decode(output.stdout, kind: query.kind, window: window)
    }
    public func inspect(arguments: [String]) async throws -> Data {
        let output = try await runner.run(executable: executable, arguments: arguments + ["--no-color"], timeout: 30, outputLimit: 2 * 1024 * 1024)
        try Self.check(output); return output.stdout
    }
    public static func check(_ output: ProcessOutput) throws {
        guard output.code != 0 else { return }
        // Raw stderr can contain expressions, response bodies, or credentials. Never display it.
        let message: String
        switch output.code {
        case 2: message = "gcx rejected the command. Verify the installed gcx version and query settings."
        case 3,4: message = "gcx could not authorize the request. Authenticate this context in Terminal and retry."
        case 6: message = "gcx reports an incompatible Grafana version. Check server compatibility."
        default: message = "gcx failed (exit \(output.code)). Check the connection, context, and query in Grafana Explore, then retry."
        }
        throw QueryError.message(message)
    }
    public func datasources(context: String) async throws -> [Datasource] {
        let data = try await inspect(arguments: ["datasources", "list", "--context", context, "-o", "json"])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], let rows = root["datasources"] as? [[String:Any]] else { throw QueryError.message("Unsupported gcx data source response.") }
        return try rows.map { row in
            guard let uid = row["uid"] as? String, let name = row["name"] as? String, let type = row["type"] as? String else { throw QueryError.message("Malformed data source response.") }
            return Datasource(uid: uid, name: name, type: type)
        }.filter(\.supported)
    }
}
