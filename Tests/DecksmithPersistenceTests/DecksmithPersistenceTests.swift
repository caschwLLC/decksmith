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

    func testDiskStoreRoundTripsEnvelope() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-\(UUID().uuidString).json")
        let store = DiskVersionedStore<DeviceID>(fileURL: url)
        try await store.save(DeviceID(rawValue: "deck"), kind: "device", schemaVersion: 3)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.schemaVersion, 3)
        XCTAssertEqual(loaded?.value, DeviceID(rawValue: "deck"))
        try? FileManager.default.removeItem(at: url)
    }
}
