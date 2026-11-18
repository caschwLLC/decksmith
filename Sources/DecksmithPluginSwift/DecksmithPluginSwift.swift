import Foundation
import DecksmithCore

public struct PluginManifest: Codable, Sendable {
    public let id: PluginID
    public let name: String
    public let sdkVersion: Int
    public init(id: PluginID, name: String, sdkVersion: Int = 1) {
        self.id = id
        self.name = name
        self.sdkVersion = sdkVersion
    }
}

public protocol DecksmithPlugin: Sendable {
    var manifest: PluginManifest { get }
    func activate() async throws
    func handle(_ event: InputEvent) async
    func deactivate() async
}
