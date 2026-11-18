import Foundation
import DecksmithCore

public struct RenderedSurface: Sendable, Equatable {
    public let surfaceID: SurfaceID
    public let revision: SurfaceRevision
    public let pixels: Data
    public init(surfaceID: SurfaceID, revision: SurfaceRevision, pixels: Data) {
        self.surfaceID = surfaceID
        self.revision = revision
        self.pixels = pixels
    }
}

public protocol SurfaceRenderer: Sendable {
    func render(_ update: SurfaceUpdate) async throws -> RenderedSurface
}

public struct DeterministicRenderer: SurfaceRenderer {
    public init() {}
    public func render(_ update: SurfaceUpdate) async throws -> RenderedSurface {
        RenderedSurface(surfaceID: update.surfaceID, revision: update.revision, pixels: Data(update.surfaceID.rawValue.utf8))
    }
}
