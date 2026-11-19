import XCTest
@testable import DecksmithTransport

final class RealHardwareIntegrationTests: XCTestCase {
    func testConfiguredDeviceCanOpenAndClose() async throws {
        guard ProcessInfo.processInfo.environment["DECKSMITH_RUN_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set DECKSMITH_RUN_HARDWARE_TESTS=1 to enable real hardware validation.")
        }

        let environment = ProcessInfo.processInfo.environment
        guard
            let vendorValue = environment["DECKSMITH_VENDOR_ID"],
            let productValue = environment["DECKSMITH_PRODUCT_ID"],
            let vendorID = UInt16(vendorValue, radix: 16),
            let productID = UInt16(productValue, radix: 16)
        else {
            throw XCTSkip("Set DECKSMITH_VENDOR_ID and DECKSMITH_PRODUCT_ID as hexadecimal values.")
        }

        let transport = IOKitHIDTransport(
            vendorID: vendorID,
            productID: productID,
            serialNumber: environment["DECKSMITH_SERIAL_NUMBER"]
        )
        try await transport.open()
        let openState = await transport.state()
        XCTAssertEqual(openState, .open)
        await transport.close()
        let closedState = await transport.state()
        XCTAssertEqual(closedState, .closed)
    }
}
