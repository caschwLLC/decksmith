import Foundation
import IOKit.hid

public enum TransportReportType: Sendable, Equatable {
    case output
    case feature
}

public struct TransportPacket: Sendable, Equatable {
    public let bytes: Data
    public let timestamp: Date
    public let reportType: TransportReportType
    public init(
        bytes: Data,
        reportType: TransportReportType = .output,
        timestamp: Date = .now
    ) {
        self.bytes = bytes
        self.timestamp = timestamp
        self.reportType = reportType
    }
}

public struct HIDDeviceDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let serialNumber: String?

    public init(id: String, name: String, vendorID: UInt16, productID: UInt16, serialNumber: String? = nil) {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }
}

public enum IOKitHIDDiscovery {
    public static func devices(vendorID: UInt16? = nil) -> [HIDDeviceDescriptor] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var matching: [String: Any] = [:]
        if let vendorID {
            matching[kIOHIDVendorIDKey as String] = Int(vendorID)
        }
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else { return [] }

        let count = CFSetGetCount(deviceSet)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(deviceSet, &values)
        return values.compactMap { pointer -> HIDDeviceDescriptor? in
            guard let pointer else { return nil }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
            guard
                let vendor = property(device, key: kIOHIDVendorIDKey as CFString) as? NSNumber,
                let product = property(device, key: kIOHIDProductIDKey as CFString) as? NSNumber
            else {
                return nil
            }
            let vendorID = vendor.uint16Value
            let productID = product.uint16Value
            let serial = property(device, key: kIOHIDSerialNumberKey as CFString) as? String
            let name = (property(device, key: kIOHIDProductKey as CFString) as? String) ?? "HID device"
            let id = "\(vendorID)-\(productID)-\(serial ?? String(describing: ObjectIdentifier(device)))"
            return HIDDeviceDescriptor(
                id: id,
                name: name,
                vendorID: vendorID,
                productID: productID,
                serialNumber: serial
            )
        }
    }

    private static func property(_ device: IOHIDDevice, key: CFString) -> Any? {
        IOHIDDeviceGetProperty(device, key)
    }
}

public enum TransportState: Sendable, Equatable {
    case closed
    case opening
    case open
    case closing
    case failed(String)
}

public protocol HIDTransport: Sendable {
    func packets() async -> AsyncStream<TransportPacket>
    func open() async throws
    func close() async
    func write(_ packet: TransportPacket) async throws
    func state() async -> TransportState
}

public actor InMemoryTransport: HIDTransport {
    private var currentState: TransportState = .closed
    private var continuation: AsyncStream<TransportPacket>.Continuation?
    private var writes: [TransportPacket] = []

    public init() {}

    public func packets() async -> AsyncStream<TransportPacket> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func open() async throws { currentState = .open }
    public func close() async { currentState = .closed; continuation?.finish() }
    public func write(_ packet: TransportPacket) async throws {
        guard currentState == .open else { throw TransportError.notOpen }
        writes.append(packet)
    }
    public func state() async -> TransportState { currentState }
    public func emit(_ packet: TransportPacket) { continuation?.yield(packet) }
    public func recordedWrites() -> [TransportPacket] { writes }
}

public actor IOKitHIDTransport: HIDTransport {
    private let vendorID: UInt16
    private let productID: UInt16
    private let serialNumber: String?
    private let callbackBridge: HIDCallbackBridge
    private let runLoop: CFRunLoop = CFRunLoopGetMain()!

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var matchedDevice: IOHIDDevice?
    private var currentState: TransportState = .closed
    private var continuation: AsyncStream<TransportPacket>.Continuation?

    public init(vendorID: UInt16, productID: UInt16, serialNumber: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.callbackBridge = HIDCallbackBridge()
        self.callbackBridge.owner = self
    }

    public func packets() async -> AsyncStream<TransportPacket> {
        continuation?.finish()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.clearContinuation() }
            }
        }
    }

    public func open() async throws {
        if currentState != .closed {
            if case .failed = currentState {
                currentState = .closed
            } else {
                return
            }
        }

        currentState = .opening
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Int(vendorID),
            kIOHIDProductIDKey as String: Int(productID)
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            hidDeviceMatchingCallback,
            Unmanaged.passUnretained(callbackBridge).toOpaque()
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            hidDeviceRemovalCallback,
            Unmanaged.passUnretained(callbackBridge).toOpaque()
        )
        self.manager = manager
        IOHIDManagerScheduleWithRunLoop(
            manager,
            runLoop,
            CFRunLoopMode.defaultMode.rawValue as CFString
        )
        CFRunLoopWakeUp(runLoop)
        let deadline = ContinuousClock.now + .seconds(5)
        while device == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard device != nil else {
            currentState = .failed("No matching HID device was opened")
            throw TransportError.deviceUnavailable
        }
        currentState = .open
    }

    public func close() async {
        guard currentState != .closed else { return }
        currentState = .closing
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                runLoop,
                CFRunLoopMode.defaultMode.rawValue as CFString
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                runLoop,
                CFRunLoopMode.defaultMode.rawValue as CFString
            )
        }
        device = nil
        matchedDevice = nil
        manager = nil
        continuation?.finish()
        continuation = nil
        currentState = .closed
    }

    public func write(_ packet: TransportPacket) async throws {
        guard currentState == .open else { throw TransportError.notOpen }
        guard let device else { throw TransportError.deviceUnavailable }

        let bytes = [UInt8](packet.bytes)
        let reportID = bytes.first ?? 0
        let type: IOHIDReportType = packet.reportType == .feature
            ? kIOHIDReportTypeFeature
            : kIOHIDReportTypeOutput
        let result = setReport(
            device: device,
            type: type,
            reportID: reportID,
            bytes: bytes,
            length: bytes.count
        )
        if result == kIOReturnTimeout, packet.reportType == .output, bytes.count > 1 {
            let fullReportResult = setReport(
                device: device,
                type: type,
                reportID: reportID,
                bytes: bytes,
                length: bytes.count - 1
            )
            if fullReportResult == kIOReturnSuccess {
                return
            }
            let payload = Array(bytes.dropFirst())
            let retryResult = setReport(
                device: device,
                type: type,
                reportID: reportID,
                bytes: payload,
                length: payload.count
            )
            guard retryResult == kIOReturnSuccess else {
                throw TransportError.writeFailed(retryResult)
            }
            return
        }
        guard result == kIOReturnSuccess else {
            throw TransportError.writeFailed(result)
        }
    }

    public func state() async -> TransportState { currentState }

    private func setReport(
        device: IOHIDDevice,
        type: IOHIDReportType,
        reportID: UInt8,
        bytes: [UInt8],
        length: Int
    ) -> IOReturn {
        bytes.withUnsafeBytes { buffer in
            IOHIDDeviceSetReport(
                device,
                type,
                CFIndex(reportID),
                buffer.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(bitPattern: 1)!,
                length
            )
        }
    }

    private func clearContinuation() {
        continuation = nil
    }

    func receive(reportID: UInt32, bytes: Data) {
        guard currentState == .open else { return }
        let id = UInt8(truncatingIfNeeded: reportID)
        let fullReport = bytes.first == id ? bytes : Data([id]) + bytes
        continuation?.yield(TransportPacket(bytes: fullReport))
    }

    fileprivate func didMatch(device reference: HIDDeviceReference) {
        let matchedDevice = reference.raw
        guard self.device == nil else { return }
        if let serialNumber, let deviceSerial = IOHIDDeviceGetProperty(matchedDevice, kIOHIDSerialNumberKey as CFString) as? String,
           deviceSerial != serialNumber {
            return
        }
        let service = IOHIDDeviceGetService(matchedDevice)
        guard service != 0,
              let openedDevice = IOHIDDeviceCreate(kCFAllocatorDefault, service)
        else {
            currentState = .failed("IOHIDDeviceCreate failed")
            return
        }
        let result = IOHIDDeviceOpen(openedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            currentState = .failed("IOHIDDeviceOpen failed: \(result)")
            return
        }
        self.device = openedDevice
        self.matchedDevice = matchedDevice
        IOHIDDeviceScheduleWithRunLoop(
            openedDevice,
            runLoop,
            CFRunLoopMode.defaultMode.rawValue as CFString
        )
        IOHIDDeviceRegisterInputReportCallback(
            openedDevice,
            callbackBridge.reportBuffer,
            HIDCallbackBridge.reportBufferSize,
            hidInputReportCallback,
            Unmanaged.passUnretained(callbackBridge).toOpaque()
        )
        CFRunLoopWakeUp(runLoop)
    }

    fileprivate func didRemove(device reference: HIDDeviceReference) {
        guard matchedDevice === reference.raw else { return }
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(
                device,
                runLoop,
                CFRunLoopMode.defaultMode.rawValue as CFString
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        self.device = nil
        self.matchedDevice = nil
    }
}

private final class HIDCallbackBridge: @unchecked Sendable {
    static let reportBufferSize = 16_384
    weak var owner: IOKitHIDTransport?
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)

    deinit {
        reportBuffer.deallocate()
    }

    func receive(reportID: UInt32, bytes: Data) {
        guard let owner else { return }
        Task { await owner.receive(reportID: reportID, bytes: bytes) }
    }

    func match(device: IOHIDDevice) {
        guard let owner else { return }
        let reference = HIDDeviceReference(raw: device)
        Task { await owner.didMatch(device: reference) }
    }

    func remove(device: IOHIDDevice) {
        guard let owner else { return }
        let reference = HIDDeviceReference(raw: device)
        Task { await owner.didRemove(device: reference) }
    }
}

fileprivate final class HIDDeviceReference: @unchecked Sendable {
    let raw: IOHIDDevice

    init(raw: IOHIDDevice) {
        self.raw = raw
    }
}

private let hidInputReportCallback: IOHIDReportCallback = {
    context, _, _, _, reportID, report, reportLength in
    guard let context else { return }
    let bridge = Unmanaged<HIDCallbackBridge>.fromOpaque(context).takeUnretainedValue()
    bridge.receive(reportID: reportID, bytes: Data(bytes: report, count: reportLength))
}

private let hidDeviceMatchingCallback: IOHIDDeviceCallback = {
    context, _, _, sender in
    guard let context else { return }
    let bridge = Unmanaged<HIDCallbackBridge>.fromOpaque(context).takeUnretainedValue()
    bridge.match(device: sender)
}

private let hidDeviceRemovalCallback: IOHIDDeviceCallback = {
    context, _, _, sender in
    guard let context else { return }
    let bridge = Unmanaged<HIDCallbackBridge>.fromOpaque(context).takeUnretainedValue()
    bridge.remove(device: sender)
}

public enum TransportError: Error, Equatable {
    case notOpen
    case managerOpenFailed(IOReturn)
    case deviceUnavailable
    case writeFailed(IOReturn)
}

extension TransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notOpen:
            return "HID transport is not open"
        case .managerOpenFailed(let status):
            return "IOHIDManagerOpen failed: \(Self.statusDescription(status))"
        case .deviceUnavailable:
            return "No matching HID device is open"
        case .writeFailed(let status):
            return "HID write failed: \(Self.statusDescription(status))"
        }
    }

    private static func statusDescription(_ status: IOReturn) -> String {
        let name: String
        switch status {
        case kIOReturnTimeout:
            name = "kIOReturnTimeout"
        case kIOReturnNotOpen:
            name = "kIOReturnNotOpen"
        case kIOReturnNotWritable:
            name = "kIOReturnNotWritable"
        case kIOReturnBusy:
            name = "kIOReturnBusy"
        case kIOReturnOffline:
            name = "kIOReturnOffline"
        default:
            name = "unknown"
        }
        return "\(name) (0x\(String(UInt32(bitPattern: status), radix: 16)))"
    }
}

public struct TransportMetrics: Sendable, Equatable {
    public private(set) var receivedPackets = 0
    public private(set) var droppedPackets = 0
    public private(set) var writtenPackets = 0
    public init() {}
    public mutating func recordReceived() { receivedPackets += 1 }
    public mutating func recordDropped() { droppedPackets += 1 }
    public mutating func recordWritten() { writtenPackets += 1 }
}

public actor BoundedPacketBuffer {
    private let capacity: Int
    private var packets: [TransportPacket] = []
    private var metrics = TransportMetrics()

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func append(_ packet: TransportPacket) {
        metrics.recordReceived()
        if packets.count == capacity {
            packets.removeFirst()
            metrics.recordDropped()
        }
        packets.append(packet)
    }

    public func drain() -> [TransportPacket] {
        defer { packets.removeAll(keepingCapacity: true) }
        return packets
    }

    public func snapshotMetrics() -> TransportMetrics { metrics }
}
