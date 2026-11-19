import Foundation
import DecksmithCore
#if os(macOS)
import Network
#endif

public struct ExternalPluginLaunchConfiguration: Sendable, Equatable {
    public let executableURL: URL
    public let pluginID: PluginID
    public let port: Int
    public let registerEvent: String
    public let info: String

    public init(
        executableURL: URL,
        pluginID: PluginID,
        port: Int,
        registerEvent: String = "registerPlugin",
        info: String = "{}"
    ) {
        self.executableURL = executableURL
        self.pluginID = pluginID
        self.port = port
        self.registerEvent = registerEvent
        self.info = info
    }
}

public enum ExternalPluginProcessError: Error, Equatable {
    case executableMissing
    case alreadyRunning
    case notRunning
    case launchFailed(String)
}

public struct ExternalPluginProcessDiagnostics: Sendable, Equatable {
    public let pid: Int32?
    public let executablePath: String?
    public let arguments: [String]
    public let isRunning: Bool
    public let terminationStatus: Int32?
    public let standardError: String

    public init(
        pid: Int32?,
        executablePath: String?,
        arguments: [String],
        isRunning: Bool,
        terminationStatus: Int32?,
        standardError: String
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
        self.isRunning = isRunning
        self.terminationStatus = terminationStatus
        self.standardError = standardError
    }
}

public actor ExternalPluginProcess {
    private var process: Process?
    private var errorPipe: Pipe?
    private var executablePath: String?
    private var arguments: [String] = []
    private var terminationStatus: Int32?

    public init() {}

    deinit {
        if let process, process.isRunning {
            process.terminate()
        }
    }

    public func launch(_ configuration: ExternalPluginLaunchConfiguration) throws {
        guard FileManager.default.fileExists(atPath: configuration.executableURL.path) else {
            throw ExternalPluginProcessError.executableMissing
        }

        guard process == nil else { throw ExternalPluginProcessError.alreadyRunning }

        let child = Process()
        child.currentDirectoryURL = configuration.executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if configuration.executableURL.pathExtension == "js" {
            child.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
            child.arguments = [
                configuration.executableURL.path,
                "-port", String(configuration.port),
                "-pluginUUID", configuration.pluginID.rawValue,
                "-registerEvent", configuration.registerEvent,
                "-info", configuration.info
            ]
        } else {
            child.executableURL = configuration.executableURL
            child.arguments = [
                "-port", String(configuration.port),
                "-pluginUUID", configuration.pluginID.rawValue,
                "-registerEvent", configuration.registerEvent,
                "-info", configuration.info
            ]
        }
        let errorPipe = Pipe()
        child.standardError = errorPipe
        self.errorPipe = errorPipe
        self.executablePath = child.executableURL?.path
        self.arguments = child.arguments ?? []
        self.terminationStatus = nil
        do {
            try child.run()
            process = child
        } catch {
            throw ExternalPluginProcessError.launchFailed(error.localizedDescription)
        }

    }

    public func terminate() async throws {
        guard let process else { throw ExternalPluginProcessError.notRunning }
        if process.isRunning {
            process.terminate()
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        terminationStatus = process.terminationStatus
        self.process = nil
    }

    public func isRunning() -> Bool {
        process?.isRunning == true
    }

    public func diagnostics() -> ExternalPluginProcessDiagnostics {
        let running = process?.isRunning == true
        let errorData: Data
        if running {
            errorData = Data()
        } else {
            errorData = errorPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        }
        let observedTerminationStatus: Int32?
        if running {
            observedTerminationStatus = nil
        } else {
            observedTerminationStatus = process?.terminationStatus
        }
        return ExternalPluginProcessDiagnostics(
            pid: process?.processIdentifier,
            executablePath: executablePath,
            arguments: arguments,
            isRunning: running,
            terminationStatus: terminationStatus ?? observedTerminationStatus,
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

public enum PluginJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: PluginJSONValue])
    case array([PluginJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: PluginJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([PluginJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct OfficialPluginEnvelope: Codable, Sendable, Equatable {
    public let event: String
    public let context: String?
    public let device: String?
    public let action: String?
    public let deviceInfo: PluginJSONValue?
    public let payload: [String: PluginJSONValue]
    public init(
        event: String,
        context: String? = nil,
        device: String? = nil,
        action: String? = nil,
        deviceInfo: PluginJSONValue? = nil,
        payload: [String: PluginJSONValue] = [:]
    ) {
        self.event = event
        self.context = context
        self.device = device
        self.action = action
        self.deviceInfo = deviceInfo
        self.payload = payload
    }

    public init(event: String, context: String? = nil, payload: [String: String]) {
        self.init(
            event: event,
            context: context,
            payload: payload.mapValues(PluginJSONValue.string)
        )
    }
}

public enum OfficialPluginAdapterError: Error, Equatable {
    case unsupportedCommand(String)
    case malformedMessage
}

public struct OfficialPluginAdapter: Sendable {
    public init() {}
    public func decode(_ data: Data) throws -> OfficialPluginEnvelope {
        do {
            return try JSONDecoder().decode(OfficialPluginEnvelope.self, from: data)
        } catch {
            throw OfficialPluginAdapterError.malformedMessage
        }
    }

    public func encode(_ envelope: OfficialPluginEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public func validateCommand(_ envelope: OfficialPluginEnvelope) throws {
        let supported = Set([
            "registerPlugin", "didReceiveSettings", "didReceiveGlobalSettings", "sendToPlugin",
            "keyDown", "keyUp", "willAppear", "willDisappear", "propertyInspectorDidAppear",
            "propertyInspectorDidDisappear", "titleParametersDidChange", "deviceDidConnect",
            "deviceDidDisconnect", "setTitle", "setImage", "setState", "showAlert", "showOk",
            "sendToPropertyInspector", "setSettings", "getSettings", "setGlobalSettings",
            "getGlobalSettings", "openUrl", "logMessage", "switchToProfile"
        ])
        guard supported.contains(envelope.event) else {
            throw OfficialPluginAdapterError.unsupportedCommand(envelope.event)
        }
    }
}

public struct OfficialPluginManifest: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let description: String
    public let author: String

    public init(name: String, version: String = "1.0.0", description: String = "", author: String = "") {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
    }
}

public enum PluginConnectionState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
}

public actor PluginWebSocketSession {
    private let adapter = OfficialPluginAdapter()
    private var state: PluginConnectionState = .disconnected
    private var outgoing: [OfficialPluginEnvelope] = []
    private var manifest: OfficialPluginManifest?

    public init() {}

    public func connect(manifest: OfficialPluginManifest) {
        self.manifest = manifest
        state = .connected
        outgoing.append(OfficialPluginEnvelope(event: "registerPlugin", payload: [
            "name": .string(manifest.name),
            "version": .string(manifest.version)
        ]))
    }

    public func disconnect() {
        state = .disconnected
        manifest = nil
        outgoing.removeAll(keepingCapacity: true)
    }

    public func connectionState() -> PluginConnectionState { state }

    public func receive(_ data: Data) throws -> OfficialPluginEnvelope {
        let envelope = try adapter.decode(data)
        try adapter.validateCommand(envelope)
        return envelope
    }

    public func send(_ envelope: OfficialPluginEnvelope) throws {
        guard state == .connected else {
            throw OfficialPluginAdapterError.unsupportedCommand("session is not connected")
        }
        outgoing.append(envelope)
    }

    public func drainOutgoing() -> [OfficialPluginEnvelope] {
        defer { outgoing.removeAll(keepingCapacity: true) }
        return outgoing
    }
}

#if os(macOS)
public final class OfficialPluginWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.decksmith.plugin-websocket")
    private var connection: NWConnection?
    private var continuation: AsyncStream<OfficialPluginEnvelope>.Continuation?
    private let adapter = OfficialPluginAdapter()

    public init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    public var messages: AsyncStream<OfficialPluginEnvelope> {
        AsyncStream { continuation in self.continuation = continuation }
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    public func waitUntilReady(timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            switch listener.state {
            case .ready:
                return true
            case .failed, .cancelled:
                return false
            default:
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return listener.state == .ready
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        listener.cancel()
        continuation?.finish()
        continuation = nil
    }

    public func isConnected() -> Bool {
        connection != nil
    }

    public func stateDescription() -> String {
        switch listener.state {
        case .setup: return "setup"
        case .waiting(let error): return "waiting(\(error.localizedDescription))"
        case .ready: return "ready"
        case .failed(let error): return "failed(\(error.localizedDescription))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }

    public func send(_ envelope: OfficialPluginEnvelope) throws {
        guard let connection else {
            throw OfficialPluginAdapterError.unsupportedCommand("plugin websocket is not connected")
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "decksmith.plugin", metadata: [metadata])
        connection.send(
            content: try adapter.encode(envelope),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.continuation?.yield(OfficialPluginEnvelope(
                        event: "decksmithError",
                        payload: ["message": .string(error.localizedDescription)]
                    ))
                }
            }
        )
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        newConnection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let envelope = try? self.adapter.decode(data) {
                self.continuation?.yield(envelope)
            } else if let error {
                self.continuation?.yield(OfficialPluginEnvelope(
                    event: "decksmithError",
                    payload: ["message": .string(error.localizedDescription)]
                ))
            }
            if error == nil { self.receiveNext() }
        }
    }
}
#endif
