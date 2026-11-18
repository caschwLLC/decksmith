import Foundation
import DecksmithCore

public struct OfficialPluginEnvelope: Codable, Sendable, Equatable {
    public let event: String
    public let context: String?
    public let payload: [String: String]
    public init(event: String, context: String? = nil, payload: [String: String] = [:]) {
        self.event = event
        self.context = context
        self.payload = payload
    }
}

public enum OfficialPluginAdapterError: Error, Equatable {
    case unsupportedCommand(String)
}

public struct OfficialPluginAdapter: Sendable {
    public init() {}
    public func decode(_ data: Data) throws -> OfficialPluginEnvelope {
        try JSONDecoder().decode(OfficialPluginEnvelope.self, from: data)
    }
}
