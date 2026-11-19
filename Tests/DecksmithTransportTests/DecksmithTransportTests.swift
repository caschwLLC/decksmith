import XCTest
import Foundation
@testable import DecksmithTransport

final class DecksmithTransportTests: XCTestCase {
    func testTransportRejectsWritesBeforeOpen() async {
        let transport = InMemoryTransport()
        do {
            try await transport.write(TransportPacket(bytes: Data([1])))
            XCTFail("Expected not-open error")
        } catch let error as TransportError {
            XCTAssertEqual(error, .notOpen)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIOKitTransportRejectsWritesBeforeOpen() async {
        let transport = IOKitHIDTransport(vendorID: 0x1234, productID: 0x5678)
        do {
            try await transport.write(TransportPacket(bytes: Data([0x02])))
            XCTFail("Expected not-open error")
        } catch let error as TransportError {
            XCTAssertEqual(error, .notOpen)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHIDDiscoveryIsSafeWithoutMatchingHardware() {
        let devices = IOKitHIDDiscovery.devices(vendorID: 0xFFFF)
        XCTAssertTrue(devices.isEmpty)
    }
}
