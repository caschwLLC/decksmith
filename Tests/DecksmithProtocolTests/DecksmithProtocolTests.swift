import XCTest
import Foundation
@testable import DecksmithCore
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

    func testImagePayloadIsChunkedWithStableHeaders() throws {
        let codec = StreamDeckPlusCodec(imageReportSize: 32)
        let reports = try codec.encodeImage(
            surfaceID: SurfaceID(rawValue: "key.0"),
            revision: SurfaceRevision(1),
            pixels: Data(0..<40)
        )

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.map(\.reportID), [0x02, 0x02])
        XCTAssertEqual(reports[0].bytes.count, 31)
        XCTAssertEqual(Array(reports[0].bytes.prefix(7)), [0x07, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(reports[1].bytes.dropFirst(7).prefix(16)), Array(24..<40))
    }

    func testBrightnessRejectsOutOfRangeValues() {
        XCTAssertThrowsError(try StreamDeckPlusCodec().encodeBrightness(101)) { error in
            XCTAssertEqual(error as? ProtocolCodecError, .invalidBrightness)
        }
    }

    func testBrightnessUsesStreamDeckFeatureCommandPayload() throws {
        let report = try StreamDeckPlusCodec().encodeBrightness(70)
        XCTAssertEqual(report.reportID, 0x03)
        XCTAssertEqual(report.bytes.count, 31)
        XCTAssertEqual(Array(report.bytes.prefix(2)), [0x08, 70])
    }

    func testInputReportsDecodeKeyTouchAndEncoderEvents() {
        let codec = StreamDeckPlusCodec()

        guard case let .key(_, pressed, _) = codec.decode(
            RawHIDReport(reportID: 0x01, bytes: Data([0x00, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0])),
            sequence: 1
        ) else { return XCTFail("Expected key event") }
        XCTAssertTrue(pressed)

        guard case let .touch(_, x, y, _) = codec.decode(
            RawHIDReport(reportID: 0x01, bytes: Data([0x02, 0x0A, 0x00, 0x01, 0x01, 0x2C, 0x01, 0x10, 0x00, 0, 0, 0, 0])),
            sequence: 2
        ) else { return XCTFail("Expected touch event") }
        XCTAssertEqual(x, 300)
        XCTAssertEqual(y, 16)

        guard case let .encoderRotation(controlID, delta, _) = codec.decode(
            RawHIDReport(reportID: 0x01, bytes: Data([0x03, 0x05, 0x00, 0x01, 0x00, 0x00, 0xFF, 0x00])),
            sequence: 3
        ) else { return XCTFail("Expected encoder event") }
        XCTAssertEqual(controlID.rawValue, "encoder.2")
        XCTAssertEqual(delta, -1)
    }

    func testEncoderPressUsesActiveLowSwitchState() {
        let codec = StreamDeckPlusCodec()
        guard case let .encoderPress(_, pressed, _) = codec.decode(
            RawHIDReport(reportID: 0x01, bytes: Data([0x03, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])),
            sequence: 4
        ) else { return XCTFail("Expected encoder press event") }
        XCTAssertTrue(pressed)

        guard case let .encoderPress(_, released, _) = codec.decode(
            RawHIDReport(reportID: 0x01, bytes: Data([0x03, 0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])),
            sequence: 5
        ) else { return XCTFail("Expected encoder release event") }
        XCTAssertFalse(released)
    }

    func testEncoderReportDecodesAllPressAndRotationChanges() {
        let codec = StreamDeckPlusCodec()
        let pressReport = RawHIDReport(
            reportID: 0x01,
            bytes: Data([0x03, 0x05, 0x00, 0x00, 0x01, 0x00, 0x01, 0x01])
        )
        let pressEvents = codec.decodeAll(pressReport, sequence: 6)
        XCTAssertEqual(pressEvents.count, 4)
        guard case let .encoderPress(controlID, pressed, sequence) = pressEvents[1] else {
            return XCTFail("Expected encoder press event")
        }
        XCTAssertEqual(controlID.rawValue, "encoder.1")
        XCTAssertTrue(pressed)
        XCTAssertEqual(sequence, 6)

        let rotationReport = RawHIDReport(
            reportID: 0x01,
            bytes: Data([0x03, 0x05, 0x00, 0x01, 0x01, 0xFF, 0x00, 0x00])
        )
        let rotationEvents = codec.decodeAll(rotationReport, sequence: 7)
        XCTAssertEqual(rotationEvents.count, 2)
        guard case let .encoderRotation(firstID, firstDelta, _) = rotationEvents[0],
              case let .encoderRotation(secondID, secondDelta, _) = rotationEvents[1] else {
            return XCTFail("Expected encoder rotation events")
        }
        XCTAssertEqual(firstID.rawValue, "encoder.0")
        XCTAssertEqual(firstDelta, 1)
        XCTAssertEqual(secondID.rawValue, "encoder.1")
        XCTAssertEqual(secondDelta, -1)
    }

    func testKeyStateReportDecodesEveryKey() {
        let report = RawHIDReport(
            reportID: 0x01,
            bytes: Data([0x00, 0x08, 0x00, 1, 0, 1, 0, 0, 0, 1, 0])
        )

        let events = StreamDeckPlusCodec().decodeAll(report, sequence: 8)

        XCTAssertEqual(events.count, 8)
        for (index, event) in events.enumerated() {
            guard case let .key(controlID, pressed, _) = event else {
                return XCTFail("Expected key event at index \(index)")
            }
            XCTAssertEqual(controlID.rawValue, "key.\(index)")
            XCTAssertEqual(pressed, [true, false, true, false, false, false, true, false][index])
        }
    }
}
