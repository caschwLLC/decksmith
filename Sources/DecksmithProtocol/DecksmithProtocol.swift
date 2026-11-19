import Foundation
import DecksmithCore

public struct RawHIDReport: Sendable, Equatable {
    public let reportID: UInt8
    public let bytes: Data

    public init(reportID: UInt8, bytes: Data) {
        self.reportID = reportID
        self.bytes = bytes
    }
}

public struct HIDFeatureReport: Sendable, Equatable {
    public let reportID: UInt8
    public let bytes: Data

    public init(reportID: UInt8, bytes: Data) {
        self.reportID = reportID
        self.bytes = bytes
    }
}

public struct ImageChunk: Sendable, Equatable {
    public let index: Int
    public let total: Int
    public let payload: Data

    public init(index: Int, total: Int, payload: Data) {
        self.index = index
        self.total = total
        self.payload = payload
    }
}

public protocol DeviceProtocolCodec: Sendable {
    func decode(_ report: RawHIDReport, sequence: UInt64) -> InputEvent
    func decodeAll(_ report: RawHIDReport, sequence: UInt64) -> [InputEvent]
    func encode(_ update: SurfaceUpdate) throws -> [RawHIDReport]
    func encodeImage(surfaceID: SurfaceID, revision: SurfaceRevision, pixels: Data) throws -> [RawHIDReport]
    func encodeBrightness(_ brightness: UInt8) throws -> HIDFeatureReport
}

public enum ProtocolCodecError: Error, Equatable {
    case unsupportedSurface
    case invalidPayload
    case invalidBrightness
    case unsupportedDevice(DeviceModel)
}

public struct StreamDeckPlusCodec: DeviceProtocolCodec {
    public let imageReportSize: Int
    public let keyCount: Int
    public let encoderCount: Int

    public init(imageReportSize: Int = 1024, keyCount: Int = 8, encoderCount: Int = 4) {
        self.imageReportSize = max(32, imageReportSize)
        self.keyCount = max(1, keyCount)
        self.encoderCount = max(1, encoderCount)
    }

    public func decodeAll(_ report: RawHIDReport, sequence: UInt64) -> [InputEvent] {
        guard report.reportID == 0x01,
              report.bytes.count >= 3 else {
            return [decode(report, sequence: sequence)]
        }

        let payloadLength = Int(report.bytes[1]) | (Int(report.bytes[2]) << 8)
        let payload = report.bytes.dropFirst(3).prefix(payloadLength)
        guard payloadLength <= payload.count, payload.count > 1 else {
            return [decode(report, sequence: sequence)]
        }

        if report.bytes.first == 0x03 {
            let encoderPayload = payload
            guard encoderPayload.count >= encoderCount else {
                return [anomaly(report, "Malformed encoder report")]
            }
            if encoderPayload.first == 0 {
                return encoderPayload.dropFirst().prefix(encoderCount).enumerated().map { index, state in
                    .encoderPress(
                        controlID: ControlID(rawValue: "encoder.\(index)"),
                        pressed: state == 0,
                        sequence: sequence
                    )
                }
            }
            if encoderPayload.first == 1 {
                return encoderPayload.dropFirst().prefix(encoderCount).enumerated().compactMap { index, rawDelta in
                    let delta = Int(Int8(bitPattern: rawDelta))
                    guard delta != 0 else { return nil }
                    return .encoderRotation(
                        controlID: ControlID(rawValue: "encoder.\(index)"),
                        delta: delta,
                        sequence: sequence
                    )
                }
            }
            return [anomaly(report, "Unknown encoder event type")]
        }

        return payload.prefix(keyCount).enumerated().map { index, state in
            .key(controlID: ControlID(rawValue: "key.\(index)"), pressed: state == 1, sequence: sequence)
        }
    }

    public func decode(_ report: RawHIDReport, sequence: UInt64) -> InputEvent {
        guard report.reportID == 0x01, let command = report.bytes.first else {
            return .protocolAnomaly(ProtocolAnomaly(
                reportID: report.reportID,
                payload: report.bytes,
                message: "Unsupported or empty input report"
            ))
        }

        guard report.bytes.count >= 3 else { return anomaly(report, "Malformed input report") }
        let payloadLength = Int(report.bytes[1]) | (Int(report.bytes[2]) << 8)
        let payload = report.bytes.dropFirst(3).prefix(payloadLength)
        guard payloadLength <= payload.count else { return anomaly(report, "Truncated input payload") }

        switch command {
        case 0x00:
            guard let state = payload.first, keyCount > 0 else { return anomaly(report, "Empty key input report") }
            return .key(controlID: ControlID(rawValue: "key.0"), pressed: state == 1, sequence: sequence)
        case 0x02:
            guard payload.count >= 6 else { return anomaly(report, "Malformed touch report") }
            let x = UInt16(payload[payload.startIndex + 2]) | (UInt16(payload[payload.startIndex + 3]) << 8)
            let y = UInt16(payload[payload.startIndex + 4]) | (UInt16(payload[payload.startIndex + 5]) << 8)
            return .touch(surfaceID: SurfaceID(rawValue: "touch.0"), x: Double(x), y: Double(y), sequence: sequence)
        case 0x03:
            guard payload.count >= encoderCount + 1 else { return anomaly(report, "Malformed encoder report") }
            let type = payload[payload.startIndex]
            if type == 0 {
                // Stream Deck+ reports the encoder switch active-low: 0 is down and 1 is up.
                return .encoderPress(controlID: ControlID(rawValue: "encoder.0"), pressed: payload[payload.startIndex + 1] == 0, sequence: sequence)
            }
            guard type == 1 else { return anomaly(report, "Unknown encoder event type") }
            let deltas = payload.dropFirst()
            let encoderIndex = deltas.firstIndex(where: { $0 != 0 }).map { deltas.distance(from: deltas.startIndex, to: $0) } ?? 0
            let delta = Int(Int8(bitPattern: deltas[deltas.index(deltas.startIndex, offsetBy: encoderIndex)]))
            return .encoderRotation(
                controlID: ControlID(rawValue: "encoder.\(encoderIndex)"),
                delta: delta,
                sequence: sequence
            )
        default:
            return anomaly(report, "Unknown Stream Deck + command")
        }
    }

    public func encode(_ update: SurfaceUpdate) throws -> [RawHIDReport] {
        switch update.presentation {
        case .blank:
            return try encodeImage(surfaceID: update.surfaceID, revision: update.revision, pixels: Data())
        case .image, .text, .composite:
            return try encodeImage(surfaceID: update.surfaceID, revision: update.revision, pixels: Data(update.surfaceID.rawValue.utf8))
        }
    }

    public func encodeImage(surfaceID: SurfaceID, revision: SurfaceRevision, pixels: Data) throws -> [RawHIDReport] {
        let command: UInt8
        let target: UInt8
        switch surfaceID.rawValue.split(separator: ".").first {
        case "key":
            guard let index = UInt8(surfaceID.rawValue.split(separator: ".").last ?? "") else {
                throw ProtocolCodecError.unsupportedSurface
            }
            command = 0x07
            target = index
        case "touch", "encoder":
            command = 0x0B
            target = 0
        default:
            throw ProtocolCodecError.unsupportedSurface
        }

        let payloadSize = imageReportSize - 8
        let chunks = max(1, Int(ceil(Double(pixels.count) / Double(payloadSize))))
        return (0..<chunks).map { index in
            let offset = index * payloadSize
            let end = min(offset + payloadSize, pixels.count)
            let chunk = offset < end ? pixels[offset..<end] : Data()
            var bytes = Data([command, target, index == chunks - 1 ? 1 : 0])
            bytes.append(UInt8(chunk.count & 0xff))
            bytes.append(UInt8((chunk.count >> 8) & 0xff))
            bytes.append(UInt8(index & 0xff))
            bytes.append(UInt8((index >> 8) & 0xff))
            bytes.append(chunk)
            bytes.append(contentsOf: repeatElement(UInt8(0), count: imageReportSize - 1 - bytes.count))
            return RawHIDReport(reportID: 0x02, bytes: bytes)
        }
    }

    public func encodeBrightness(_ brightness: UInt8) throws -> HIDFeatureReport {
        guard brightness <= 100 else { throw ProtocolCodecError.invalidBrightness }
        var bytes = Data([0x08, brightness])
        bytes.append(contentsOf: repeatElement(UInt8(0), count: 32 - 1 - bytes.count))
        return HIDFeatureReport(reportID: 0x03, bytes: bytes)
    }

    private func anomaly(_ report: RawHIDReport, _ message: String) -> InputEvent {
        .protocolAnomaly(ProtocolAnomaly(reportID: report.reportID, payload: report.bytes, message: message))
    }
}

public enum ProtocolRegistry {
    public static func codec(for model: DeviceModel) throws -> any DeviceProtocolCodec {
        switch model {
        case .streamDeckPlus:
            return StreamDeckPlusCodec()
        case .unknown:
            throw ProtocolCodecError.unsupportedDevice(model)
        }
    }
}
