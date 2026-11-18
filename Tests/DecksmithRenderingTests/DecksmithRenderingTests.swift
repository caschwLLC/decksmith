import XCTest
@testable import DecksmithCore
@testable import DecksmithRendering

final class DecksmithRenderingTests: XCTestCase {
    func testRendererProducesDeterministicBytes() async throws {
        let update = SurfaceUpdate(surfaceID: SurfaceID(rawValue: "key.0"), revision: SurfaceRevision(1), presentation: .blank)
        let rendered = try await DeterministicRenderer().render(update)
        XCTAssertEqual(rendered.pixels, Data("key.0".utf8))
    }
}
