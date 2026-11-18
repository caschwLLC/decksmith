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

public struct TransportMetrics: Sendable, Equatable {
    public private(set) var receivedPackets = 0
    public private(set) var droppedPackets = 0
    public private(set) var writtenPackets = 0
    public init() {}
    public mutating func recordReceived() { receivedPackets += 1 }
    public mutating func recordDropped() { droppedPackets += 1 }
    public mutating func recordWritten() { writtenPackets += 1 }
}

public actor BoundedPacketBuffer {
    private let capacity: Int
    private var packets: [TransportPacket] = []
    private var metrics = TransportMetrics()

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func append(_ packet: TransportPacket) {
        metrics.recordReceived()
        if packets.count == capacity {
            packets.removeFirst()
            metrics.recordDropped()
        }
        packets.append(packet)
    }

    public func drain() -> [TransportPacket] {
        defer { packets.removeAll(keepingCapacity: true) }
        return packets
    }

    public func snapshotMetrics() -> TransportMetrics { metrics }
}
