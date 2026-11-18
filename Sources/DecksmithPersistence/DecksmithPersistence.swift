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
