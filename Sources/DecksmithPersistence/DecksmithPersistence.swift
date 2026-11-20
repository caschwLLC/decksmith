import Foundation
import DecksmithCore

public actor VersionedStore<Value: Codable & Sendable> {
    private var value: SchemaEnvelope<Value>?
    public init() {}
    public func save(_ value: Value, kind: String, schemaVersion: Int = 1) {
        self.value = SchemaEnvelope(schemaVersion: schemaVersion, kind: kind, value: value)
    }

    public func load() -> SchemaEnvelope<Value>? { value }
}

public actor DiskVersionedStore<Value: Codable & Sendable> {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func save(_ value: Value, kind: String, schemaVersion: Int = 1) throws {
        let envelope = SchemaEnvelope(schemaVersion: schemaVersion, kind: kind, value: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    public func load() throws -> SchemaEnvelope<Value>? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(SchemaEnvelope<Value>.self, from: Data(contentsOf: fileURL))
    }
}

public protocol SchemaMigration: Sendable {
    associatedtype Value: Codable & Sendable
    var fromVersion: Int { get }
    var toVersion: Int { get }
    func migrate(_ value: Value) throws -> Value
}

public enum PersistenceError: Error, Equatable {
    case migrationUnavailable(from: Int, to: Int)
}

public actor MigrationPipeline<Value: Codable & Sendable> {
    private var migrations: [Int: any SchemaMigrationBox<Value>] = [:]

    public init() {}

    public func register<M: SchemaMigration>(_ migration: M) where M.Value == Value {
        migrations[migration.fromVersion] = AnySchemaMigration(migration: migration)
    }

    public func migrate(_ envelope: SchemaEnvelope<Value>, to targetVersion: Int) throws -> SchemaEnvelope<Value> {
        var version = envelope.schemaVersion
        var value = envelope.value
        while version < targetVersion {
            guard let migration = migrations[version] else {
                throw PersistenceError.migrationUnavailable(from: version, to: targetVersion)
            }
            value = try migration.migrate(value)
            version = migration.toVersion
        }
        return SchemaEnvelope(schemaVersion: version, kind: envelope.kind, value: value)
    }
}

private protocol SchemaMigrationBox<Value>: Sendable {
    associatedtype Value: Codable & Sendable
    var toVersion: Int { get }
    func migrate(_ value: Value) throws -> Value
}

private struct AnySchemaMigration<StoredValue: Codable & Sendable, M: SchemaMigration>: SchemaMigrationBox where M.Value == StoredValue {
    typealias Value = StoredValue
    let migration: M
    var toVersion: Int { migration.toVersion }
    func migrate(_ value: Value) throws -> Value { try migration.migrate(value) }
}
