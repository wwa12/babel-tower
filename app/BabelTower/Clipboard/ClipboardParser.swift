import Foundation
import AppKit

/// 剪贴板解析结果。解析顺序：图片文件 → 位图 → 纯文本。
enum ClipboardContent: Equatable {
    /// 访达中复制 / 拖动的图片文件（PNG / JPEG / HEIC / WebP / GIF）
    case imageFiles([URL])
    /// 剪贴板位图数据（截图、应用内复制的图像）
    case imageBitmap(Data)
    /// 纯文本（富文本只保留纯文本部分）
    case plainText(String)
}

/// 剪贴板内容解析（纯读取函数）。GIF 取首帧在图片预处理（ImagePreprocessor）里做，
/// 这里只负责识别与按优先级取出。空剪贴板与非图文类型返回 nil，不报错。
///
/// 优先级：图片文件 → （文字与位图并存时）文字 → 位图 → 文字。
/// - 复制的是文件但没有一个是支持的图片：无反应（内容不是文字和图片）。访达此时还会附带
///   文件图标位图和文件名文字，图标不是待翻译内容，文件名也不是；
/// - Office / Numbers 等复制文字时常附带一张图片预览：文字与位图并存时按文字翻译；
///   例外是文字只有一个网址 / 路径（浏览器"拷贝图像"附带图片地址），此时按图片翻译。
enum ClipboardParser {

    /// 图片文件扩展名白名单（大小写不敏感）。
    static let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]

    static func parse(_ pasteboard: NSPasteboard) -> ClipboardContent? {
        // 1) 图片文件：访达复制的一组文件里筛白名单扩展
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        let imageFiles = fileURLs.filter {
            imageFileExtensions.contains($0.pathExtension.lowercased())
        }
        if !imageFiles.isEmpty {
            return .imageFiles(imageFiles)
        }
        if !fileURLs.isEmpty {
            return nil
        }

        // string(forType:) 自动剥离富文本样式，只留文字与换行
        let text = pasteboard.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }

        // 2) 位图：截图与图像数据（PNG / TIFF）。同时有实质文字时让给文字
        if text.map(isLocatorOnly) ?? true {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    return .imageBitmap(data)
                }
            }
        }

        // 3) 纯文本
        return text.map(ClipboardContent.plainText)
    }

    /// 文字是否只是一个网址或文件路径（随图片一起复制的地址，不是待翻译内容）。
    static func isLocatorOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "file", "data"].contains(scheme)
    }
}
