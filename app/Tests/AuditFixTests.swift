import XCTest
import AppKit
import SwiftUI
@testable import BabelTower

/// 缺陷回归测试：短译文被吞、浮窗高度、⌘C 选区、位置记忆、快速切换、纯图片切语言。
/// 每个用例断言产品期望行为；修复前全部失败。
@MainActor
final class AuditFixTests: XCTestCase {

    private var viewModel: PanelViewModel!
    private var pasteboard: NSPasteboard!
    private var panelDefaults: UserDefaults!

    override func setUp() async throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        pasteboard = NSPasteboard.withUniqueName()
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.audit.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        viewModel = PanelViewModel(
            engine: engine, settings: settings,
            clipboardMonitor: ClipboardMonitor(initialChangeCount: 100, now: { Date() }),
            pasteboard: pasteboard, now: { Date() }, collapse: {},
            imageProcessingMode: .synchronous)
        panelDefaults = UserDefaults(suiteName: "test.audit.panel.\(UUID().uuidString)")!
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
    }

    // MARK: 工具

    private static func chunk(_ text: String) -> StubURLProtocol.ScheduledChunk {
        let data = try! JSONEncoder().encode(["choices": [["delta": ["content": text]]]])
        return .immediate(Data("data: ".utf8) + data + Data("\n\n".utf8))
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

    private func pngData() -> Data {
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// 走生产路径组装浮窗：PanelController + 真实 PanelContentView。
    private func makeRealPanel() -> PanelController {
        let viewModel = self.viewModel!
        let controller = PanelController(
            panelContent: { PanelHostingView(rootView: AnyView(PanelContentView(viewModel: viewModel))) },
            settingsContent: { NSView() },
            defaults: panelDefaults
        )
        controller.viewModel = viewModel
        return controller
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allSubviews(of:))
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: 缺陷 1：短译文缺首行标记被吞（无合法标记时整体当译文）

    func testShortOutputWithoutMarkerIsShownAsTranslation() async {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("你好"), Self.done] }
        viewModel.handlePaste("Hello")
        await waitForTerminalPhase()
        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(viewModel.resultText, "你好")
        XCTAssertFalse(viewModel.showsEmptyResultHint)
    }

    func testShortOutputWithoutMarkerSplitAcrossChunksIsShown() async {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("Hel"), Self.chunk("lo!"), Self.done] }
        viewModel.handlePaste("你好！")
        await waitForTerminalPhase()
        XCTAssertEqual(viewModel.resultText, "Hello!")
    }

    /// 只在正常完成时补发：模型拒绝时未判定的内容不当译文。
    func testUnmarkedTextIsNotFlushedOnRefusal() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.chunk("abc"),
            .immediate(Data(#"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#.utf8) + Data("\n\n".utf8)),
        ] }
        viewModel.handlePaste("Hello")
        await waitForTerminalPhase()
        XCTAssertEqual(viewModel.phase, .failed(.modelRefused))
        XCTAssertEqual(viewModel.resultText, "")
    }

    /// 写了一半的标记（流在 "[[zh-Ha" 处正常结束）不是译文。
    func testHalfWrittenMarkerIsNotShownAsTranslation() async {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("[[zh-Ha"), Self.done] }
        viewModel.handlePaste("Hello")
        await waitForTerminalPhase()
        XCTAssertEqual(viewModel.resultText, "")
    }

    // MARK: 缺陷 6：纯图片输入切换语言要立即重译

    func testSwitchingLanguageWithImageOnlyRetranslates() async {
        StubURLProtocol.streamHandler = { _ in [Self.chunk("[[zh-Hans]]\n图里的字"), Self.done] }
        viewModel.handlePasteImage(data: pngData())
        await waitForTerminalPhase()
        let requestsBefore = StubURLProtocol.capturedRequests.count
        viewModel.setTargetMode(.manual(.ja))
        XCTAssertEqual(viewModel.phase, .translating, "切换后应立即进入重译")
        await waitForTerminalPhase()
        XCTAssertGreaterThan(StubURLProtocol.capturedRequests.count, requestsBefore)
    }

    // MARK: 缺陷 4：位置记忆只记用户拖动，程序定位不算

    func testProgrammaticPositioningIsNotRemembered() {
        let controller = PanelController(panelContent: { NSView() }, settingsContent: { NSView() },
                                          defaults: panelDefaults)
        controller.showPanel()
        controller.hidePanel()
        controller.showPanel()
        controller.hidePanel()
        XCTAssertNil(panelDefaults.string(forKey: "panel.savedFrame"),
                     "没有拖动过，不应写入记忆位置（否则以后不再跟随鼠标所在显示器）")
    }

    func testControllerDoesNotTouchStandardDefaults() {
        let before = UserDefaults.standard.string(forKey: "panel.savedFrame")
        let controller = PanelController(panelContent: { NSView() }, settingsContent: { NSView() },
                                          defaults: panelDefaults)
        controller.showPanel()
        // 不经控制器的移动（等同用户拖动）应被记住——且记在注入的存储里，不碰真实偏好
        controller.panelForTesting.setFrameOrigin(NSPoint(x: 10, y: 10))
        controller.hidePanel()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "panel.savedFrame"), before)
        let saved = try? XCTUnwrap(panelDefaults.string(forKey: "panel.savedFrame"))
        XCTAssertEqual(saved.map { NSRectFromString($0).origin }, NSPoint(x: 10, y: 10),
                       "用户拖动后的位置应被记住")
    }

    // MARK: 缺陷 5：收起后立刻再呼出，面板必须可见

    func testFastHideThenShowKeepsPanelOnScreen() async {
        let controller = PanelController(panelContent: { NSView() }, settingsContent: { NSView() },
                                          defaults: panelDefaults)
        controller.showPanel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        controller.hidePanel()
        controller.showPanel()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(controller.isPanelVisible)
        XCTAssertTrue(controller.panelForTesting.isVisible, "淡出回调不应把刚呼出的面板 orderOut")
        XCTAssertEqual(controller.panelForTesting.alphaValue, 1, accuracy: 0.01)
        controller.hidePanel()
    }

    // MARK: 缺陷 3：结果区选中部分文字，⌘C 只复制选区

    func testCommandCCopiesOnlySelectedResultText() throws {
        let controller = makeRealPanel()
        controller.showPanel()
        viewModel.inputText = "Hello world"
        viewModel.forceFinishedForTesting(marker: .language(.zhHans), body: "你好，世界")
        settle()
        let panel = controller.panelForTesting
        let contentView = try XCTUnwrap(panel.contentView)
        let resultTextView = try XCTUnwrap(
            allSubviews(of: contentView).compactMap { $0 as? NSTextView }.first { !$0.isEditable },
            "结果区必须是可选中的只读文本视图")
        XCTAssertEqual(resultTextView.string, "你好，世界")
        XCTAssertTrue(panel.makeFirstResponder(resultTextView))
        resultTextView.setSelectedRange(NSRange(location: 0, length: 2))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "c",
            charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertEqual(panel.keyEventHandler?(event), true)
        XCTAssertEqual(pasteboard.string(forType: .string), "你好")
        controller.hidePanel()
    }

    /// 流式期间到完成，结果区是同一个文本视图（不重建，选区与焦点保留）。
    func testResultTextViewSurvivesStreamingToFinished() async throws {
        let controller = makeRealPanel()
        controller.showPanel()
        StubURLProtocol.streamHandler = { _ in [
            Self.chunk("[[zh-Hans]]\n第一段"),
            StubURLProtocol.ScheduledChunk(data: Data("data: ".utf8)
                + (try! JSONEncoder().encode(["choices": [["delta": ["content": "，第二段"]]]]))
                + Data("\n\n".utf8), delayBefore: 0.6),
            Self.done,
        ] }
        viewModel.handlePaste("First part, second part")
        try await Task.sleep(nanoseconds: 300_000_000)
        let contentView = try XCTUnwrap(controller.panelForTesting.contentView)
        let streaming = try XCTUnwrap(
            allSubviews(of: contentView).compactMap { $0 as? NSTextView }.first { !$0.isEditable })
        XCTAssertEqual(viewModel.phase, .translating)
        streaming.setSelectedRange(NSRange(location: 0, length: 2))
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(viewModel.phase, .finished)
        let finished = try XCTUnwrap(
            allSubviews(of: contentView).compactMap { $0 as? NSTextView }.first { !$0.isEditable })
        XCTAssertTrue(streaming === finished, "完成时结果区文本视图被重建")
        XCTAssertEqual(finished.string, "第一段，第二段")
        XCTAssertEqual(finished.selectedRange(), NSRange(location: 0, length: 2), "流式追加不应清掉选区")
        controller.hidePanel()
    }

    /// 浮窗拖到靠近屏幕底边后来了长译文：整个窗口仍在可见区内。
    func testGrowingPanelStaysOnScreen() throws {
        let controller = makeRealPanel()
        controller.showPanel()
        settle()
        let panel = controller.panelForTesting
        let visible = try XCTUnwrap(panel.screen?.visibleFrame)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: visible.minY + 5))   // 用户拖到底部
        viewModel.inputText = "Hello"
        viewModel.forceFinishedForTesting(
            marker: .language(.zhHans),
            body: Array(repeating: "很长的一行译文内容", count: 40).joined(separator: "\n"))
        settle()
        XCTAssertGreaterThanOrEqual(panel.frame.minY, visible.minY - 0.5, "窗口底部越出屏幕可见区")
        XCTAssertLessThanOrEqual(panel.frame.maxY, visible.maxY + 0.5)
        XCTAssertGreaterThan(panel.frame.height, 300)
        controller.hidePanel()
    }

    // MARK: 缺陷 2：浮窗高度随内容在 120–640 伸缩，顶边不动

    func testPanelHeightFollowsContentWithTopEdgeFixed() throws {
        let controller = makeRealPanel()
        controller.showPanel()
        settle()
        let panel = controller.panelForTesting
        let emptyFrame = panel.frame
        XCTAssertGreaterThanOrEqual(emptyFrame.height, BehaviorConstants.panelMinHeight)

        viewModel.inputText = "Hello"
        viewModel.forceFinishedForTesting(
            marker: .language(.zhHans),
            body: Array(repeating: "很长的一行译文内容", count: 40).joined(separator: "\n"))
        settle()
        let longFrame = panel.frame
        XCTAssertGreaterThan(longFrame.height, emptyFrame.height + 100, "长译文时窗口应变高")
        XCTAssertLessThanOrEqual(longFrame.height, BehaviorConstants.panelMaxHeight)
        XCTAssertEqual(longFrame.maxY, emptyFrame.maxY, accuracy: 1, "变高时顶边不动，向下长")

        viewModel.clearRound()
        settle()
        XCTAssertLessThan(panel.frame.height, longFrame.height, "清空后窗口应缩回")
        XCTAssertEqual(panel.frame.maxY, emptyFrame.maxY, accuracy: 1)
        controller.hidePanel()
    }
}
