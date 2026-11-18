import Foundation
import DecksmithCore

public struct DecksmithEvent: Codable, Sendable {
    public let timestamp: Date
    public let category: String
    public let message: String
    public init(timestamp: Date = .now, category: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

public actor EventJournal {
    private var events: [DecksmithEvent] = []
    public init() {}
    public func append(_ event: DecksmithEvent) { events.append(event) }
    public func snapshot() -> [DecksmithEvent] { events }
}
