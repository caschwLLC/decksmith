import Foundation

public protocol DecksmithIdentifier: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {}

public struct DeviceID: DecksmithIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ControlID: DecksmithIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct SurfaceID: DecksmithIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct PluginID: DecksmithIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ActionInstanceID: DecksmithIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct PageID: DecksmithIdentifier { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

public struct FirmwareVersion: Codable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int?
    public init(major: Int, minor: Int, patch: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public enum DeviceModel: String, Codable, Sendable {
    case streamDeckPlus
    case unknown
}

public enum DeviceFeature: String, Codable, Hashable, Sendable {
    case keypad
    case encoders
    case touchscreen
    case brightness
    case layeredRendering
}

public struct DeviceCapabilities: Codable, Sendable {
    public let features: Set<DeviceFeature>
    public let keyCount: Int
    public let encoderCount: Int
    public let touchSize: PixelSize?
    public init(features: Set<DeviceFeature>, keyCount: Int, encoderCount: Int, touchSize: PixelSize? = nil) {
        self.features = features
        self.keyCount = keyCount
        self.encoderCount = encoderCount
        self.touchSize = touchSize
    }
}

public struct PixelSize: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct DeviceDescriptor: Codable, Sendable {
    public let id: DeviceID
    public let model: DeviceModel
    public let firmware: FirmwareVersion?
    public let vendorID: UInt16
    public let productID: UInt16
    public let capabilities: DeviceCapabilities
    public init(id: DeviceID, model: DeviceModel, firmware: FirmwareVersion?, vendorID: UInt16, productID: UInt16, capabilities: DeviceCapabilities) {
        self.id = id
        self.model = model
        self.firmware = firmware
        self.vendorID = vendorID
        self.productID = productID
        self.capabilities = capabilities
    }
}

public enum InputEvent: Codable, Sendable {
    case key(controlID: ControlID, pressed: Bool, sequence: UInt64)
    case encoderRotation(controlID: ControlID, delta: Int, sequence: UInt64)
    case encoderPress(controlID: ControlID, pressed: Bool, sequence: UInt64)
    case touch(surfaceID: SurfaceID, x: Double, y: Double, sequence: UInt64)
    case lifecycle(DeviceLifecycleEvent)
    case protocolAnomaly(ProtocolAnomaly)
}

public struct PageDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: PageID
    public let name: String
    public let bindings: [ControlID: ActionBinding]

    public init(id: PageID, name: String, bindings: [ControlID: ActionBinding] = [:]) {
        self.id = id
        self.name = name
        self.bindings = bindings
    }
}

public struct ActionBinding: Codable, Sendable, Equatable {
    public let actionInstanceID: ActionInstanceID
    public let trigger: InputTrigger
    public let pageID: PageID

    public init(actionInstanceID: ActionInstanceID, trigger: InputTrigger, pageID: PageID) {
        self.actionInstanceID = actionInstanceID
        self.trigger = trigger
        self.pageID = pageID
    }
}

public enum InputTrigger: Codable, Sendable, Equatable {
    case key(ControlID)
    case encoderRotation(ControlID)
    case encoderPress(ControlID)
    case touch(SurfaceID)
}

public enum NavigationCommand: Codable, Sendable, Equatable {
    case select(PageID)
    case next
    case previous
}

public struct IntegrationDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: PluginID
    public let name: String
    public let version: String
    public let capabilities: Set<String>

    public init(id: PluginID, name: String, version: String = "1.0", capabilities: Set<String> = []) {
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
    }
}

public enum DeviceLifecycleEvent: String, Codable, Sendable {
    case discovered
    case connected
    case disconnected
    case failed
}

public struct ProtocolAnomaly: Codable, Sendable, Equatable {
    public let reportID: UInt8
    public let payload: Data
    public let message: String
    public init(reportID: UInt8, payload: Data, message: String) {
        self.reportID = reportID
        self.payload = payload
        self.message = message
    }
}

public struct SurfaceRevision: Codable, Hashable, Sendable, Comparable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

public enum SurfacePresentation: Codable, Sendable, Equatable {
    case blank
    case image(assetID: String)
    case text(title: String, subtitle: String?)
    case composite(layers: [RenderLayer])
}

public enum RenderLayer: Codable, Sendable, Equatable {
    case image(assetID: String, x: Double, y: Double, width: Double, height: Double)
    case text(value: String, x: Double, y: Double, width: Double, height: Double)
    case progress(value: Double, x: Double, y: Double, width: Double, height: Double)
    case unavailable(x: Double, y: Double, width: Double, height: Double)
}

public struct SurfaceUpdate: Codable, Sendable, Equatable {
    public let surfaceID: SurfaceID
    public let revision: SurfaceRevision
    public let presentation: SurfacePresentation
    public init(surfaceID: SurfaceID, revision: SurfaceRevision, presentation: SurfacePresentation) {
        self.surfaceID = surfaceID
        self.revision = revision
        self.presentation = presentation
    }

    public struct ActionBinding: Codable, Sendable, Equatable {
        public let actionInstanceID: ActionInstanceID
        public let trigger: InputTrigger
        public let pageID: PageID
        public init(actionInstanceID: ActionInstanceID, trigger: InputTrigger, pageID: PageID) {
            self.actionInstanceID = actionInstanceID
            self.trigger = trigger
            self.pageID = pageID
        }
    }

    public enum InputTrigger: Codable, Sendable, Equatable {
        case key(ControlID)
        case encoderRotation(ControlID)
        case encoderPress(ControlID)
        case touch(SurfaceID)
    }

    public struct PageDefinition: Codable, Sendable, Equatable {
        public let id: PageID
        public let name: String
        public let bindings: [ControlID: ActionBinding]
        public init(id: PageID, name: String, bindings: [ControlID: ActionBinding] = [:]) {
            self.id = id
            self.name = name
            self.bindings = bindings
        }
    }
}

public struct SchemaEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let value: Value
    public init(schemaVersion: Int = 1, kind: String, value: Value) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.value = value
    }
}
