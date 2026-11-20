import Foundation
import AppKit
import DecksmithCore
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public struct RenderedSurface: Sendable, Equatable {
    public let surfaceID: SurfaceID
    public let revision: SurfaceRevision
    public let pixels: Data
    public let size: PixelSize

    public init(surfaceID: SurfaceID, revision: SurfaceRevision, pixels: Data, size: PixelSize = PixelSize(width: 64, height: 64)) {
        self.surfaceID = surfaceID
        self.revision = revision
        self.pixels = pixels
        self.size = size
    }
}

public protocol SurfaceRenderer: Sendable {
    func render(_ update: SurfaceUpdate) async throws -> RenderedSurface
}

public enum RenderingError: Error, Equatable {
    case invalidSize
    case unsupportedImage
}

private enum ImageDecoder {
    static func decode(data: Data) -> CGImage? {
        if isSVG(data) {
            return decodeWithAppKit(data)
        }
        return CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            ?? decodeWithAppKit(data)
    }

    static func decode(url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data: data)
    }

    private static func decodeWithAppKit(_ data: Data) -> CGImage? {
        let nsImage = NSImage(data: data)
        var proposedRect = CGRect(origin: .zero, size: nsImage?.size ?? .zero)
        return nsImage?.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func isSVG(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<svg") { return true }
        guard trimmed.hasPrefix("<?xml"),
              let svgStart = trimmed.range(of: "<svg") else {
            return false
        }
        return trimmed.distance(from: trimmed.startIndex, to: svgStart.lowerBound) < 4096
    }
}

public enum ImageAssetNormalizer {
    public static func normalize(
        data: Data,
        to destinationURL: URL,
        canvasSize: PixelSize,
        removingNeutralBackground: Bool = false
    ) throws {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw RenderingError.invalidSize
        }

        let image = ImageDecoder.decode(data: data)
        guard let image else { throw RenderingError.unsupportedImage }

        var rgba = Data(count: canvasSize.width * canvasSize.height * 4)
        guard let context = rgba.withUnsafeMutableBytes({ rawBuffer -> CGContext? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return CGContext(
                data: baseAddress,
                width: canvasSize.width,
                height: canvasSize.height,
                bitsPerComponent: 8,
                bytesPerRow: canvasSize.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else {
            throw RenderingError.invalidSize
        }

        if ["jpg", "jpeg"].contains(destinationURL.pathExtension.lowercased()) {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height))
        } else {
            context.clear(CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height))
        }
        let scale = min(
            CGFloat(canvasSize.width) / CGFloat(image.width),
            CGFloat(canvasSize.height) / CGFloat(image.height)
        )
        let drawSize = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        let drawRect = CGRect(
            x: (CGFloat(canvasSize.width) - drawSize.width) / 2,
            y: (CGFloat(canvasSize.height) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        if removingNeutralBackground {
            removeNeutralBackground(from: &rgba, size: canvasSize)
        }

        let output = NSMutableData()
        let destinationType: CFString
        let properties: CFDictionary
        if ["jpg", "jpeg"].contains(destinationURL.pathExtension.lowercased()) {
            destinationType = UTType.jpeg.identifier as CFString
            properties = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        } else {
            destinationType = UTType.png.identifier as CFString
            properties = [:] as CFDictionary
        }
        guard let destinationImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                output,
                destinationType,
                1,
                nil
              ) else {
            throw RenderingError.invalidSize
        }
        CGImageDestinationAddImage(destination, destinationImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderingError.invalidSize
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try output.write(to: destinationURL, options: .atomic)
    }

    private static func removeNeutralBackground(from rgba: inout Data, size: PixelSize) {
        var histogram: [UInt16: Int] = [:]
        rgba.withUnsafeBytes { rawBuffer in
            let pixels = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<(size.width * size.height) {
                let offset = index * 4
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let alpha = pixels[offset + 3]
                guard alpha > 0,
                      max(red, green, blue) - min(red, green, blue) <= 4,
                      red >= 32,
                      red <= 128 else { continue }
                let key = UInt16(red / 4)
                histogram[key, default: 0] += 1
            }
        }
        guard let background = histogram.max(by: { $0.value < $1.value })?.key else { return }
        let target = UInt8(background * 4)
        rgba.withUnsafeMutableBytes { rawBuffer in
            let pixels = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<(size.width * size.height) {
                let offset = index * 4
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                guard max(red, green, blue) - min(red, green, blue) <= 8,
                      abs(Int(red) - Int(target)) <= 10,
                      abs(Int(green) - Int(target)) <= 10,
                      abs(Int(blue) - Int(target)) <= 10 else { continue }
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 0
            }
        }
    }
}

public struct DeterministicRenderer: SurfaceRenderer {
    public init() {}

    public func render(_ update: SurfaceUpdate) async throws -> RenderedSurface {
        try await RasterSurfaceRenderer().render(update)
    }
}

public struct RasterSurfaceRenderer: SurfaceRenderer {
    public let size: PixelSize?

    public init(size: PixelSize? = nil) {
        self.size = size
    }

    public func render(_ update: SurfaceUpdate) async throws -> RenderedSurface {
        let size = size ?? defaultSize(for: update.surfaceID)
        guard size.width > 0, size.height > 0 else { throw RenderingError.invalidSize }
        let seed = (16 as UInt8, 18 as UInt8, 24 as UInt8)
        var rgba = Data(count: size.width * size.height * 4)
        rgba.withUnsafeMutableBytes { rawBuffer in
            guard let buffer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<(size.width * size.height) {
                let offset = index * 4
                buffer[offset] = seed.0
                buffer[offset + 1] = seed.1
                buffer[offset + 2] = seed.2
                buffer[offset + 3] = 0xff
            }
        }
        draw(presentation: update.presentation, into: &rgba, size: size)
        return RenderedSurface(
            surfaceID: update.surfaceID,
            revision: update.revision,
            pixels: try jpegData(rgba: rgba, size: size),
            size: size
        )
    }

    private func defaultSize(for surfaceID: SurfaceID) -> PixelSize {
        surfaceID.rawValue.hasPrefix("key.") ? PixelSize(width: 120, height: 120) : PixelSize(width: 800, height: 100)
    }

    private func jpegData(rgba: Data, size: PixelSize) throws -> Data {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: size.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw RenderingError.invalidSize
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw RenderingError.invalidSize
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderingError.invalidSize }
        return output as Data
    }

    private func draw(presentation: SurfacePresentation, into rgba: inout Data, size: PixelSize) {
        rgba.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: size.width,
                    height: size.height,
                    bitsPerComponent: 8,
                    bytesPerRow: size.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }

            context.interpolationQuality = .high
            context.setBlendMode(.normal)
            switch presentation {
            case .blank:
                break
            case .text(let title, let subtitle):
                drawText(title, at: CGPoint(x: 12, y: CGFloat(size.height) - 34), fontSize: min(22, CGFloat(size.height) / 4), in: context)
                if let subtitle {
                    drawText(subtitle, at: CGPoint(x: 12, y: CGFloat(size.height) - 62), fontSize: min(14, CGFloat(size.height) / 7), in: context)
                }
            case .image(let assetID):
                drawImage(
                    at: assetID,
                    rect: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                    in: context
                )
            case .composite(let layers):
                for layer in layers {
                    if case .image(let assetID, let x, let y, let width, let height) = layer {
                        drawImage(
                            at: assetID,
                            rect: CGRect(
                                x: x,
                                y: CGFloat(size.height) - y - height,
                                width: width,
                                height: height
                            ),
                            in: context
                        )
                    } else if case .text(let value, let x, let y, _, _) = layer {
                        let fontSize = min(16, max(11, CGFloat(size.height) / 7))
                        drawText(value, at: CGPoint(x: x, y: CGFloat(size.height) - y - 18), fontSize: fontSize, in: context)
                    } else if case .progress(let value, let x, let y, let width, let height) = layer {
                        drawProgress(
                            value: value,
                            rect: CGRect(
                                x: x,
                                y: CGFloat(size.height) - y - height,
                                width: width,
                                height: height
                            ),
                            in: context
                        )
                    }
                }
            }
        }
    }

    private func drawText(_ value: String, at point: CGPoint, fontSize: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        context.saveGState()
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawImage(at path: String, rect: CGRect, in context: CGContext) {
        let url = URL(fileURLWithPath: path)
        let image = ImageDecoder.decode(url: url)
        guard let image else { return }
        context.saveGState()
        context.interpolationQuality = .high
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawSize = CGSize(
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.draw(image, in: drawRect)
        context.restoreGState()
    }

    private func drawProgress(value: Double, rect: CGRect, in context: CGContext) {
        let clamped = min(max(value, 0), 1)
        context.saveGState()
        let radius = min(rect.height / 2, 4)
        let background = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.setFillColor(CGColor(gray: 0.22, alpha: 0.9))
        context.addPath(background)
        context.fillPath()
        guard clamped > 0 else {
            context.restoreGState()
            return
        }
        let fillRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width * clamped,
            height: rect.height
        )
        let fill = CGPath(
            roundedRect: fillRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 1, alpha: 0.95))
        context.addPath(fill)
        context.fillPath()
        context.restoreGState()
    }

}
