import XCTest
@testable import BabelTower

/// 翻译引擎核心测试（本地 mock SSE，不连真实服务）：
/// 事件流与标记感知缓冲、单请求取消语义、首字超时、max_tokens 规则、请求构造。
@MainActor
final class TranslationEngineTests: XCTestCase {

    private var engine: TranslationEngine!
    private var client: OpenAICompatibleClient!

    override func setUp() async throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = OpenAICompatibleClient(session: URLSession(configuration: config))
        engine = TranslationEngine(client: client, firstTokenTimeout: 2.0)
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
        engine = nil
    }

    // MARK: 工具

    private func makeConfig() -> ResolvedServiceConfig {
        ResolvedServiceConfig(
            presetID: "openai",
            displayName: "OpenAI",
            model: "虚构模型-1",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key",
            disableThinkingParameters: ["reasoning_effort": .string("none")],
            supportsImages: true
        )
    }

    private static func contentChunk(_ text: String, delayBefore: TimeInterval = 0) -> StubURLProtocol.ScheduledChunk {
        let json = #"{"choices":[{"delta":{"content":\#(Self.encoded(text))}}]}"#
        return .immediate(Data(("data: \(json)\n\n").utf8))
    }

    private static var doneChunk: StubURLProtocol.ScheduledChunk {
        .immediate(Data("data: [DONE]\n\n".utf8))
    }

    private static func errorChunk(_ message: String) -> StubURLProtocol.ScheduledChunk {
        .immediate(Data((#"data: {"error":{"message":"\#(message)"}}"# + "\n\n").utf8))
    }

    private static func encoded(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[]".utf8)
        return String(data: data.dropFirst().dropLast(), encoding: .utf8) ?? "\"\""
    }

    /// 跑一次翻译到终态事件（finished / failed），返回全部事件。
    private func runUntilTerminal(
        text: String = "你好",
        target: TranslationTarget = .manual(.zhHans),
        timeout: TimeInterval = 3
    ) async -> [TranslationEvent] {
        let terminal = expectation(description: "terminal event")
        var events: [TranslationEvent] = []
        engine.translate(text: text, target: target, config: makeConfig()) { event in
            events.append(event)
            if case .finished = event { terminal.fulfill() }
            if case .failed = event { terminal.fulfill() }
        }
        await fulfillment(of: [terminal], timeout: timeout)
        return events
    }

    // MARK: max_tokens 规则（输入长度 3 倍且 ≥512）

    func testMaxOutputTokensRule() {
        XCTAssertEqual(TranslationEngine.maxOutputTokens(forTextLength: 1), 512)
        XCTAssertEqual(TranslationEngine.maxOutputTokens(forTextLength: 10), 512)
        XCTAssertEqual(TranslationEngine.maxOutputTokens(forTextLength: 200), 600)
        XCTAssertEqual(TranslationEngine.maxOutputTokens(forTextLength: 400), 1_200)
    }

    // MARK: 请求构造

    func testTranslationRequestConstruction() async {
        StubURLProtocol.streamHandler = { _ in [Self.doneChunk] }

        let events = await runUntilTerminal(text: "你好世界", target: .manual(.ja))
        guard case .finished = events.last else {
            return XCTFail("应正常完成：\(events)")
        }

        let request = try! XCTUnwrap(StubURLProtocol.capturedRequests.last)
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.fictional.example/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer 虚构测试Key")

        let bodyData = try! XCTUnwrap(StubURLProtocol.requestBodyData(of: request))
        let body = try! XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "虚构模型-1")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")

        let messages = try! XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        let system = try! XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.hasPrefix("你是一个翻译引擎"), "系统提示词应以内置模板首句开头")
        XCTAssertTrue(system.contains("译成日语。"), "目标语言段应按手动目标填充")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "<source>\n你好世界\n</source>")
    }

    /// 自定义提示词：系统消息 = 自定义模板（占位符替换后），所见即所发。
    func testCustomPromptUsedAsSystemMessage() async {
        StubURLProtocol.streamHandler = { _ in [Self.doneChunk] }

        var events: [TranslationEvent] = []
        let terminal = expectation(description: "terminal")
        engine.translate(text: "样本", target: .manual(.en),
                         customPrompt: "只按{目标语言}输出，别的不许多说",
                         config: makeConfig()) { event in
            events.append(event)
            if case .finished = event { terminal.fulfill() }
            if case .failed = event { terminal.fulfill() }
        }
        await fulfillment(of: [terminal], timeout: 3)
        guard case .finished = events.last else {
            return XCTFail("应正常完成：\(events)")
        }

        let request = try! XCTUnwrap(StubURLProtocol.capturedRequests.last)
        let bodyData = try! XCTUnwrap(StubURLProtocol.requestBodyData(of: request))
        let body = try! XCTUnwrap(
            try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let messages = try! XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = try! XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertEqual(system, "只按译成英语。输出，别的不许多说",
                       "占位符替换为当前目标语言段，其余原样")
    }

    /// 图文混合请求体同样使用自定义提示词。
    func testCustomPromptUsedInImageRequestBody() throws {
        let body = TranslationEngine.translationBody(
            text: "样本",
            images: [ProcessedImage(data: Data([1]), mimeType: "image/png")],
            target: .manual(.ja),
            customPrompt: "图文都按{目标语言}来",
            config: makeConfig())
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertEqual(system, "图文都按译成日语。来")
    }

    // MARK: 事件流与标记感知缓冲

    func testMarkerSplitAcrossChunksThenDeltas() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[zh-H"),
            Self.contentChunk("ans]]\n你"),
            Self.contentChunk("好"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.language(.zhHans)),
            .delta("你"),
            .delta("好"),
            .finished(marker: .language(.zhHans), body: "你好"),
        ])
    }

    func testMarkerAloneSkipsFollowingNewline() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[zh-Hans]]"),
            Self.contentChunk("\n你好"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.language(.zhHans)),
            .delta("你好"),
            .finished(marker: .language(.zhHans), body: "你好"),
        ])
    }

    func testPassthroughWhenNoMarkerInWindow() async {
        let longText = "这一段译文开头没有标记而且超过了二十个字符的扫描窗口"
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk(longText),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.passthrough),
            .delta(longText),
            .finished(marker: .passthrough, body: longText),
        ])
    }

    func testNoneMarkerSuppressesEverythingAfter() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[none]]"),
            Self.contentChunk("模型多余的解释"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.none),
            .finished(marker: .none, body: ""),
        ])
    }

    /// 标记判定完成前，不向 UI 发任何正文（缓冲到能判定为止）。
    func testNoBodyEmittedBeforeMarkerResolves() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[zh-H"),   // 不足以判定
            Self.contentChunk("ans]]"),
            Self.contentChunk("\n译文"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        // 前两块只累积缓冲；第三块才判定标记并给出正文
        XCTAssertEqual(events, [
            .markerResolved(.language(.zhHans)),
            .delta("译文"),
            .finished(marker: .language(.zhHans), body: "译文"),
        ])
    }

    // MARK: 标记后无换行（钉住用例）

    /// 场景 A：标记后无换行、内容跨块到达——换行到达前标记行上的内容按候选暂存并最终作废，
    /// 正文从换行后开始，对齐 MarkerParser 完整文本语义（正文从第二行起）。
    func testMarkerWithoutNewlineDiscardsMarkerLineContent() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[zh-Hans]]你"),
            Self.contentChunk("好\n世界"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.language(.zhHans)),
            .delta("世界"),
            .finished(marker: .language(.zhHans), body: "世界"),
        ])
    }

    /// 场景 B：标记后始终没有换行——流结束时采用候选正文（截断 fallback），
    /// 译文不得静默丢失（"不留空白"）。
    func testMarkerWithoutNewlineFallsBackToAfterMarkerContent() async {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[zh-Hans]]"),
            Self.contentChunk("正文一"),
            Self.contentChunk("正文二"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.language(.zhHans)),
            .delta("正文一正文二"),
            .finished(marker: .language(.zhHans), body: "正文一正文二"),
        ])
    }

    // MARK: 单请求语义：新请求取消旧请求，取消后不上屏

    func testSupersedingCancelsOldRequestSilently() async {
        StubURLProtocol.streamHandler = { request in
            let body = StubURLProtocol.requestBodyData(of: request).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            if body.contains("慢请求文本") {
                return [
                    StubURLProtocol.ScheduledChunk(data: Data(), delayBefore: 1.0),
                    Self.contentChunk("[[en]]\nslow"),
                    Self.doneChunk,
                ]
            }
            return [
                Self.contentChunk("[[zh-Hans]]\n快"),
                Self.doneChunk,
            ]
        }

        var oldEvents: [TranslationEvent] = []
        let newTerminal = expectation(description: "new request finishes")

        engine.translate(text: "慢请求文本", target: .manual(.zhHans), config: makeConfig()) { event in
            oldEvents.append(event)   // 旧请求的任何事件都不应到达
        }
        engine.translate(text: "快请求文本", target: .manual(.zhHans), config: makeConfig()) { event in
            if case .finished = event { newTerminal.fulfill() }
        }
        await fulfillment(of: [newTerminal], timeout: 3)

        try! await Task.sleep(nanoseconds: 300_000_000)   // 等旧请求的取消落地
        XCTAssertTrue(oldEvents.isEmpty, "被取代的旧请求不得再上报事件：\(oldEvents)")
        XCTAssertGreaterThanOrEqual(StubURLProtocol.stopLoadingCount, 1, "旧请求应被真正取消")
    }

    // MARK: 首字超时（首字超过 60 秒；测试注入短超时）

    /// 默认首字超时 60 秒，提示文案与之一致。
    func testDefaultFirstTokenTimeoutIs60Seconds() {
        XCTAssertEqual(BehaviorConstants.firstTokenTimeout, 60)
        XCTAssertEqual(TranslationFailure.firstTokenTimeout.userMessage,
                       "60 秒内没有收到译文开头，已停止请求。可以重试。")
    }

    func testFirstTokenTimeoutFails() async {
        engine = TranslationEngine(client: client, firstTokenTimeout: 0.15)
        StubURLProtocol.streamHandler = { _ in [
            StubURLProtocol.ScheduledChunk(data: Data(), delayBefore: 0.6),
            Self.contentChunk("[[zh-Hans]]\n迟到"),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [.failed(.firstTokenTimeout)])
    }

    func testTimeoutDisarmedAfterFirstToken() async {
        engine = TranslationEngine(client: client, firstTokenTimeout: 0.2)
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[en]]\nhi"),
            StubURLProtocol.ScheduledChunk(
                data: Self.contentChunk("!").data, delayBefore: 0.5),
            Self.doneChunk,
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.language(.en)),
            .delta("hi"),
            .delta("!"),
            .finished(marker: .language(.en), body: "hi!"),
        ])
    }

    // MARK: 错误路径

    /// 显式 cancel（如 ⌘N 清空）后不得再上报任何事件。
    func testExplicitCancelSilencesAllEvents() async throws {
        StubURLProtocol.streamHandler = { _ in [
            StubURLProtocol.ScheduledChunk(data: Data(), delayBefore: 1.0),
            Self.contentChunk("[[zh-Hans]]\n迟到"),
            Self.doneChunk,
        ] }
        var events: [TranslationEvent] = []
        engine.translate(text: "你好", target: .manual(.zhHans), config: makeConfig()) { event in
            events.append(event)
        }
        engine.cancel()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertTrue(events.isEmpty, "显式取消后不得再上报事件：\(events)")
    }

    func testHTTP401FailsWithKeyRejected() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.errorResponse(status: 401, serverMessage: "Incorrect API key provided")
        }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [.failed(.keyRejected(detail: "Incorrect API key provided"))])
    }

    func testNetworkErrorFailsWithNetworkUnavailable() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [.failed(.networkUnavailable)])
    }

    func testStreamErrorAfterContentFailsWithStreamInterrupted() async {
        let longText = "已经收到的一段超过二十个字符的译文部分内容在这里"
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk(longText),
            Self.errorChunk("Provider overloaded"),
        ] }
        let events = await runUntilTerminal()
        XCTAssertEqual(events, [
            .markerResolved(.passthrough),
            .delta(longText),
            .failed(.streamInterrupted(detail: "Provider overloaded")),
        ])
    }
}
