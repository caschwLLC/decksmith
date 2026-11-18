import XCTest
@testable import DecksmithCore
@testable import DecksmithProtocol

final class ProtocolRegistryTests: XCTestCase {
    func testUnknownDeviceIsRejected() {
        XCTAssertThrowsError(try ProtocolRegistry.codec(for: .unknown)) { error in
            XCTAssertEqual(error as? ProtocolCodecError, .unsupportedDevice(.unknown))
        }
    }
}
