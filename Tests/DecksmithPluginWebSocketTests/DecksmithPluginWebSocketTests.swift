import XCTest
@testable import DecksmithPluginWebSocket

final class DecksmithPluginWebSocketTests: XCTestCase {
    func testOfficialEnvelopeDecodes() throws {
        let data = Data(#"{"event":"keyDown","context":"ctx","payload":{"state":"0"}}"#.utf8)
        let envelope = try OfficialPluginAdapter().decode(data)
        XCTAssertEqual(envelope.event, "keyDown")
        XCTAssertEqual(envelope.context, "ctx")
    }
}
