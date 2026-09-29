import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DabberCore

func screen(width: Int = 1920, height: Int = 1080, gray: CGFloat = 1, rects: [CGRect] = []) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(gray: 1 - gray, alpha: 1))
    for r in rects { ctx.fill(r) }
    return ctx.makeImage()!
}

@Test func framesKeepTheirSizeUpTo3456WideWithEvenSides() {
    #expect(Frames.fitSize(width: 2560, height: 1664) == (2560, 1664))
    #expect(Frames.fitSize(width: 5120, height: 2880) == (3456, 1944))
    #expect(Frames.fitSize(width: 1440, height: 900) == (1440, 900))
    #expect(Frames.fitSize(width: 3456, height: 2234) == (3456, 2234))
    #expect(Frames.fitSize(width: 1001, height: 601) == (1000, 600))
}

@Test func largeScreensAreScaledDown() throws {
    let big = try Frames.scaled(screen(width: 5120, height: 2880))
    #expect((big.width, big.height) == (3456, 1944))
    let small = screen(width: 1440, height: 900)
    #expect(try Frames.scaled(small) === small)
}

@Test func caretSizedChangesDoNotCountButContentDoes() throws {
    let base = try Frames.thumbnail(screen())
    #expect(!Frames.changed(base, base))
    #expect(!Frames.changed(base, try Frames.thumbnail(screen(rects: [CGRect(x: 900, y: 500, width: 2, height: 20)]))))
    #expect(!Frames.changed(base, try Frames.thumbnail(screen(rects: [CGRect(x: 1800, y: 1062, width: 60, height: 12)]))))
    #expect(Frames.changed(base, try Frames.thumbnail(screen(rects: [CGRect(x: 200, y: 200, width: 400, height: 300)]))))
    #expect(Frames.changed(base, try Frames.thumbnail(screen(gray: 0))))
}

@Test func heicRoundTripKeepsTheSize() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("f-\(UUID().uuidString).heic")
    let data = try Frames.heic(screen(rects: [CGRect(x: 100, y: 100, width: 300, height: 200)]))
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    #expect(CGImageSourceGetType(source) as String? == "public.heic")
    try data.write(to: url)
    let back = try Frames.decode(url)
    #expect((back.width, back.height) == (1920, 1080))
    #expect(throws: FrameError.self) { try Frames.decode(URL(fileURLWithPath: "/nonexistent.heic")) }
}

@Test func samplerKeepsOnlyChangedFramesAndDisplaySwitches() throws {
    let s = FrameSampler()
    #expect(try s.offer(screen(), display: 1) != nil)
    #expect(try s.offer(screen(), display: 1) == nil)
    #expect(try s.offer(screen(rects: [CGRect(x: 900, y: 500, width: 2, height: 20)]), display: 1) == nil)
    #expect(try s.offer(screen(), display: 2) != nil)
    #expect(try s.offer(screen(gray: 0), display: 2) != nil)
    #expect(try s.offer(screen(gray: 0, rects: [CGRect(x: 1800, y: 1062, width: 60, height: 12)]), display: 2) == nil)
}
