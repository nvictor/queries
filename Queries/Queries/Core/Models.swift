import Foundation

public enum QueryLanguage: String, Codable, CaseIterable, Sendable { case promQL = "PromQL", logQL = "LogQL" }
public enum ResultKind: String, Codable, CaseIterable, Sendable { case metrics = "Time series", logs = "Logs" }
public struct SavedQuery: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var title = "Untitled query"
    public var text = ""
    public var language: QueryLanguage = .promQL
    public var kind: ResultKind = .metrics
    public var datasourceUID = ""
    public var unit = ""
    public var notes = ""
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case id, title, text, language, kind, datasourceUID, unit, notes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
        language = try values.decode(QueryLanguage.self, forKey: .language)
        kind = try values.decode(ResultKind.self, forKey: .kind)
        datasourceUID = try values.decode(String.self, forKey: .datasourceUID)
        unit = try values.decode(String.self, forKey: .unit)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !datasourceUID.isEmpty, language != .promQL || kind == .metrics else { throw QueryError.message("Every query needs a title, expression, compatible result type, and data source.") }
    }
}
public struct QueryCollection: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var queries: [SavedQuery] = []
    public var context = ""
    public var rangeSeconds: Double = 3600
    public var refreshSeconds = 0
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw QueryError.message("Unsupported collection version. Your existing collection was preserved.") }
        guard [0,30,60,300].contains(refreshSeconds), rangeSeconds.isFinite, rangeSeconds > 0,
              Set(queries.map(\.id)).count == queries.count else { throw QueryError.message("Invalid collection settings or duplicate query identifiers.") }
        try queries.forEach { try $0.validate() }
    }
}
public struct QueryWindow: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var step: Int { max(10, Int(ceil(end.timeIntervalSince(start) / 600))) }
    public init(start: Date, end: Date) { self.start = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970)); self.end = Date(timeIntervalSince1970: floor(end.timeIntervalSince1970)) }
}
public struct Sample: Identifiable, Equatable, Sendable {
    public let timestamp: Date
    public let value: Double?
    public var id: Date { timestamp }
    public init(timestamp: Date, value: Double?) { self.timestamp = timestamp; self.value = value }
}
public struct TimeSeries: Identifiable, Equatable, Sendable {
    public let labels: [String:String]
    public let samples: [Sample]
    public var id: String { labels.keys.sorted().map { "\($0.utf8.count):\($0)=\(labels[$0]!.utf8.count):\(labels[$0]!)" }.joined(separator: "|") }
    public var label: String { labels.keys.sorted().map { "\($0)=\(labels[$0]!)" }.joined(separator: ", ") }
    public var validSamples: [Sample] { samples.filter { $0.value != nil } }
    public func isBridged(at date: Date, step: Int) -> Bool {
        let valid = validSamples
        guard let following = valid.first(where: { $0.timestamp >= date }),
              let previous = valid.last(where: { $0.timestamp < date }) else { return false }
        return following.timestamp.timeIntervalSince(previous.timestamp) > Double(step) * 1.5 || samples.contains { $0.timestamp > previous.timestamp && $0.timestamp < following.timestamp && $0.value == nil }
    }
    public func bridges(before sample: Sample, step: Int) -> Bool {
        guard let index = validSamples.firstIndex(where: { $0.timestamp == sample.timestamp }), index > 0 else { return false }
        let previous = validSamples[index - 1]
        return sample.timestamp.timeIntervalSince(previous.timestamp) > Double(step) * 1.5 || samples.contains { $0.timestamp > previous.timestamp && $0.timestamp < sample.timestamp && $0.value == nil }
    }
}
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceTimestamp: String
    public let timestamp: Date
    public let text: String
    public let labels: [String:String]
}
public struct QueryResult: Sendable {
    public var series: [TimeSeries] = []
    public var logs: [LogEntry] = []
    public var warnings: [String] = []
    public var possiblyTruncated = false
    public var window: QueryWindow
    public var isEmpty: Bool { series.allSatisfy { $0.validSamples.isEmpty } && logs.isEmpty }
}
public struct Datasource: Identifiable, Sendable {
    public let uid: String
    public let name: String
    public let type: String
    public var id: String { uid }
    public var supported: Bool { type == "prometheus" || type == "loki" }
}
public enum QueryError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
