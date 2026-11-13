import Foundation
import CryptoKit

public enum ResultNormalizer {
    public static func decode(_ data: Data, kind: ResultKind, window: QueryWindow, limit: Int = 1000) throws -> QueryResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], root["status"] as? String == "success",
              let body = root["data"] as? [String:Any], let type = body["resultType"] as? String,
              let rows = body["result"] as? [[String:Any]] else { throw QueryError.message("gcx returned an unsuccessful or unsupported response. Check the query in Grafana Explore.") }
        var result = QueryResult(window: window)
        if let warnings = root["warnings"] as? [Any], !warnings.isEmpty { result.warnings.append("The data source reported \(warnings.count) warning(s). Verify this query in Grafana Explore.") }
        if let infos = root["infos"] as? [Any], !infos.isEmpty { result.warnings.append("The data source reported \(infos.count) informational message(s).") }
        if kind == .logs {
            guard type == "streams" else { throw QueryError.message("Expected logs. Change the result type to Time series for a metric LogQL query.") }
            var entries: [LogEntry] = []
            var occurrences: [String:Int] = [:]
            for row in rows {
                guard let labels = row["stream"] as? [String:String], let values = row["values"] as? [Any] else { throw malformed() }
                for value in values {
                    let stamp: String, line: String
                    var allLabels = labels
                    if let object = value as? [String:Any], let ts = object["timestamp"] as? String, let text = object["line"] as? String {
                        stamp = ts; line = text
                        if let metadata = object["structuredMetadata"] as? [String:String] { allLabels.merge(metadata, uniquingKeysWith: { old, _ in old }) }
                    } else if let pair = value as? [String], pair.count >= 2 { stamp = pair[0]; line = pair[1] }
                    else { throw malformed() }
                    guard let nanos = Int64(stamp) else { throw malformed() }
                    let identity = String(decoding: try JSONSerialization.data(withJSONObject: ["labels": allLabels, "timestamp": stamp, "text": line], options: [.sortedKeys]), as: UTF8.self)
                    let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                    let occurrence = occurrences[digest, default: 0]; occurrences[digest] = occurrence + 1
                    entries.append(LogEntry(id: "\(digest):\(occurrence)", sourceTimestamp: stamp, timestamp: Date(timeIntervalSince1970: Double(nanos) / 1e9), text: line, labels: allLabels))
                }
            }
            entries = entries.enumerated().sorted { a, b in
                let left = Int64(a.element.sourceTimestamp)!, right = Int64(b.element.sourceTimestamp)!
                return left == right ? a.offset < b.offset : left > right
            }.map(\.element)
            result.possiblyTruncated = entries.count >= limit
            result.logs = Array(entries.prefix(limit))
        } else {
            guard type == "matrix" || type == "vector" else { throw QueryError.message("Expected time series. Change the result type to Logs for a log stream query.") }
            var grouped: [String:TimeSeries] = [:]
            for row in rows {
                guard let labels = row["metric"] as? [String:String] else { throw malformed() }
                let values: [[Any]]
                if type == "vector", let value = row["value"] as? [Any] { values = [value] }
                else if let samples = row["values"] as? [[Any]] { values = samples }
                else { throw malformed() }
                var samples: [Sample] = []
                for pair in values {
                    guard pair.count >= 2, let timestamp = pair[0] as? NSNumber, timestamp.doubleValue.isFinite else { throw malformed() }
                    let number = (pair[1] as? String).flatMap(Double.init) ?? (pair[1] as? NSNumber)?.doubleValue
                    if number == nil && !(pair[1] is NSNull) { throw malformed() }
                    samples.append(Sample(timestamp: Date(timeIntervalSince1970: timestamp.doubleValue), value: number.flatMap { $0.isFinite ? $0 : nil }))
                }
                let series = TimeSeries(labels: labels, samples: samples)
                let combined = (grouped[series.id]?.samples ?? []) + samples
                var byTime: [Date:Sample] = [:]
                for sample in combined { byTime[sample.timestamp] = sample }
                grouped[series.id] = TimeSeries(labels: labels, samples: byTime.values.sorted { $0.timestamp < $1.timestamp })
            }
            result.series = grouped.values.sorted { $0.id < $1.id }
        }
        return result
    }
    private static func malformed() -> QueryError { .message("gcx returned malformed sample data. No partial chart was substituted.") }
}
