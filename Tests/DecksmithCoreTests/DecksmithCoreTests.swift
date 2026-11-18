import XCTest
@testable import DecksmithCore

final class DecksmithCoreTests: XCTestCase {
    func testStableIDsRoundTrip() throws {
        let original = SchemaEnvelope(kind: "device", value: DeviceID(rawValue: "streamdeck-plus"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SchemaEnvelope<DeviceID>.self, from: data)
        XCTAssertEqual(decoded.value, original.value)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testSurfaceRevisionOrdering() {
        XCTAssertLessThan(SurfaceRevision(1), SurfaceRevision(2))
    }
}
