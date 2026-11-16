import XCTest
import AppKit
@testable import BabelTower

/// 设置存取：主语言/常用外语/引导完成标记，默认简中+英语。
@MainActor
final class AppSettingsTests: XCTestCase {

    private var settings: AppSettings!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "test.appSettings.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testDefaultLanguages() {
        XCTAssertEqual(settings.mainLanguage, .zhHans, "主语言默认简中")
        XCTAssertEqual(settings.foreignLanguage, .en, "常用外语默认英语")
    }

    func testLanguagePersistence() {
        settings.mainLanguage = .ja
        settings.foreignLanguage = .zhHant
        let reloaded = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reloaded.mainLanguage, .ja)
        XCTAssertEqual(reloaded.foreignLanguage, .zhHant)
    }

    /// 主语言与常用外语相同：自动模式无意义，写入口拦住。
    func testSettingSameLanguageRejected() {
        settings.mainLanguage = .zhHans
        settings.foreignLanguage = .zhHans   // 与主语言相同 → 不生效
        XCTAssertEqual(settings.foreignLanguage, .en, "外语不允许与主语言相同")
    }

    func testOnboardingCompletionFlag() {
        XCTAssertFalse(settings.hasCompletedOnboarding)
        settings.hasCompletedOnboarding = true
        XCTAssertTrue(AppSettings(defaults: UserDefaults(suiteName: suiteName)!).hasCompletedOnboarding)
    }

    // MARK: 自定义提示词

    /// 首次使用：编辑框预填默认提示词全文（含 {目标语言} 占位符）。
    func testCustomPromptDefaultsToBuiltinTemplate() {
        XCTAssertEqual(settings.customPrompt, TranslationPrompt.builtinTemplate,
                       "无存量时初始值 = 默认模板全文")
    }

    func testCustomPromptPersistence() {
        settings.customPrompt = "我的提示词{目标语言}"
        XCTAssertEqual(
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!).customPrompt,
            "我的提示词{目标语言}")
    }

    /// 超 10,000 字符自动截断，截断值落盘。
    func testCustomPromptClampedToLimit() {
        settings.customPrompt = String(repeating: "长", count: BehaviorConstants.maxPromptCharacters + 50)
        XCTAssertEqual(settings.customPrompt.count, BehaviorConstants.maxPromptCharacters)
        XCTAssertEqual(
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!).customPrompt.count,
            BehaviorConstants.maxPromptCharacters, "截断后的值应持久化")
    }
}

/// 引导显示条件（首次启动三步引导；配置过的老用户不打扰）。
final class OnboardingStateTests: XCTestCase {

    func testShowsWhenNoKeyAndNotCompleted() {
        XCTAssertTrue(OnboardingState.shouldShow(hasAPIKey: false, hasCompletedOnboarding: false))
    }

    func testHiddenWhenKeyExistsOrCompleted() {
        XCTAssertFalse(OnboardingState.shouldShow(hasAPIKey: true, hasCompletedOnboarding: false),
                       "已配置 Key 的用户不引导")
        XCTAssertFalse(OnboardingState.shouldShow(hasAPIKey: false, hasCompletedOnboarding: true),
                       "完成过引导不再出现")
    }
}

/// 模型拒绝与空译文。
@MainActor
final class RefusalAndEmptyResultTests: XCTestCase {

    // MARK: SSE 层：content_filter 拒绝事件

    func testSSEParserEmitsRefusalOnContentFilter() {
        var parser = SSEParser()
        let events = parser.append(Data(
            ("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n"
             + "data: [DONE]\n\n").utf8
        ))
        XCTAssertTrue(events.contains(.refusal), "content_filter 应产出拒绝事件：\(events)")
    }

    func testSSEParserIgnoresNormalFinishReason() {
        var parser = SSEParser()
        let events = parser.append(Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\n\n".utf8
        ))
        XCTAssertEqual(events, [.content("好")], "正常 stop 不产生拒绝")
    }

    // MARK: 引擎层：拒绝映射为 modelRefused 失败

    func testEngineMapsRefusalToModelRefused() async {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = TranslationEngine(
            client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"content_filter\"}]}\n\n".utf8)),
            .immediate(Data("data: [DONE]\n\n".utf8)),
        ] }
        let resolved = ResolvedServiceConfig(
            presetID: "openai", displayName: "OpenAI", model: "虚构模型",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key", disableThinkingParameters: [:], supportsImages: true
        )
        let terminal = expectation(description: "terminal")
        var events: [TranslationEvent] = []
        engine.translate(text: "会拒绝的文字", target: .manual(.zhHans), config: resolved) { event in
            events.append(event)
            if case .failed = event { terminal.fulfill() }
        }
        await fulfillment(of: [terminal], timeout: 2)
        XCTAssertTrue(events.contains(.failed(.modelRefused)), "应映射为模型拒绝：\(events)")
        if case .failed(let failure) = events.last, case .modelRefused = failure {
            XCTAssertTrue(failure.userMessage.contains("模型拒绝"), "拒绝文案")
        } else {
            XCTFail("终态应为 modelRefused")
        }
    }

    // MARK: 视图模型层：空译文提示状态
    //（视图模型构造辅助在文件末尾的文件作用域：LanguageBox / PromptBox / PanelViewModelStubForSettings）

    private func makeViewModel() async throws -> PanelViewModel {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.emptyResult.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        return PanelViewModel(
            engine: TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config))),
            settings: settings,
            pasteboard: NSPasteboard.withUniqueName(), now: { Date() }, collapse: {}
        )
    }

    func testEmptyFinishedBodyShowsHint() async throws {
        let viewModel = try await makeViewModel()
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data("data: {\"choices\":[{\"delta\":{\"content\":\"[[zh-Hans]]\"}}]}\n\n".utf8)),
            .immediate(Data("data: [DONE]\n\n".utf8)),
        ] }
        viewModel.inputText = "会得到空译文的文字"
        viewModel.submit()
        let terminal = expectation(description: "terminal")
        let cancellable = viewModel.$phase.sink { phase in
            if case .finished = phase { terminal.fulfill() }
        }
        await fulfillment(of: [terminal], timeout: 2)
        cancellable.cancel()
        XCTAssertTrue(viewModel.resultText.isEmpty)
        XCTAssertTrue(viewModel.showsEmptyResultHint, "空译文应给提示状态")
    }

    /// [[none]] 有专门提示，不算空译文（钉住用例）。
    func testNoneMarkerIsNotEmptyResult() {
        let viewModel = PanelViewModelStubForSettings.makeFinishedPanelViewModel(
            marker: .none, body: "")
        XCTAssertFalse(viewModel.showsEmptyResultHint)
    }

    /// 改语言设置只影响下一轮：新请求的目标语言段用新设置（可变捕获闭包驱动两轮）。
    func testLanguageChangeAffectsNextRoundOnly() async throws {
        let foreign = LanguageBox(language: .en)
        let viewModel = PanelViewModelStubForSettings.makePanelViewModel(
            foreignLanguage: { foreign.language })

        viewModel.inputText = "样本文字"
        viewModel.submit()
        try await Task.sleep(nanoseconds: 300_000_000)
        let firstBody = try XCTUnwrap(latestRequestBody())
        XCTAssertTrue(firstBody.contains("常用外语是英语"), "第一轮用英语")

        // 改设置 → 下一轮请求用新外语；设置变化本身不触发重译
        foreign.language = .ja
        try await Task.sleep(nanoseconds: 150_000_000)
        let requestsAfterSettingChange = StubURLProtocol.capturedRequests.count
        XCTAssertEqual(requestsAfterSettingChange, 1, "改设置不得触发重译")

        viewModel.retranslate()
        try await Task.sleep(nanoseconds: 300_000_000)
        let secondBody = try XCTUnwrap(latestRequestBody())
        XCTAssertTrue(secondBody.contains("常用外语是日语"), "下一轮应改用新外语")
    }

    private func latestRequestBody() -> String? {
        StubURLProtocol.capturedRequests.last
            .flatMap { StubURLProtocol.requestBodyData(of: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func testNonEmptyBodyHasNoHint() async throws {
        let viewModel = try await makeViewModel()
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data("data: {\"choices\":[{\"delta\":{\"content\":\"[[zh-Hans]]\\n你好\"}}]}\n\n".utf8)),
            .immediate(Data("data: [DONE]\n\n".utf8)),
        ] }
        viewModel.inputText = "正常文字"
        viewModel.submit()
        let terminal = expectation(description: "terminal")
        let cancellable = viewModel.$phase.sink { phase in
            if case .finished = phase { terminal.fulfill() }
        }
        await fulfillment(of: [terminal], timeout: 2)
        cancellable.cancel()
        XCTAssertFalse(viewModel.showsEmptyResultHint)
    }
}

// MARK: 视图模型构造辅助（文件作用域，本文件各测试类共用）

/// 可变语言捕获（驱动"改设置→下一轮生效"的断言）。
@MainActor
private final class LanguageBox {
    var language: TranslationLanguage
    init(language: TranslationLanguage) { self.language = language }
}

/// 可变提示词捕获（同 LanguageBox，驱动"改提示词→下一轮生效"的断言）。
@MainActor
private final class PromptBox {
    var text: String
    init(text: String) { self.text = text }
}

/// 构造视图模型（可注入语言 / 提示词闭包；或直接置入终态）。
@MainActor
private enum PanelViewModelStubForSettings {
    static func makePanelViewModel(
        foreignLanguage: @escaping () -> TranslationLanguage = { .en },
        customPrompt: @escaping () -> String = { "" }
    ) -> PanelViewModel {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.settingsStub.\(UUID().uuidString)")!
        )
        try? settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        return PanelViewModel(
            engine: TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config))),
            settings: settings,
            pasteboard: NSPasteboard.withUniqueName(),
            now: { Date() },
            collapse: {},
            foreignLanguage: foreignLanguage,
            customPrompt: customPrompt
        )
    }

    static func makeFinishedPanelViewModel(marker: MarkerParser.Marker, body: String) -> PanelViewModel {
        let viewModel = makePanelViewModel()
        // 直接置入终态，驱动被测的派生状态
        viewModel.forceFinishedForTesting(marker: marker, body: body)
        return viewModel
    }
}

/// 自定义提示词端到端：所见即所发、下一轮生效、空白兜底默认。
@MainActor
final class CustomPromptSettingsTests: XCTestCase {

    func testCustomPromptChangeAffectsNextRoundOnly() async throws {
        let prompt = PromptBox(text: "版本甲提示词{目标语言}")
        let viewModel = PanelViewModelStubForSettings.makePanelViewModel(
            customPrompt: { prompt.text })

        viewModel.inputText = "样本文字"
        viewModel.submit()
        try await Task.sleep(nanoseconds: 300_000_000)
        let firstBody = try XCTUnwrap(StubURLProtocol.capturedRequests.last
            .flatMap { StubURLProtocol.requestBodyData(of: $0) }
            .flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(firstBody.contains("版本甲提示词"), "请求体应携带自定义提示词")
        XCTAssertTrue(firstBody.contains("常用外语是英语"), "占位符应替换为当前目标语言段")

        // 改提示词 → 不触发重译，下一轮请求才用新文本
        prompt.text = "版本乙提示词"
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "改提示词不得触发重译")

        viewModel.retranslate()
        try await Task.sleep(nanoseconds: 300_000_000)
        let secondBody = try XCTUnwrap(StubURLProtocol.capturedRequests.last
            .flatMap { StubURLProtocol.requestBodyData(of: $0) }
            .flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(secondBody.contains("版本乙提示词"), "下一轮应改用新提示词")
        XCTAssertFalse(secondBody.contains("版本甲提示词"), "旧提示词不得残留")
    }

    /// 纯空白提示词：兜底按内置默认全文发送，不发出空提示词。
    func testBlankCustomPromptFallsBackToBuiltinInRequest() async throws {
        let viewModel = PanelViewModelStubForSettings.makePanelViewModel(
            customPrompt: { "  \n " })
        viewModel.inputText = "样本文字"
        viewModel.submit()
        try await Task.sleep(nanoseconds: 300_000_000)
        let body = try XCTUnwrap(StubURLProtocol.capturedRequests.last
            .flatMap { StubURLProtocol.requestBodyData(of: $0) }
            .flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("你是一个翻译引擎"), "空白兜底应发内置默认全文")
        XCTAssertTrue(body.contains("【翻译要求】"), "内置默认应含尾段（全文兜底而非拼合）")
    }
}
