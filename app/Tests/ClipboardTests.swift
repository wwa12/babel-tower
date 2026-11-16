import XCTest
import AppKit
@testable import BabelTower

/// 剪贴板新鲜度判定（纯函数）：
/// 60 秒窗口、App 自己写入不算、未被带入过才算。
final class ClipboardFreshnessTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testChangeWithinWindowIsFresh() {
        XCTAssertTrue(ClipboardFreshness.isFresh(
            lastChangeDate: base.addingTimeInterval(10), now: base.addingTimeInterval(30)))
        // 恰好 60 秒边界算新鲜（"60 秒内"含边界）
        XCTAssertTrue(ClipboardFreshness.isFresh(
            lastChangeDate: base, now: base.addingTimeInterval(60)))
    }

    func testChangeBeyondWindowIsStale() {
        XCTAssertFalse(ClipboardFreshness.isFresh(
            lastChangeDate: base, now: base.addingTimeInterval(60.01)))
        XCTAssertFalse(ClipboardFreshness.isFresh(
            lastChangeDate: base, now: base.addingTimeInterval(3_600)))
    }

    func testNoRecordedChangeIsStale() {
        XCTAssertFalse(ClipboardFreshness.isFresh(lastChangeDate: nil, now: base))
    }
}

/// 剪贴板变化监测状态机（注入时钟与 changeCount，不依赖真实轮询）。
/// 变化只看 changeCount（不读内容）；本 App 写入的译文不算新内容；带入过的不重复带入。
@MainActor
final class ClipboardMonitorTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
    }

    private func makeMonitor(initialChangeCount: Int = 100) -> ClipboardMonitor {
        ClipboardMonitor(
            initialChangeCount: initialChangeCount,
            now: { [self] in now }
        )
    }

    func testObservedChangeBecomesFresh() {
        let monitor = makeMonitor(initialChangeCount: 100)
        advance(5)
        let snapshot = monitor.update(changeCount: 101)   // 检测到变化
        XCTAssertEqual(snapshot?.changeCount, 101)
        XCTAssertTrue(monitor.isFreshContent(snapshot!))
    }

    func testNoChangeYieldsNil() {
        let monitor = makeMonitor(initialChangeCount: 100)
        advance(5)
        XCTAssertNil(monitor.update(changeCount: 100))
        XCTAssertFalse(monitor.hasFreshContent)
    }

    func testOwnWriteIsNotFresh() {
        let monitor = makeMonitor(initialChangeCount: 100)
        monitor.noteOwnWrite(changeCount: 101)   // App 自己复制译文 → 计数 +1 但不算新内容
        advance(1)
        let snapshot = monitor.update(changeCount: 101)
        XCTAssertNotNil(snapshot, "变化仍应被观察到")
        XCTAssertFalse(monitor.isFreshContent(snapshot!), "本 App 写入不算新鲜内容")
    }

    func testConsumedContentIsNotFreshAgain() {
        let monitor = makeMonitor(initialChangeCount: 100)
        advance(5)
        let snapshot = monitor.update(changeCount: 101)!
        monitor.markConsumed(snapshot)
        advance(10)
        // 计数没变：既无新快照，旧内容也不再新鲜（已被带入过）
        XCTAssertNil(monitor.update(changeCount: 101))
        XCTAssertFalse(monitor.isFreshContent(snapshot))
    }

    func testFreshnessExpiresAfterWindow() {
        let monitor = makeMonitor(initialChangeCount: 100)
        advance(5)
        let snapshot = monitor.update(changeCount: 101)!
        advance(BehaviorConstants.clipboardFreshnessInterval + 1)
        XCTAssertFalse(monitor.isFreshContent(snapshot), "超过 60 秒不新鲜")
        XCTAssertFalse(monitor.hasFreshContent)
    }

    /// 轮询间隔：只读计数的高频轮询，空闲 CPU 接近 0。
    func testPollIntervalIsLightweight() {
        XCTAssertLessThanOrEqual(ClipboardMonitor.pollInterval, 1.0)
    }
}

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
