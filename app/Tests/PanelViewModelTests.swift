import XCTest
import AppKit
@testable import BabelTower

/// 浮窗视图模型状态机：剪贴板带入、呼出清空、触发规则、
/// 目标语言切换、流式标记、复制路径、失败相位。全部走 mock SSE 引擎与注入时钟。
@MainActor
final class PanelViewModelTests: XCTestCase {

    private var viewModel: PanelViewModel!
    private var pasteboard: NSPasteboard!
    private var settings: ModelServiceSettings!
    private var collapsed = false
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        pasteboard = NSPasteboard.withUniqueName()
        settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.panelVM.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        collapsed = false
        viewModel = PanelViewModel(
            engine: engine,
            settings: settings,
            pasteboard: pasteboard,
            now: { [self] in now },
            collapse: { [self] in collapsed = true },
            imageProcessingMode: .synchronous
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
    }

    // MARK: 工具：把一轮翻译跑完

    private func stubSSE(marker: String = "[[zh-Hans]]", body: String = "你好", delay: TimeInterval = 0) {
        StubURLProtocol.streamHandler = { _ in [
            StubURLProtocol.ScheduledChunk(data: Self.contentChunk("\(marker)\n\(body)").data, delayBefore: delay),
            Self.doneChunk,
        ] }
    }

    private static func contentChunk(_ text: String) -> StubURLProtocol.ScheduledChunk {
        let json = #"{"choices":[{"delta":{"content":\#(encoded(text))}}]}"#
        return .immediate(Data(("data: \(json)\n\n").utf8))
    }

    private static var doneChunk: StubURLProtocol.ScheduledChunk {
        .immediate(Data("data: [DONE]\n\n".utf8))
    }

    private static func encoded(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[]".utf8)
        return String(data: data.dropFirst().dropLast(), encoding: .utf8) ?? "\"\""
    }

    /// 等到相位到达终态（finished / failed）或超时。
    private func waitForTerminal(timeout: TimeInterval = 2) async {
        let terminal = expectation(description: "terminal")
        let cancellable = viewModel.$phase.sink { phase in
            switch phase {
            case .finished, .failed: terminal.fulfill()
            default: break
            }
        }
        await fulfillment(of: [terminal], timeout: timeout)
        cancellable.cancel()
    }

    // MARK: 呼出不读剪贴板（回车翻译）

    /// 剪贴板里有刚复制的文字：呼出不带入、不翻译。
    func testShowDoesNotBringInClipboardText() async throws {
        stubSSE()
        pasteboard.setString("刚复制的文字", forType: .string)

        viewModel.panelWillShow()
        XCTAssertEqual(viewModel.inputText, "", "呼出不读剪贴板")
        XCTAssertEqual(viewModel.phase, .empty)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "呼出不发请求")
    }

    /// 剪贴板里有图片：呼出同样不带入。
    func testShowDoesNotBringInClipboardImage() {
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        viewModel.panelWillShow()
        XCTAssertTrue(viewModel.images.isEmpty)
        XCTAssertEqual(viewModel.phase, .empty)
    }

    // MARK: 每次呼出都是空的

    /// 收起后马上再呼出：上一轮不保留，输入区、结果区都为空。
    func testShowAfterCollapseIsAlwaysEmpty() async {
        stubSSE()
        viewModel.inputText = "上一轮文字"
        viewModel.submit()
        await waitForTerminal()

        viewModel.panelDidCollapse()
        viewModel.panelWillShow()
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertEqual(viewModel.resultText, "")
        XCTAssertEqual(viewModel.phase, .empty)
    }

    /// 翻译中收起再呼出：请求取消，迟到的译文不会出现在新一轮里。
    func testShowCancelsInFlightTranslation() async throws {
        stubSSE(delay: 0.3)
        viewModel.inputText = "还在翻译"
        viewModel.submit()
        XCTAssertEqual(viewModel.phase, .translating)
        // 等请求真正发出，再收起、呼出
        let deadline = Date().addingTimeInterval(3)
        while StubURLProtocol.capturedRequests.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(StubURLProtocol.capturedRequests.isEmpty, "请求应已发出")

        viewModel.panelDidCollapse()
        viewModel.panelWillShow()
        XCTAssertEqual(viewModel.phase, .empty)
        // 正向信号：网络请求被真正取消
        while StubURLProtocol.stopLoadingCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(StubURLProtocol.stopLoadingCount, 1, "请求应被取消")
        try await Task.sleep(nanoseconds: 500_000_000)   // 越过原定出字时间
        XCTAssertEqual(viewModel.resultText, "")
        XCTAssertEqual(viewModel.phase, .empty)
    }

    // MARK: 触发规则

    func testSubmitTranslates() async {
        stubSSE()
        viewModel.inputText = "手动输入"
        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.resultText, "你好")
    }

    func testEmptySubmitDoesNothing() {
        viewModel.submit()
        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "空输入不发包")
    }

    /// 翻译中修改输入再 ↩：按新内容重译（请求体携带新文本）。
    func testSubmitDuringTranslationSupersedesWithNewText() async throws {
        stubSSE()
        viewModel.inputText = "第一版"
        viewModel.submit()
        viewModel.inputText = "第二版改了"
        viewModel.submit()
        await waitForTerminal()
        try await Task.sleep(nanoseconds: 300_000_000)   // 等第二个请求真正发出
        // 并发请求在 URLProtocol 的捕获顺序无保证：断言存在含新文本的请求，而非最后一个
        let bodies = StubURLProtocol.capturedRequests.compactMap { request in
            StubURLProtocol.requestBodyData(of: request).flatMap { String(data: $0, encoding: .utf8) }
        }
        XCTAssertTrue(bodies.contains { $0.contains("第二版改了") }, "重译应使用新输入")
    }

    /// 向空输入区粘贴文字：只填入，不翻译；↩ 才翻译。
    func testPasteIntoEmptyInputWaitsForEnter() async throws {
        stubSSE()
        viewModel.handlePaste("粘贴的文字")
        XCTAssertEqual(viewModel.inputText, "粘贴的文字")
        XCTAssertEqual(viewModel.phase, .composing)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "粘贴不发请求")

        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.resultText, "你好")
    }

    /// 先选语言再粘贴：手动目标保留（粘贴不再复位目标语言）。
    func testPasteIntoEmptyKeepsManualTarget() {
        viewModel.setTargetMode(.manual(.ja))
        viewModel.handlePaste("先选日语再粘贴")
        XCTAssertEqual(viewModel.targetMode, .manual(.ja))
    }

    func testPasteWithExistingInputOnlyAppends() {
        viewModel.inputText = "已有"
        viewModel.handlePaste("追加")
        XCTAssertEqual(viewModel.inputText, "已有追加")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "追加不触发翻译，等 ↩")
    }

    /// 文字超过 10,000 字符：禁止发送并标记超限。
    func testOverLimitInputBlocksSubmit() {
        stubSSE()
        viewModel.inputText = String(repeating: "字", count: BehaviorConstants.maxTextCharacters + 1)
        XCTAssertTrue(viewModel.isInputOverLimit)
        viewModel.submit()
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "超限不发包")
    }

    func testLimitBoundaryAllowsSubmit() async throws {
        stubSSE()
        viewModel.inputText = String(repeating: "字", count: BehaviorConstants.maxTextCharacters)
        XCTAssertFalse(viewModel.isInputOverLimit)
        viewModel.submit()
        try await Task.sleep(nanoseconds: 300_000_000)   // 等请求真正发出
        XCTAssertGreaterThanOrEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    // MARK: 目标语言

    /// 切换目标语言只改选择，不发请求；↩ 才按新语言翻译。
    func testTargetSwitchWaitsForEnter() async throws {
        stubSSE(marker: "[[ja]]", body: "こんにちは")
        viewModel.inputText = "切语言"
        viewModel.setTargetMode(.manual(.ja))
        XCTAssertEqual(viewModel.phase, .composing)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "切语言不发请求")
        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.targetMode, .manual(.ja))
        XCTAssertEqual(viewModel.marker, .language(.ja))

        // 请求体目标语言段应含"译成日语。"
        let lastRequest = StubURLProtocol.capturedRequests.last!
        let body = StubURLProtocol.requestBodyData(of: lastRequest).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertTrue(body.contains("译成日语。"))
    }

    func testAutomaticTargetUsesMainAndForeignPrompt() async throws {
        stubSSE()
        viewModel.inputText = "自动模式"
        viewModel.submit()
        try await Task.sleep(nanoseconds: 300_000_000)   // 等请求真正发出
        guard let lastRequest = StubURLProtocol.capturedRequests.last else {
            return XCTFail("应已发出请求")
        }
        let body = StubURLProtocol.requestBodyData(of: lastRequest).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        XCTAssertTrue(body.contains("用户的主语言是简体中文，常用外语是英语。"))
    }

    /// 手动目标只本轮有效：复制收起后回到自动。
    func testManualTargetResetsAfterCopyTake() async {
        stubSSE()
        viewModel.inputText = "本轮文字"
        viewModel.setTargetMode(.manual(.en))
        viewModel.submit()
        await waitForTerminal()
        viewModel.submit()   // 完成后 ↩ → 复制收起
        XCTAssertTrue(collapsed)
        XCTAssertEqual(viewModel.targetMode, .automatic, "收走后新一轮回自动")
        XCTAssertEqual(pasteboard.string(forType: .string), "你好")
    }

    // MARK: 固定状态

    func testTogglePinnedFlipsState() {
        XCTAssertFalse(viewModel.isPinned, "呼出默认非固定")
        viewModel.togglePinned()
        XCTAssertTrue(viewModel.isPinned, "点图钉进入固定")
        viewModel.togglePinned()
        XCTAssertFalse(viewModel.isPinned, "再点图钉取消")
    }

    /// 固定时完成后 ↩ 复制全文但不收起（固定态不收起窗口）。
    func testCopyTakeKeepsPanelWhenPinned() async {
        stubSSE()
        viewModel.inputText = "固定中复制"
        viewModel.submit()
        await waitForTerminal()
        viewModel.togglePinned()
        viewModel.submit()   // 完成后 ↩ → 只复制不收起
        XCTAssertEqual(pasteboard.string(forType: .string), "你好")
        XCTAssertTrue(viewModel.copyConfirmed)
        XCTAssertFalse(collapsed, "固定时 ↩ 不收起")
    }

    /// 每次呼出恢复非固定（固定状态不跨呼出记忆）。
    func testPinResetsOnShow() {
        viewModel.togglePinned()
        viewModel.panelWillShow()   // 无新鲜剪贴板、无保留内容
        XCTAssertFalse(viewModel.isPinned, "呼出后恢复非固定")
    }

    func testClearRoundResetsEverything() async {
        stubSSE()
        viewModel.inputText = "待清空"
        viewModel.setTargetMode(.manual(.ja))
        viewModel.clearRound()
        XCTAssertEqual(viewModel.inputText, "")
        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertEqual(viewModel.targetMode, .automatic)
        XCTAssertEqual(viewModel.resultText, "")
        XCTAssertNil(viewModel.marker)
    }

    // MARK: 复制

    func testReturnBeforeFinishedDoesNotCopy() async {
        // 慢速响应：翻译中按 ↩ 不复制
        StubURLProtocol.streamHandler = { _ in [
            StubURLProtocol.ScheduledChunk(data: Data(), delayBefore: 1.0),
            Self.contentChunk("[[zh-Hans]]\n迟到"),
            Self.doneChunk,
        ] }
        viewModel.inputText = "等译文"
        viewModel.submit()
        viewModel.submit()   // 翻译中再按 ↩：输入未改 → 不复制（会按新输入重译，输入相同则重复请求）
        XCTAssertFalse(collapsed)
    }

    func testCopyButtonCopiesFullAndConfirms() async {
        stubSSE()
        viewModel.inputText = "按钮复制"
        viewModel.submit()
        await waitForTerminal()
        viewModel.copyButtonTapped()
        XCTAssertEqual(pasteboard.string(forType: .string), "你好")
        XCTAssertTrue(viewModel.copyConfirmed, "按钮变对勾 0.8s（标记即时置位）")
        XCTAssertFalse(collapsed, "按钮复制不收起")
    }

    /// 本 App 写入剪贴板后标记 ownWrite：译文不算新内容。
    func testCopyMarksOwnWrite() async {
        stubSSE()
        viewModel.inputText = "复制后"
        viewModel.submit()
        await waitForTerminal()
        viewModel.copyResult(selection: nil, andCollapse: false)
        viewModel.panelDidCollapse()
        // 下次呼出：自己的译文不该被当新鲜内容带入（监测里 ownWrite 生效由 ClipboardMonitorTests 覆盖，
        // 这里通过行为验证：呼出后输入为空、译文未被带入）
        pasteboard.setString("你好", forType: .string)   // 已是译文，无新变化计数
        viewModel.panelWillShow()
        XCTAssertEqual(viewModel.inputText, "", "呼出为空，自己的译文不被带入")
    }

    // MARK: 标记与失败

    func testSameMarkerShowsOriginalAndBanner() async {
        stubSSE(marker: "[[same]]", body: "Hello 原文")
        viewModel.inputText = "Hello 原文"
        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.marker, .same)
        XCTAssertEqual(viewModel.resultText, "Hello 原文")
        XCTAssertEqual(viewModel.banner, .sameAsSource(language: .zhHans))
    }

    func testNoneMarkerShowsBanner() async {
        stubSSE(marker: "[[none]]", body: "")
        viewModel.inputText = "（无内容的轮次）"
        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.marker, .some(MarkerParser.Marker.none))
        XCTAssertEqual(viewModel.banner, .noTextInImage)
    }

    func testFailurePhaseKeepsInputAndSuggestsRetry() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.errorResponse(status: 401, serverMessage: "bad key")
        }
        viewModel.inputText = "会失败的文字"
        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.phase, .failed(.keyRejected(detail: "bad key")))
        XCTAssertEqual(viewModel.inputText, "会失败的文字", "失败保留输入")
        if case .failed(let failure) = viewModel.phase {
            XCTAssertTrue(failure.suggestsSettings)
        }
    }

    /// 未配置 API Key：相位给出去设置类失败，不发包。
    func testMissingAPIKeyFailsWithConfiguration() async throws {
        try settings.setAPIKey("", forPresetID: "openai")
        viewModel.inputText = "没 Key"
        viewModel.submit()
        XCTAssertEqual(viewModel.phase, .failed(.configuration(.missingAPIKey)))
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0)
    }

    func testRetranslateUsesSameInput() async throws {
        stubSSE()
        viewModel.inputText = "重译这段"
        viewModel.submit()
        await waitForTerminal()
        let requestsBefore = StubURLProtocol.capturedRequests.count
        viewModel.retranslate()
        try await Task.sleep(nanoseconds: 300_000_000)   // 等重译请求真正发出
        XCTAssertGreaterThan(StubURLProtocol.capturedRequests.count, requestsBefore)
    }
}

/// 回车翻译：完成后切换语言，↩ 应按新语言重译，而不是复制旧译文收起。
@MainActor
final class EnterToTranslateTests: XCTestCase {

    func testEnterAfterLanguageSwitchRetranslatesInsteadOfCopying() async throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.enter.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        var collapsed = false
        let pasteboard = NSPasteboard.withUniqueName()
        let viewModel = PanelViewModel(
            engine: TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config))),
            settings: settings,
            pasteboard: pasteboard,
            collapse: { collapsed = true },
            imageProcessingMode: .synchronous
        )
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data(#"data: {"choices":[{"delta":{"content":"[[en]]\nHello"}}]}"#.utf8 + Data("\n\n".utf8))),
            .immediate(Data("data: [DONE]\n\n".utf8)),
        ] }
        viewModel.inputText = "你好"
        viewModel.submit()
        for _ in 0..<40 where viewModel.phase != .finished {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(viewModel.phase, .finished)

        viewModel.setTargetMode(.manual(.ja))
        XCTAssertEqual(viewModel.phase, .composing, "切语言后回到待发送")
        XCTAssertEqual(AppText.panelHint(for: viewModel.phase), AppText.panelHintComposing)
        viewModel.submit()
        XCTAssertFalse(collapsed, "切语言后 ↩ 是重译，不是复制收起")
        XCTAssertEqual(viewModel.phase, .translating)
        StubURLProtocol.resetStreamingState()
    }
}
