import Foundation
import DecksmithCore

public struct USBNode: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let parentID: String?
    public let unavailable: [String]
    public init(id: String, name: String, parentID: String? = nil, unavailable: [String] = []) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.unavailable = unavailable
    }
}
