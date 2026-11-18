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
}
