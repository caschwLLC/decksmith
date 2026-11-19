import XCTest
@testable import DecksmithPluginWebSocket

final class DecksmithPluginWebSocketTests: XCTestCase {
    func testExternalLaunchUsesOfficialRegistrationEventByDefault() {
        let configuration = ExternalPluginLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/tmp/plugin.js"),
            pluginID: .init(rawValue: "com.example.plugin"),
            port: 28196
        )
        XCTAssertEqual(configuration.registerEvent, "registerPlugin")
    }

    func testOfficialEnvelopeDecodes() throws {
        let data = Data(#"{"event":"keyDown","context":"ctx","payload":{"state":"0"}}"#.utf8)
        let envelope = try OfficialPluginAdapter().decode(data)
        XCTAssertEqual(envelope.event, "keyDown")
        XCTAssertEqual(envelope.context, "ctx")
    }

    func testOfficialEnvelopePreservesNestedPayloadValues() throws {
        let data = Data(#"{"event":"didReceiveSettings","payload":{"settings":{"mode":"focus"},"coordinates":{"column":1}}}"#.utf8)
        let envelope = try OfficialPluginAdapter().decode(data)
        guard case let .object(settings)? = envelope.payload["settings"] else {
            return XCTFail("Expected nested settings object")
        }
        XCTAssertEqual(settings["mode"], .string("focus"))
        XCTAssertEqual(envelope.payload["coordinates"], .object(["column": .number(1)]))
    }
}
