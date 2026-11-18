import Foundation
import DecksmithCore
import DecksmithPluginSwift
import DecksmithPluginWebSocket

public actor PluginRuntime {
    private var nativePlugins: [PluginID: any DecksmithPlugin] = [:]
    public init() {}
    public func register(_ plugin: any DecksmithPlugin) {
        nativePlugins[plugin.manifest.id] = plugin
    }
    public func activateAll() async throws {
        for plugin in nativePlugins.values { try await plugin.activate() }
    }
    public func route(_ event: InputEvent) async {
        for plugin in nativePlugins.values { await plugin.handle(event) }
    }
}
