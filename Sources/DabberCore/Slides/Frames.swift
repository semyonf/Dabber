import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FrameError: Error, CustomStringConvertible {
    case draw
    case encode
    case decode(String)

    public var description: String {
        switch self {
        case .draw: return "could not draw frame"
        case .encode: return "could not encode frame"
        case .decode(let file): return "\(file): could not decode frame"
        }
    }
}

public enum Frames {
    public static let maxWidth = 1920
    public static let quality = 0.8
    static let thumbWidth = 64
    static let thumbHeight = 36
    static let pixelDelta = 24
    static let changedPixels = 4

    public static func fitSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = min(width, maxWidth)
        let h = Int((Double(height) * Double(w) / Double(width)).rounded())
        return (max(2, w & ~1), max(2, h & ~1))
    }

    public static func scaled(_ image: CGImage) throws -> CGImage {
        let size = fitSize(width: image.width, height: image.height)
        if size.width == image.width, size.height == image.height { return image }
        return try draw(image, width: size.width, height: size.height)
    }

    public static func draw(_ image: CGImage?, width: Int, height: Int) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw FrameError.draw }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let image {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: fit(image, width: width, height: height))
        }
        guard let out = ctx.makeImage() else { throw FrameError.draw }
        return out
    }

    static func fit(_ image: CGImage, width: Int, height: Int) -> CGRect {
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
    }

    public static func thumbnail(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: thumbWidth * thumbHeight)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8,
                bytesPerRow: thumbWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
            return true
        }
        guard drawn else { throw FrameError.draw }
        return pixels
    }

    public static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        zip(a, b).count { abs(Int($0) - Int($1)) > pixelDelta } >= changedPixels
    }

    public static func heic(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw FrameError.encode
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FrameError.encode }
        return data as Data
    }

    public static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FrameError.decode(url.lastPathComponent) }
        return image
    }
}

public final class FrameSampler {
    private var last: (display: UInt32, thumb: [UInt8])?

    public init() {}

    public func offer(_ image: CGImage, display: UInt32) throws -> Data? {
        let frame = try Frames.scaled(image)
        let thumb = try Frames.thumbnail(frame)
        if let last, last.display == display, !Frames.changed(last.thumb, thumb) { return nil }
        let data = try Frames.heic(frame)
        last = (display, thumb)
        return data
    }
}
