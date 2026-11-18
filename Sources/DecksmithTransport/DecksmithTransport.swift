import Foundation

public struct TransportPacket: Sendable, Equatable {
    public let bytes: Data
    public let timestamp: Date
    public init(bytes: Data, timestamp: Date = .now) {
        self.bytes = bytes
        self.timestamp = timestamp
    }
}

public enum TransportState: Sendable, Equatable {
    case closed
    case opening
    case open
    case closing
    case failed(String)
}

public protocol HIDTransport: Sendable {
    func packets() async -> AsyncStream<TransportPacket>
    func open() async throws
    func close() async
    func write(_ packet: TransportPacket) async throws
    func state() async -> TransportState
}

public actor InMemoryTransport: HIDTransport {
    private var currentState: TransportState = .closed
    private var continuation: AsyncStream<TransportPacket>.Continuation?
    private var writes: [TransportPacket] = []

    public init() {}

    public func packets() async -> AsyncStream<TransportPacket> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func open() async throws { currentState = .open }
    public func close() async { currentState = .closed; continuation?.finish() }
    public func write(_ packet: TransportPacket) async throws {
        guard currentState == .open else { throw TransportError.notOpen }
        writes.append(packet)
    }
    public func state() async -> TransportState { currentState }
    public func emit(_ packet: TransportPacket) { continuation?.yield(packet) }
    public func recordedWrites() -> [TransportPacket] { writes }
}

public enum TransportError: Error, Equatable {
    case notOpen
}
