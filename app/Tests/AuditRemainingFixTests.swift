import XCTest
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import BabelTower

/// 缺陷回归测试：照片方向、删图后 ↩、流式中断、粘贴位置、剪贴板优先级。
/// 每个用例断言产品期望行为；修复前全部失败。
@MainActor
final class AuditRemainingFixTests: XCTestCase {

    private var viewModel: PanelViewModel!
    private var pasteboard: NSPasteboard!
    private var collapsed = false

    override func setUp() async throws {
        StubURLProtocol.resetStreamingState()
        FailingMidStreamURLProtocol.firstChunk = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingMidStreamURLProtocol.self, StubURLProtocol.self]
        let engine = TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        pasteboard = NSPasteboard.withUniqueName()
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.audit2.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        collapsed = false
        viewModel = PanelViewModel(
            engine: engine, settings: settings,
            clipboardMonitor: ClipboardMonitor(initialChangeCount: 100, now: { Date() }),
            pasteboard: pasteboard, now: { Date() },
            collapse: { [self] in collapsed = true },
            imageProcessingMode: .synchronous)
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
        FailingMidStreamURLProtocol.firstChunk = nil
    }

    // MARK: 工具

    private static func chunkData(_ text: String) -> Data {
        let json = try! JSONEncoder().encode(["choices": [["delta": ["content": text]]]])
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    private static func chunk(_ text: String) -> StubURLProtocol.ScheduledChunk {
        .immediate(chunkData(text))
    }

    private static var done: StubURLProtocol.ScheduledChunk { .immediate(Data("data: [DONE]\n\n".utf8)) }

    private func waitForTerminalPhase(timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch viewModel.phase {
            case .finished, .failed: return
            default: try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func pngData(width: Int = 40, height: Int = 30) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    private func makeRealPanel() -> PanelController {
        let viewModel = self.viewModel!
        let controller = PanelController(
            panelContent: { PanelHostingView(rootView: AnyView(PanelContentView(viewModel: viewModel))) },
            settingsContent: { NSView() },
            defaults: UserDefaults(suiteName: "test.audit2.panel.\(UUID().uuidString)")!
        )
        controller.viewModel = viewModel
        controller.pasteboardForKeys = pasteboard
        return controller
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews(of:))
    }

    // MARK: 竖拍照片方向（EXIF Orientation）发给模型前要摆正

    /// 300×100 的横向像素 + Orientation=6（顺时针转 90° 显示）= 实际应是 100×300 的竖图。
    private func orientedJPEG() -> Data {
        let context = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 100))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func testOrientationAppliedForBitmapData() throws {
        let processed = try XCTUnwrap(ImagePreprocessor.process(data: orientedJPEG()))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: processed.data))
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 300)
        XCTAssertEqual(processed.mimeType, "image/jpeg")
    }

    /// 方向摆正与长边 2000 压缩同时生效：4000×1000 横像素 + 方向 6 → 500×2000 竖图。
    func testOrientationAndDownscaleTogether() throws {
        let context = CGContext(data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 1000))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let processed = try XCTUnwrap(ImagePreprocessor.process(data: data as Data))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: processed.data))
        XCTAssertEqual(rep.pixelsHigh, 2000)
        XCTAssertEqual(rep.pixelsWide, 500, accuracy: 1)
        XCTAssertEqual(processed.mimeType, "image/jpeg")
    }

    func testOrientationAppliedForImageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("竖拍-\(UUID()).jpg")
        try orientedJPEG().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let processed = try XCTUnwrap(ImagePreprocessor.process(fileURL: url))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: processed.data))
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 300)
    }

    // MARK: 删图后 ↩ 不复制旧译文（输入没有改动才复制并收起）

    func testEnterAfterRemovingImageRetranslatesInsteadOfCopying() async throws {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("[[zh-Hans]]\n两张图的译文"), Self.done] }
        viewModel.handlePasteImage(data: pngData())
        await waitForTerminalPhase()
        viewModel.handlePasteImage(data: pngData())
        await waitForTerminalPhase()
        let requestsBefore = StubURLProtocol.capturedRequests.count
        viewModel.removeImage(viewModel.images[1].id)
        XCTAssertEqual(viewModel.phase, .composing, "删图后回到待发送状态")
        viewModel.submit()
        XCTAssertFalse(collapsed, "删图后 ↩ 不应复制旧译文并收起")
        XCTAssertNil(pasteboard.string(forType: .string))
        await waitForTerminalPhase()
        XCTAssertGreaterThan(StubURLProtocol.capturedRequests.count, requestsBefore, "↩ 应按剩下的图重译")
    }

    func testBackspaceDeletingLastImageAlsoCountsAsChange() async {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("[[zh-Hans]]\n译文"), Self.done] }
        viewModel.handlePasteImage(data: pngData())
        await waitForTerminalPhase()
        viewModel.handlePasteImage(data: pngData())
        await waitForTerminalPhase()
        viewModel.deleteLastImage()
        viewModel.submit()
        XCTAssertFalse(collapsed)
    }

    func testRemovingOnlyImageReturnsToEmpty() async {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("[[zh-Hans]]\n译文"), Self.done] }
        viewModel.handlePasteImage(data: pngData())
        await waitForTerminalPhase()
        viewModel.deleteLastImage()
        XCTAssertEqual(viewModel.phase, .empty)
    }

    // MARK: 流式中断：保留已收到的译文并标注未完成

    func testNetworkDropAfterFirstContentIsStreamInterrupted() async {
        FailingMidStreamURLProtocol.firstChunk = Self.chunkData("[[zh-Hans]]\n前半段译文")
        viewModel.handlePaste("Hello world")
        await waitForTerminalPhase()
        guard case .failed(.streamInterrupted) = viewModel.phase else {
            return XCTFail("首字之后断网应归为流式中断，实际：\(viewModel.phase)")
        }
        XCTAssertEqual(viewModel.resultText, "前半段译文")
    }

    func testInterruptedPartialTranslationIsDisplayed() async throws {
        let controller = makeRealPanel()
        controller.showPanel()
        StubURLProtocol.streamHandler = { _ in [
            Self.chunk("[[zh-Hans]]\n已收到的前半段"),
            .immediate(Data(#"data: {"error":{"message":"overloaded"}}"#.utf8) + Data("\n\n".utf8)),
        ] }
        viewModel.handlePaste("Hello world")
        await waitForTerminalPhase()
        try await Task.sleep(nanoseconds: 400_000_000)
        let contentView = try XCTUnwrap(controller.panelForTesting.contentView)
        let resultView = allSubviews(of: contentView).compactMap { $0 as? NSTextView }.first { !$0.isEditable }
        XCTAssertEqual(resultView?.string, "已收到的前半段", "中断后应显示已收到的部分译文")
        controller.hidePanel()
    }

    // MARK: ⌘V 粘贴文字插在光标处 / 替换选区

    func testPasteInsertsAtCursorAndReplacesSelection() async throws {
        let controller = makeRealPanel()
        controller.showPanel()
        viewModel.inputText = "AAA BBB"
        try await Task.sleep(nanoseconds: 300_000_000)
        let panel = controller.panelForTesting
        let input = try XCTUnwrap(panel.firstResponder as? NSTextView, "呼出后焦点应在输入区")
        XCTAssertTrue(input.isEditable)
        XCTAssertEqual(input.string, "AAA BBB")

        pasteboard.clearContents()
        pasteboard.setString("XX", forType: .string)
        input.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(panel.keyEventHandler?(try commandV(panel)), true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.inputText, "AAAXX BBB", "应插入在光标处")

        input.setSelectedRange(NSRange(location: 6, length: 3))   // 选中 "BBB"
        XCTAssertEqual(panel.keyEventHandler?(try commandV(panel)), true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewModel.inputText, "AAAXX XX", "应替换选区")
        XCTAssertEqual(viewModel.phase, .composing, "已有内容时粘贴只追加，不自动翻译")
        controller.hidePanel()
    }

    private func commandV(_ panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    }

    // MARK: 剪贴板同时有文字和图片

    /// 访达复制非图片文件：剪贴板带文件图标位图和文件名，都不是待翻译内容 → 无反应。
    func testFinderNonImageFileIconIsNotTreatedAsImage() {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/虚构报告.pdf")])
        board.addTypes([.tiff, .string], owner: nil)
        board.setData(NSImage(size: NSSize(width: 16, height: 16)).tiffRepresentation ?? pngData(), forType: .tiff)
        board.setString("虚构报告.pdf", forType: .string)
        XCTAssertNil(ClipboardParser.parse(board))
    }

    /// Office / Numbers 复制文字时常附带图片预览：按文字翻译。
    func testTextWithImagePreviewPrefersText() {
        let board = NSPasteboard.withUniqueName()
        board.declareTypes([.string, .png], owner: nil)
        board.setString("Quarterly revenue grew 12%", forType: .string)
        board.setData(pngData(), forType: .png)
        XCTAssertEqual(ClipboardParser.parse(board), .plainText("Quarterly revenue grew 12%"))
    }

    /// 浏览器"拷贝图像"常附带图片地址文本：按图片翻译。
    func testImageWithItsURLPrefersImage() {
        let board = NSPasteboard.withUniqueName()
        board.declareTypes([.png, .string], owner: nil)
        board.setData(pngData(), forType: .png)
        board.setString("https://example.com/assets/poster.png", forType: .string)
        guard case .imageBitmap = ClipboardParser.parse(board) else {
            return XCTFail("只有一个网址的文字不是待翻译内容，应按图片处理")
        }
    }
}

/// 发出一块 SSE 数据后以网络断开失败（模拟首字之后断网）。
final class FailingMidStreamURLProtocol: URLProtocol {
    nonisolated(unsafe) static var firstChunk: Data?

    override class func canInit(with request: URLRequest) -> Bool { firstChunk != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let chunk = Self.firstChunk else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: chunk)
        nonisolated(unsafe) let unsafeSelf = self
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            unsafeSelf.client?.urlProtocol(unsafeSelf, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    override func stopLoading() {}
}
