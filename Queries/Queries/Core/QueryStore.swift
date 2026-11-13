import Foundation

public final class QueryStore {
    public let url: URL
    private var recoveryRequired = false
    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Queries/collection.json")) { self.url = url }
    public func load() throws -> QueryCollection {
        guard FileManager.default.fileExists(atPath: url.path) else { return QueryCollection() }
        do { return try decode(Data(contentsOf: url)) }
        catch { recoveryRequired = true; throw QueryError.message("Cannot read the saved collection at \(url.path). It has been preserved. Restore a valid JSON export using Import. \(error.localizedDescription)") }
    }
    public func decode(_ data: Data) throws -> QueryCollection {
        let collection = try JSONDecoder().decode(QueryCollection.self, from: data)
        try collection.validate()
        return collection
    }
    public func encode(_ collection: QueryCollection) throws -> Data {
        try collection.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(collection)
    }
    public func save(_ collection: QueryCollection) throws {
        guard !recoveryRequired else { throw QueryError.message("Saving is paused to protect the unreadable collection. Import a valid backup to recover.") }
        let data = try encode(collection)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try Data(contentsOf: url).write(to: url.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }
    public func replace(with data: Data) throws -> QueryCollection {
        let collection = try decode(data)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try Data(contentsOf: url).write(to: url.deletingLastPathComponent().appendingPathComponent("collection-backup-\(UUID().uuidString).json"), options: .atomic)
        }
        try encode(collection).write(to: url, options: .atomic)
        recoveryRequired = false
        return collection
    }
}
