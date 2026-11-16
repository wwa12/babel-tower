import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

/// 预处理完成、可直接进请求体的图片。
struct ProcessedImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

/// 图片本地预处理（图片预处理模块）：
/// - 解码任意来源（位图数据 / 图片文件），GIF 取首帧；
/// - 按 EXIF 方向摆正（iPhone 竖拍照片像素是横的，靠方向标记显示为竖图）；
/// - 长边缩到 2,000px 以内（只缩不放，保等比）——长边约束后高度同被约束，无需长图切片；
/// - 透明通道输出 PNG，不透明输出高质量 JPEG；
/// - 解码失败返回 nil，由上层提示「无法读取这张图片」。
enum ImagePreprocessor {

    static func process(data: Data) -> ProcessedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return process(source: source)
    }

    static func process(fileURL url: URL) -> ProcessedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return process(source: source)
    }

    /// 取第 0 帧（GIF 一律取第一帧），按 EXIF 方向摆正，并直接解码到长边 ≤2000：
    /// 用 ImageIO 缩略图接口一步完成，大图（如 4800 万像素 HEIC）不必先全尺寸解码再缩放。
    private static func process(source: CGImageSource) -> ProcessedImage? {
        // 只取尺寸与透明信息（CGImage 惰性解码，这一步不解像素）
        guard CGImageSourceGetCount(source) > 0,
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 应用 EXIF 方向
            kCGImageSourceShouldCacheImmediately: true,
            // 只缩不放
            kCGImageSourceThumbnailMaxPixelSize: min(max(raw.width, raw.height),
                                                     Int(BehaviorConstants.imageMaxLongEdge)),
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return process(cgImage: raw)
        }
        return process(cgImage: upright, hasAlpha: hasAlpha(raw))
    }

    /// 透明判定必须看原图：缩放 / 摆正画布的固定格式会改变 alpha 信息，
    /// 不透明的大图（截图常见）会被误判成带透明而输出 PNG
    private static func hasAlpha(_ image: CGImage) -> Bool {
        image.alphaInfo != .none && image.alphaInfo != .noneSkipLast
            && image.alphaInfo != .noneSkipFirst
    }

    private static func process(cgImage: CGImage, hasAlpha knownAlpha: Bool? = nil) -> ProcessedImage? {
        var image = cgImage
        let hasAlpha = knownAlpha ?? Self.hasAlpha(image)

        let longEdge = max(image.width, image.height)
        let limit = Int(BehaviorConstants.imageMaxLongEdge)
        if longEdge > limit {
            // 等比缩到长边 2000（只缩不放）；画布格式跟随原图是否带透明
            let scale = CGFloat(limit) / CGFloat(longEdge)
            let width = max(1, Int(CGFloat(image.width) * scale))
            let height = max(1, Int(CGFloat(image.height) * scale))
            guard let resized = resize(image, toWidth: width, height: height, keepingAlpha: hasAlpha) else {
                return nil
            }
            image = resized
        }

        if hasAlpha {
            guard let png = encode(image, type: .png) else { return nil }
            return ProcessedImage(data: png, mimeType: "image/png")
        }
        guard let jpeg = encode(image, type: .jpeg) else { return nil }
        return ProcessedImage(data: jpeg, mimeType: "image/jpeg")
    }

    /// 纯 CoreGraphics 缩放：不依赖窗口服务的图形上下文，线程安全（预算内）。
    private static func resize(_ image: CGImage, toWidth width: Int, height: Int,
                               keepingAlpha: Bool) -> CGImage? {
        let alphaInfo: CGImageAlphaInfo = keepingAlpha ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: alphaInfo.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: NSBitmapImageRep.FileType) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        let properties: [NSBitmapImageRep.PropertyKey: Any] =
            type == .jpeg ? [.compressionFactor: 0.85] : [:]   // 高质量 JPEG
        return rep.representation(using: type, properties: properties)
    }
}
