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

public protocol DeviceProtocolCodec: Sendable {
    func decode(_ report: RawHIDReport, sequence: UInt64) -> InputEvent
    func encode(_ update: SurfaceUpdate) throws -> [RawHIDReport]
}

public enum ProtocolCodecError: Error, Equatable {
    case unsupportedSurface
    case invalidPayload
    case unsupportedDevice(DeviceModel)
}

public struct StreamDeckPlusCodec: DeviceProtocolCodec {
    public init() {}
    public func decode(_ report: RawHIDReport, sequence: UInt64) -> InputEvent {
        guard report.reportID == 0x01, let command = report.bytes.first else {
            return .protocolAnomaly(ProtocolAnomaly(reportID: report.reportID, payload: report.bytes, message: "Unsupported input report"))
        }

        switch command {
        case 0x00:
            let pressed = report.bytes.dropFirst().first == 1
            return .key(controlID: ControlID(rawValue: "key.0"), pressed: pressed, sequence: sequence)
        case 0x03:
            let delta = Int(Int8(bitPattern: report.bytes.dropFirst().first ?? 0))
            return .encoderRotation(controlID: ControlID(rawValue: "encoder.0"), delta: delta, sequence: sequence)
        default:
            return .protocolAnomaly(ProtocolAnomaly(reportID: report.reportID, payload: report.bytes, message: "Unknown Stream Deck + command"))
        }
    }

    public func encode(_ update: SurfaceUpdate) throws -> [RawHIDReport] {
        switch update.presentation {
        case .blank, .text, .image, .composite:
            return [RawHIDReport(reportID: 0x02, bytes: Data([0x02]))]
        }
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
