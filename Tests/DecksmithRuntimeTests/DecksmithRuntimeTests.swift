import XCTest
@testable import DecksmithCore
@testable import DecksmithRuntime

final class DecksmithRuntimeTests: XCTestCase {
    func testRuntimeCanBeConstructed() {
        _ = PluginRuntime()
    }
}
