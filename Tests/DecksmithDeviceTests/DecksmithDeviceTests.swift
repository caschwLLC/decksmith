import XCTest
@testable import DecksmithCore
@testable import DecksmithDevice
@testable import DecksmithTransport

final class DecksmithDeviceTests: XCTestCase {
    func testOlderSurfaceRevisionDoesNotWrite() async throws {
        let transport = InMemoryTransport()
        let session = DeviceSession(transport: transport)
        try await session.connect()
        let update = SurfaceUpdate(surfaceID: SurfaceID(rawValue: "key.0"), revision: SurfaceRevision(1), presentation: .text(title: "A", subtitle: nil))
        try await session.submit(update)
        let firstWriteCount = await transport.recordedWrites().count
        try await session.submit(update)
        let writes = await transport.recordedWrites()
        XCTAssertGreaterThan(firstWriteCount, 0)
        XCTAssertEqual(writes.count, firstWriteCount)
    }
}
