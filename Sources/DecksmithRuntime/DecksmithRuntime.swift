import Foundation
import DecksmithCore
import DecksmithPluginSwift
import DecksmithPluginWebSocket
#if os(macOS)
import Foundation
#endif

public actor PluginRuntime {
    private var nativePlugins: [PluginID: any DecksmithPlugin] = [:]
    #if os(macOS)
    private var externalPlugins: [PluginID: (process: ExternalPluginProcess, server: OfficialPluginWebSocketServer)] = [:]
    #endif
    public init() {}
    public func register(_ plugin: any DecksmithPlugin) {
        nativePlugins[plugin.manifest.id] = plugin
    }
    public func activateAll() async throws {
        for plugin in nativePlugins.values { try await plugin.activate() }
    }

    public func deactivateAll() async {
        for plugin in nativePlugins.values { await plugin.deactivate() }
    }

    public func registeredPlugins() -> [PluginManifest] {
        nativePlugins.values.map(\.manifest).sorted { $0.name < $1.name }
    }

    public func route(_ event: InputEvent) async {
        for plugin in nativePlugins.values { await plugin.handle(event) }
    }

    #if os(macOS)
    public func startExternal(
        _ package: PluginPackage,
        port: UInt16,
        deviceID: String = "decksmith-stream-deck-plus"
    ) async throws {
        guard let executablePath = package.executablePath else {
            throw ExternalPluginProcessError.executableMissing
        }
        guard externalPlugins[package.id] == nil else {
            throw ExternalPluginProcessError.alreadyRunning
        }
        guard port > 0 else {
            throw ExternalPluginProcessError.launchFailed("invalid plugin port \(port)")
        }
        let server = try OfficialPluginWebSocketServer(port: port)
        server.start()
        guard await server.waitUntilReady() else {
            server.stop()
            throw ExternalPluginProcessError.launchFailed("plugin websocket listener did not become ready")
        }
        let process = ExternalPluginProcess()
        do {
            try await process.launch(ExternalPluginLaunchConfiguration(
                executableURL: URL(fileURLWithPath: executablePath),
                pluginID: package.id,
                port: Int(port),
                info: registrationInfo(for: package, deviceID: deviceID)
            ))
        } catch {
            server.stop()
            throw error
        }
        externalPlugins[package.id] = (process, server)
    }

    public func externalDiagnostics(
        for pluginID: PluginID
    ) async -> (process: ExternalPluginProcessDiagnostics, websocketState: String, connected: Bool)? {
        guard let external = externalPlugins[pluginID] else { return nil }
        return (
            process: await external.process.diagnostics(),
            websocketState: external.server.stateDescription(),
            connected: external.server.isConnected()
        )
    }

    private func registrationInfo(for package: PluginPackage, deviceID: String) -> String {
        let payload: [String: Any] = [
            "application": [
                "language": "en",
                "platform": "mac",
                "platformVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "version": "7.6.1.23033"
            ],
            "colors": [
                "buttonPressedBackgroundColor": "#303030FF",
                "buttonPressedBorderColor": "#646464FF",
                "buttonPressedTextColor": "#969696FF",
                "highlightColor": "#62BA46FF",
                "mouseDownColor": "#46972DFF"
            ],
            "devicePixelRatio": 2,
            "devices": [
                [
                    "id": deviceID,
                    "name": "Stream Deck +",
                    "size": ["columns": 4, "rows": 2],
                    "type": 7
                ]
            ],
            "plugin": [
                "uuid": package.id.rawValue,
                "version": package.manifest.version
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let info = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return info
    }

    public func waitForExternalConnection(
        _ pluginID: PluginID,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        guard let server = externalPlugins[pluginID]?.server else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if server.isConnected() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return server.isConnected()
    }

    #if os(macOS)
    public func externalMessages(for pluginID: PluginID) -> AsyncStream<OfficialPluginEnvelope>? {
        externalPlugins[pluginID]?.server.messages
    }
    #endif

    public func stopExternal(_ pluginID: PluginID) async throws {
        guard let external = externalPlugins.removeValue(forKey: pluginID) else {
            throw ExternalPluginProcessError.notRunning
        }
        external.server.stop()
        try await external.process.terminate()
    }

    public func sendExternal(
        _ envelope: OfficialPluginEnvelope,
        to pluginID: PluginID,
        timeout: Duration = .seconds(2)
    ) async throws {
        guard let external = externalPlugins[pluginID] else {
            throw ExternalPluginProcessError.notRunning
        }
        guard await external.process.isRunning() else {
            throw ExternalPluginProcessError.notRunning
        }
        let deadline = ContinuousClock.now + timeout
        while !external.server.isConnected(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard external.server.isConnected() else {
            throw ExternalPluginProcessError.notRunning
        }
        try external.server.send(envelope)
    }

    public func stopAllExternal() async {
        let plugins = externalPlugins
        externalPlugins.removeAll()
        for (_, external) in plugins {
            external.server.stop()
            try? await external.process.terminate()
        }
    }
    #endif
}
