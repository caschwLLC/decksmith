import XCTest
@testable import DecksmithUSB

final class DecksmithUSBTests: XCTestCase {
    func testUSBNodePreservesUnavailableFields() {
        let node = USBNode(id: "1", name: "Hub", unavailable: ["currentMilliAmps"])
        XCTAssertEqual(node.unavailable, ["currentMilliAmps"])
    }
}
