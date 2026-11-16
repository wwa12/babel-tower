import XCTest
import AppKit
@testable import BabelTower

/// 图片本地预处理：
/// 长边 ≤2000px（不放大）、GIF 取首帧、透明→PNG / 不透明→高质量 JPEG、解码失败返回 nil。
final class ImagePreprocessorTests: XCTestCase {

    /// 生成指定像素尺寸的纯色位图数据（CoreGraphics 直接绘制，无窗口服务依赖）。
    private func makeImageData(width: Int, height: Int, color: NSColor = .red, alpha: Bool = false) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: alphaInfo.rawValue
        ))
        let fill = color.cgColor.copy(alpha: alpha ? 0.5 : 1.0) ?? NSColor.red.cgColor
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func dimensions(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    func testLargeImageDownscaledTo2000LongEdge() throws {
        let input = try makeImageData(width: 4000, height: 1000)
        let output = try XCTUnwrap(ImagePreprocessor.process(data: input))
        let size = try XCTUnwrap(dimensions(of: output.data))
        XCTAssertEqual(max(size.width, size.height), BehaviorConstants.imageMaxLongEdge, accuracy: 2,
                       "长边应恰为 2000")
        XCTAssertLessThanOrEqual(max(size.width, size.height), BehaviorConstants.imageMaxLongEdge)
        // 宽高等比：原比例 4:1
        XCTAssertEqual(size.width / size.height, 4, accuracy: 0.05)
    }

    /// 钉住用例：超过 2000px 的不透明图（截图场景）应输出 JPEG 而非 PNG。
    func testLargeOpaqueImageEncodesJPEG() throws {
        let input = try makeImageData(width: 4000, height: 1000)
        let output = try XCTUnwrap(ImagePreprocessor.process(data: input))
        XCTAssertEqual(output.mimeType, "image/jpeg")
    }

    func testSmallImageNotUpscaled() throws {
        let input = try makeImageData(width: 300, height: 200)
        let output = try XCTUnwrap(ImagePreprocessor.process(data: input))
        let size = try XCTUnwrap(dimensions(of: output.data))
        XCTAssertEqual(size.width, 300, accuracy: 2)
        XCTAssertEqual(size.height, 200, accuracy: 2)
    }

    func testOpaqueImageEncodesJPEG() throws {
        let input = try makeImageData(width: 100, height: 100)
        let output = try XCTUnwrap(ImagePreprocessor.process(data: input))
        XCTAssertEqual(output.mimeType, "image/jpeg")
        XCTAssertEqual(Array(output.data.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG 魔数")
    }

    func testImageWithAlphaEncodesPNG() throws {
        let input = try makeImageData(width: 100, height: 100, alpha: true)
        let output = try XCTUnwrap(ImagePreprocessor.process(data: input))
        XCTAssertEqual(output.mimeType, "image/png")
    }

    /// GIF 取首帧：两帧同尺寸不同色（蓝→黄），输出中心像素为蓝即证明取首帧。
    func testGIFUsesFirstFrame() throws {
        let frame1 = try makeImageData(width: 64, height: 64, color: .blue)
        let frame2 = try makeImageData(width: 64, height: 64, color: .yellow)
        let output = try XCTUnwrap(ImagePreprocessor.process(data: try makeGIF(frames: [frame1, frame2])))
        // 输出为 PNG/JPEG 单帧，不再是 GIF
        XCTAssertTrue(output.mimeType == "image/png" || output.mimeType == "image/jpeg")
        let pixel = try XCTUnwrap(centerPixel(of: output.data))
        // 蓝帧：蓝通道显著高、红通道显著低（JPEG 压缩留余量）
        XCTAssertGreaterThan(pixel.blue, 150, "首帧应为蓝色：\(pixel)")
        XCTAssertLessThan(pixel.red, 100, "不应取到黄色第二帧：\(pixel)")
    }

    /// 解码数据并取中心像素（RGBA）。
    private func centerPixel(of data: Data) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let offset = (height / 2 * width + width / 2) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    func testUndecodableDataReturnsNil() {
        XCTAssertNil(ImagePreprocessor.process(data: Data("这不是图片".utf8)))
        XCTAssertNil(ImagePreprocessor.process(data: Data()))
    }

    /// 预处理预算：常规尺寸应在 100ms 内（超大图的实际手感需真机确认）。
    func testSmallImageWithinBudget() throws {
        let input = try makeImageData(width: 3000, height: 2000)
        let start = CFAbsoluteTimeGetCurrent()
        _ = try XCTUnwrap(ImagePreprocessor.process(data: input))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, BehaviorConstants.imagePreprocessBudget * 3,
                          "3000×2000 压缩应远快于 100ms 预算（留 3 倍 CI 余量）")
    }

    private func makeGIF(frames: [Data]) throws -> Data {
        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData, UTType.gif.identifier as CFString, frames.count, nil
        ) else {
            throw XCTSkip("无法创建 GIF 目标")
        }
        for frame in frames {
            guard let source = CGImageSourceCreateWithData(frame as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw XCTSkip("帧解码失败")
            }
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("GIF 写入失败")
        }
        return destinationData as Data
    }
}

import UniformTypeIdentifiers
