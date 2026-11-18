import XCTest
import Foundation
@testable import DecksmithProtocol

final class DecksmithProtocolTests: XCTestCase {
    func testUnknownReportIsPreserved() {
        let event = StreamDeckPlusCodec().decode(RawHIDReport(reportID: 0x09, bytes: Data([0xAA])), sequence: 4)
        guard case let .protocolAnomaly(anomaly) = event else {
            return XCTFail("Expected protocol anomaly")
        }
        XCTAssertEqual(anomaly.reportID, 0x09)
        XCTAssertEqual(anomaly.payload, Data([0xAA]))
    }
}
