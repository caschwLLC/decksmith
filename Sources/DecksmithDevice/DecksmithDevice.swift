import Foundation
import DecksmithCore
import DecksmithProtocol
import DecksmithRendering
import DecksmithTransport

public actor DeviceSession {
    private let transport: any HIDTransport
    private let codec: any DeviceProtocolCodec
    private let renderer: any SurfaceRenderer
    private var latestRevision: [SurfaceID: SurfaceRevision] = [:]

    public init(transport: any HIDTransport, codec: any DeviceProtocolCodec = StreamDeckPlusCodec(), renderer: any SurfaceRenderer = DeterministicRenderer()) {
        self.transport = transport
        self.codec = codec
        self.renderer = renderer
    }

    public func connect() async throws { try await transport.open() }
    public func disconnect() async { await transport.close() }
    public func submit(_ update: SurfaceUpdate) async throws {
        guard latestRevision[update.surfaceID, default: SurfaceRevision(0)] < update.revision else { return }
        latestRevision[update.surfaceID] = update.revision
        let rendered = try await renderer.render(update)
        let output = try codec.encode(SurfaceUpdate(surfaceID: rendered.surfaceID, revision: rendered.revision, presentation: .image(assetID: rendered.surfaceID.rawValue)))
        for report in output {
            try await transport.write(TransportPacket(bytes: report.bytes))
        }
    }
}
