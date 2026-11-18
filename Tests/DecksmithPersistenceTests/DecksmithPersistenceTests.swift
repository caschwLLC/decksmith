import XCTest
@testable import DecksmithCore
@testable import DecksmithPersistence

final class DecksmithPersistenceTests: XCTestCase {
    func testVersionedStoreRetainsSchemaEnvelope() async {
        let store = VersionedStore<DeviceID>()
        await store.save(DeviceID(rawValue: "deck"), kind: "device", schemaVersion: 2)
        let saved = await store.load()
        XCTAssertEqual(saved?.schemaVersion, 2)
        XCTAssertEqual(saved?.kind, "device")
    }
}
