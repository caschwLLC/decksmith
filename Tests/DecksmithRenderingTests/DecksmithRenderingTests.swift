import XCTest
import Foundation
import ImageIO
@testable import DecksmithCore
@testable import DecksmithRendering

final class DecksmithRenderingTests: XCTestCase {
    func testRendererProducesDeterministicBytes() async throws {
        let update = SurfaceUpdate(surfaceID: SurfaceID(rawValue: "key.0"), revision: SurfaceRevision(1), presentation: .blank)
        let renderer = DeterministicRenderer()
        let first = try await renderer.render(update)
        let second = try await renderer.render(update)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.size, PixelSize(width: 120, height: 120))
        XCTAssertEqual(first.pixels.prefix(2), Data([0xff, 0xd8]))
    }

    func testRendererLoadsSVGImageAssets() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-renderer-\(UUID().uuidString).svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">
          <rect width="32" height="32" fill="#ff0000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let update = SurfaceUpdate(
            surfaceID: SurfaceID(rawValue: "touch.0"),
            revision: SurfaceRevision(1),
            presentation: .composite(layers: [
                .image(assetID: url.path, x: 0, y: 0, width: 32, height: 32)
            ])
        )
        let rendered = try await RasterSurfaceRenderer().render(update)
        XCTAssertGreaterThan(rendered.pixels.count, 100)
        XCTAssertEqual(rendered.pixels.prefix(2), Data([0xff, 0xd8]))
    }

    func testRendererDrawsImageOnlyPresentation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-renderer-\(UUID().uuidString).svg")
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">
          <rect width="32" height="32" fill="#ff0000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let update = SurfaceUpdate(
            surfaceID: SurfaceID(rawValue: "key.0"),
            revision: SurfaceRevision(1),
            presentation: .image(assetID: url.path)
        )
        let rendered = try await RasterSurfaceRenderer().render(update)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(rendered.pixels as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let provider = try XCTUnwrap(output.dataProvider)
        let data = try XCTUnwrap(provider.data as Data?)
        XCTAssertTrue(data.contains { $0 > 80 })
    }

    func testImageAssetNormalizerProducesDeviceSizedJPEG() throws {
        let source = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="16">
          <rect width="32" height="16" fill="#00ff00"/>
        </svg>
        """.utf8)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("decksmith-normalized-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }

        try ImageAssetNormalizer.normalize(
            data: source,
            to: destination,
            canvasSize: PixelSize(width: 200, height: 100)
        )

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 100)
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, "public.png")
    }
}
