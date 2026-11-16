import XCTest
import AppKit
@testable import BabelTower

/// 解析顺序测试：图片文件 → 位图 → 纯文本。
/// 用 NSPasteboard.withUniqueName 构造真实粘贴板，测真实 API 路径。
@MainActor
final class ClipboardParserTests: XCTestCase {

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard.withUniqueName()
    }

    func testPrefersImageFilesOverBitmapAndText() throws {
        let board = makePasteboard()
        board.declareTypes([.fileURL, .string], owner: nil)
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/虚构图片.png")])
        board.setString("还有文字", forType: .string)

        let content = try XCTUnwrap(ClipboardParser.parse(board))
        guard case let .imageFiles(urls) = content else {
            return XCTFail("应优先解析为图片文件：\(content)")
        }
        XCTAssertEqual(urls, [URL(fileURLWithPath: "/tmp/虚构图片.png")])
    }

    /// 复制的是非图片文件：无反应（内容不是文字和图片）。
    /// 早期版本这里回落为文件名文字，会把"虚构文档.pdf"当原文翻译。
    func testNonImageFilesAreIgnored() throws {
        let board = makePasteboard()
        board.declareTypes([.fileURL, .string], owner: nil)
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/虚构文档.pdf")])
        board.setString("虚构文档.pdf", forType: .string)

        XCTAssertNil(ClipboardParser.parse(board))
    }

    func testBitmapWhenNoFiles() throws {
        let board = makePasteboard()
        let pngData = try XCTUnwrap(makePNGData())
        board.declareTypes([.png], owner: nil)
        board.setData(pngData, forType: .png)

        let content = try XCTUnwrap(ClipboardParser.parse(board))
        guard case let .imageBitmap(data) = content else {
            return XCTFail("应解析为位图：\(content)")
        }
        XCTAssertEqual(data, pngData)
    }

    /// 截图与图像数据的另一常见类型：TIFF（支持位图 PNG、TIFF）。
    func testTIFFBitmapParsed() throws {
        let board = makePasteboard()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try XCTUnwrap(context.makeImage())
        let tiffData = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .tiff, properties: [:]))
        board.declareTypes([.tiff], owner: nil)
        board.setData(tiffData, forType: .tiff)

        let content = try XCTUnwrap(ClipboardParser.parse(board))
        guard case let .imageBitmap(data) = content else {
            return XCTFail("应解析为 TIFF 位图：\(content)")
        }
        XCTAssertEqual(data, tiffData)
    }

    func testPlainTextOnly() throws {
        let board = makePasteboard()
        board.setString("一段文字", forType: .string)
        XCTAssertEqual(ClipboardParser.parse(board), .plainText("一段文字"))
    }

    /// 富文本粘贴只保留纯文本；RTF 数据与纯文本并存时取纯文本部分。
    func testRichTextFallsBackToPlainString() throws {
        let board = makePasteboard()
        let rtf = try XCTUnwrap("带样式文字".data(using: .utf8).map { data in
            // 构造最小 RTF，让 pasteboard 同时有 RTF 与 string 类型
            "{\\rtf1\\ansi 带样式文字}".data(using: .utf8) ?? data
        })
        board.declareTypes([.rtf, .string], owner: nil)
        board.setData(rtf, forType: .rtf)
        board.setString("带样式文字", forType: .string)
        XCTAssertEqual(ClipboardParser.parse(board), .plainText("带样式文字"))
    }

    /// 剪贴板为空或内容不是文字和图片 → 无反应不报错。
    func testUnsupportedTypesReturnNil() {
        let emptyBoard = makePasteboard()
        emptyBoard.declareTypes([], owner: nil)
        XCTAssertNil(ClipboardParser.parse(emptyBoard))

        let pdfBoard = makePasteboard()
        pdfBoard.declareTypes([.pdf], owner: nil)
        pdfBoard.setData(Data("%PDF-1.4 虚构".utf8), forType: .pdf)
        XCTAssertNil(ClipboardParser.parse(pdfBoard))
    }

    func testImageExtensionWhitelist() throws {
        // 白名单外的"图片"扩展（如 .svg）不按图片文件处理 → 与其他非图片文件一样无反应
        let board = makePasteboard()
        board.declareTypes([.fileURL, .string], owner: nil)
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/矢量图.svg")])
        board.setString("矢量图.svg", forType: .string)
        XCTAssertNil(ClipboardParser.parse(board))
    }

    private func makePNGData() -> Data? {
        guard let context = CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
