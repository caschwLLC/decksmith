import Foundation
import DecksmithCore
import DecksmithProtocol
import DecksmithRendering
import DecksmithTransport

public struct DeviceSessionMetrics: Sendable, Equatable {
    public private(set) var receivedPackets = 0
    public private(set) var droppedEvents = 0
    public private(set) var decodedEvents = 0
    public private(set) var writtenReports = 0
    public private(set) var reconnects = 0

    public init() {}
    mutating func recordPacket() { receivedPackets += 1 }
    mutating func recordDecoded() { decodedEvents += 1 }
    mutating func recordWrite() { writtenReports += 1 }
    mutating func recordReconnect() { reconnects += 1 }
}

public actor DeviceSession {
    private let transport: any HIDTransport
    private let codec: any DeviceProtocolCodec
    private let renderer: any SurfaceRenderer
    private var latestRevision: [SurfaceID: SurfaceRevision] = [:]
    private var inputTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<InputEvent>.Continuation?
    private var sequence: UInt64 = 0
    private var metrics = DeviceSessionMetrics()

    public init(
        transport: any HIDTransport,
        codec: any DeviceProtocolCodec = StreamDeckPlusCodec(),
        renderer: any SurfaceRenderer = DeterministicRenderer()
    ) {
        self.transport = transport
        self.codec = codec
        self.renderer = renderer
    }

    public func events() -> AsyncStream<InputEvent> {
        eventContinuation?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.eventContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.clearEventContinuation() }
            }
        }
    }

    public func connect() async throws {
        guard inputTask == nil else { return }
        let packets = await transport.packets()
        try await transport.open()
        inputTask = Task { [weak self] in
            for await packet in packets {
                guard !Task.isCancelled else { return }
                await self?.receive(packet)
            }
        }
        emit(.lifecycle(.connected))
    }

    public func reconnect() async throws {
        metrics.recordReconnect()
        await disconnect()
        try await connect()
    }

    public func disconnect() async {
        inputTask?.cancel()
        inputTask = nil
        await transport.close()
        emit(.lifecycle(.disconnected))
    }

    public func currentTransportState() async -> TransportState {
        await transport.state()
    }

    public func submit(_ update: SurfaceUpdate) async throws {
        guard latestRevision[update.surfaceID, default: SurfaceRevision(0)] < update.revision else { return }
        let rendered = try await renderer.render(update)
        let reports = try codec.encodeImage(
            surfaceID: rendered.surfaceID,
            revision: rendered.revision,
            pixels: rendered.pixels
        )
        for report in reports {
            try await write(report)
        }
        latestRevision[update.surfaceID] = update.revision
    }

    public func setBrightness(_ brightness: UInt8) async throws {
        let report = try codec.encodeBrightness(brightness)
        try await write(report)
    }

    public func currentMetrics() -> DeviceSessionMetrics { metrics }

    private func receive(_ packet: TransportPacket) {
        metrics.recordPacket()
        let bytes = [UInt8](packet.bytes)
        guard let reportID = bytes.first else {
            let event = InputEvent.protocolAnomaly(ProtocolAnomaly(reportID: 0, payload: packet.bytes, message: "Empty HID packet"))
            emit(event)
            return
        }
        sequence &+= 1
        let report = RawHIDReport(reportID: reportID, bytes: Data(bytes.dropFirst()))
        for event in codec.decodeAll(report, sequence: sequence) {
            metrics.recordDecoded()
            emit(event)
        }
    }

    private func write(_ report: RawHIDReport) async throws {
        var bytes = Data([report.reportID])
        bytes.append(report.bytes)
        try await transport.write(TransportPacket(bytes: bytes))
        metrics.recordWrite()
    }

    private func write(_ report: HIDFeatureReport) async throws {
        var bytes = Data([report.reportID])
        bytes.append(report.bytes)
        try await transport.write(TransportPacket(bytes: bytes, reportType: .feature))
        metrics.recordWrite()
    }

    private func emit(_ event: InputEvent) {
        eventContinuation?.yield(event)
    }

    private func clearEventContinuation() {
        eventContinuation = nil
    }
}
