import XCTest
import AppKit
@testable import BabelTower

/// Key 内存缓存、Key 自动保存、浮窗 ⌘, 打开设置、预热节流、图片后台处理。
@MainActor
final class ReviewBatch1Tests: XCTestCase {

    /// 记录读写次数的 Key 存储替身。
    final class CountingKeyStore: APIKeyStore {
        var storage: [String: String] = [:]
        var loads = 0
        var saves = 0
        var failNextLoad = false

        func saveAPIKey(_ key: String, forAccount account: String) throws {
            saves += 1
            storage[account] = key
        }

        func loadAPIKey(forAccount account: String) throws -> String? {
            loads += 1
            if failNextLoad {
                failNextLoad = false
                throw KeychainStoreError.unexpectedStatus(-128)   // 用户在授权框点了拒绝
            }
            return storage[account]
        }

        func deleteAPIKey(forAccount account: String) throws {
            storage[account] = nil
        }
    }

    private var store: CountingKeyStore!
    private var settings: ModelServiceSettings!

    override func setUp() async throws {
        store = CountingKeyStore()
        settings = ModelServiceSettings(
            keyStore: store,
            defaults: UserDefaults(suiteName: "test.batch1.\(UUID().uuidString)")!
        )
    }

    // MARK: A11 内存缓存：每次呼出 / 翻译不再访问钥匙串

    func testKeyIsReadFromKeychainOnlyOnce() throws {
        store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")] = "虚构Key"
        for _ in 0..<5 {
            XCTAssertEqual(try settings.resolvedConfig().apiKey, "虚构Key")
        }
        XCTAssertEqual(store.loads, 1, "同一预设的 Key 只应读一次钥匙串")
    }

    func testMissingKeyIsAlsoCached() {
        for _ in 0..<3 {
            XCTAssertThrowsError(try settings.resolvedConfig())
        }
        XCTAssertEqual(store.loads, 1)
    }

    func testSettingKeyUpdatesCacheWithoutReading() throws {
        try settings.setAPIKey("新Key", forPresetID: "openai")
        XCTAssertEqual(try settings.resolvedConfig().apiKey, "新Key")
        XCTAssertEqual(store.loads, 0, "刚写入的 Key 直接用缓存")
        try settings.setAPIKey("", forPresetID: "openai")
        XCTAssertThrowsError(try settings.resolvedConfig()) { error in
            XCTAssertEqual(error as? ServiceConfigError, .missingAPIKey)
        }
    }

    func testFailedReadIsNotCached() throws {
        store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")] = "虚构Key"
        store.failNextLoad = true
        XCTAssertThrowsError(try settings.resolvedConfig(), "读取失败（如拒绝授权）要报出来")
        XCTAssertEqual(try settings.resolvedConfig().apiKey, "虚构Key", "失败不缓存，下次重新读")
        XCTAssertEqual(store.loads, 2)
    }

    // MARK: A2 自动保存：停止输入后写入，连续输入只写最后一次

    func testAutosaveDebouncesAndReportsSaved() async throws {
        settings.scheduleAPIKeySave("s", forPresetID: "openai", delay: 0.2)
        settings.scheduleAPIKeySave("sk", forPresetID: "openai", delay: 0.2)
        settings.scheduleAPIKeySave("sk-虚构", forPresetID: "openai", delay: 0.2)
        XCTAssertEqual(store.saves, 0, "输入过程中不写")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(store.saves, 1, "只写最后一次")
        XCTAssertEqual(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")], "sk-虚构")
        XCTAssertEqual(settings.apiKeySaveStatus, .saved(presetID: "openai"))
        XCTAssertEqual(try settings.resolvedConfig().apiKey, "sk-虚构")
    }

    func testAutosaveSkipsUnchangedKey() async throws {
        try settings.setAPIKey("已有Key", forPresetID: "openai")
        let savesBefore = store.saves
        settings.scheduleAPIKeySave("已有Key", forPresetID: "openai", delay: 0.05)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.saves, savesBefore, "内容没变不重复写钥匙串（打开设置载入 Key 时不应触发写入）")
    }

    func testAutosaveKeepsPresetCapturedAtTypingTime() async throws {
        settings.scheduleAPIKeySave("百炼Key", forPresetID: "dashscope", delay: 0.1)
        settings.selectedPresetID = "openai"
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "dashscope")], "百炼Key")
        XCTAssertNil(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")])
    }

    /// 授权被拒导致输入框为空：自动保存不能把空值当"清空"去删钥匙串里的 Key。
    func testAutosaveDoesNotDeleteKeyThatFailedToLoad() async throws {
        store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")] = "真Key"
        store.failNextLoad = true
        XCTAssertThrowsError(try settings.apiKey(forPresetID: "openai"))
        settings.scheduleAPIKeySave("", forPresetID: "openai", delay: 0.05)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")], "真Key")
    }

    /// 关窗口 / 切服务时立即写入还在等待的 Key；之后再 flush 不会重复写。
    func testFlushWritesPendingSaveImmediatelyOnce() throws {
        settings.scheduleAPIKeySave("刚输入的Key", forPresetID: "openai", delay: 10)
        settings.flushPendingAPIKeySaves()
        XCTAssertEqual(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "openai")], "刚输入的Key")
        let saves = store.saves
        settings.flushPendingAPIKeySaves()
        XCTAssertEqual(store.saves, saves)
    }

    /// 两个服务各自等待中的保存互不取消。
    func testPendingSavesArePerPreset() throws {
        settings.scheduleAPIKeySave("百炼Key", forPresetID: "dashscope", delay: 10)
        settings.scheduleAPIKeySave("方舟Key", forPresetID: "volcengineArk", delay: 10)
        settings.flushPendingAPIKeySaves()
        XCTAssertEqual(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "dashscope")], "百炼Key")
        XCTAssertEqual(store.storage[ModelServiceSettings.apiKeyAccount(forPresetID: "volcengineArk")], "方舟Key")
    }

    /// 重新输入时"已保存"提示消失。
    func testSaveStatusClearsWhileTyping() throws {
        settings.scheduleAPIKeySave("k1", forPresetID: "openai", delay: 10)
        settings.flushPendingAPIKeySaves()
        XCTAssertEqual(settings.apiKeySaveStatus, .saved(presetID: "openai"))
        settings.scheduleAPIKeySave("k12", forPresetID: "openai", delay: 10)
        XCTAssertEqual(settings.apiKeySaveStatus, APIKeySaveStatus.none)
    }

    // MARK: A4 浮窗 ⌘, 打开设置

    func testCommandCommaOpensSettings() {
        let action = PanelKeyRouter.action(
            keyCode: 43, modifiers: .command, hasMarkedText: false, focus: .input,
            hasResultSelection: false, hasInputSelection: false)
        XCTAssertEqual(action, .openSettings)
    }

    func testCommandCommaPassesThroughWhileComposing() {
        let action = PanelKeyRouter.action(
            keyCode: 43, modifiers: .command, hasMarkedText: true, focus: .input,
            hasResultSelection: false, hasInputSelection: false)
        XCTAssertEqual(action, .passthrough)
    }

    // MARK: A10 预热节流：同一地址 60 秒内只预热一次

    func testWarmupIsThrottledPerEndpoint() {
        var throttle = ConnectionWarmer.Throttle()
        let endpoint = URL(string: "https://api.fictional.example/v1/chat/completions")!
        let other = URL(string: "https://other.fictional.example/v1/chat/completions")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(throttle.shouldWarm(endpoint, now: start))
        XCTAssertFalse(throttle.shouldWarm(endpoint, now: start.addingTimeInterval(30)))
        XCTAssertTrue(throttle.shouldWarm(other, now: start.addingTimeInterval(30)), "换了服务地址要重新预热")
        XCTAssertTrue(throttle.shouldWarm(endpoint, now: start.addingTimeInterval(61)))
    }

    // MARK: A8 图片后台处理

    private static func bodyString(_ request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8)
    }

    private func makeBackgroundViewModel(collapse: @escaping () -> Void = {}) throws -> PanelViewModel {
        StubURLProtocol.resetStreamingState()
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data(#"data: {"choices":[{"delta":{"content":"[[zh-Hans]]\n图里的字"}}]}"#.utf8) + Data("\n\n".utf8)),
            .immediate(Data("data: [DONE]\n\n".utf8)),
        ] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        return PanelViewModel(
            engine: TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config))),
            settings: settings,
            pasteboard: NSPasteboard.withUniqueName(), now: { Date() }, collapse: collapse,
            imageProcessingMode: .background)
    }

    private func pngData(width: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 10))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    /// 处理中按 ↩：处理完统一发一次请求。
    func testBackgroundProcessingShowsPendingThenTranslatesOnce() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.handlePasteImage(data: pngData(width: 30))
        XCTAssertEqual(viewModel.pendingImageCount, 1, "粘贴后立即显示占位，不等处理完")
        XCTAssertTrue(viewModel.images.isEmpty)
        viewModel.submit()
        XCTAssertNotEqual(viewModel.phase, .translating, "处理完之前不发请求")
        await viewModel.waitForPendingImages()
        XCTAssertEqual(viewModel.pendingImageCount, 0)
        XCTAssertEqual(viewModel.images.count, 1)
        XCTAssertEqual(viewModel.phase, .translating, "处理完兑现 ↩")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "只发一次请求")
    }

    /// 连续粘贴多张（或拖入多个文件，逐个回调）：全部处理完只发一次请求，且带齐所有图。
    func testSeveralQuickPastesSendOneCompleteRequest() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.handlePasteImage(data: pngData(width: 11))
        viewModel.handlePasteImage(data: pngData(width: 22))
        viewModel.handlePasteImage(data: pngData(width: 33))
        viewModel.submit()
        await viewModel.waitForPendingImages()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "中途不发缺图的请求")
        let body = try XCTUnwrap(StubURLProtocol.capturedRequests.first.flatMap(Self.bodyString))
        XCTAssertEqual(body.components(separatedBy: ";base64,").count - 1, 3, "请求里带齐 3 张图")
    }

    /// 上一轮已完成，粘贴新图后（还在处理）按 ↩：不能复制旧译文并收起。
    func testEnterWhileNewImageProcessingDoesNotCopyOldResult() async throws {
        var collapsed = false
        let viewModel = try makeBackgroundViewModel(collapse: { collapsed = true })
        viewModel.inputText = "Hello"
        viewModel.forceFinishedForTesting(marker: .language(.zhHans), body: "旧译文")
        viewModel.handlePasteImage(data: pngData(width: 20))
        XCTAssertEqual(viewModel.phase, .composing, "内容已变，离开完成态")
        viewModel.submit()
        XCTAssertFalse(collapsed, "不能复制旧译文并收起")
        await viewModel.waitForPendingImages()
        XCTAssertEqual(viewModel.phase, .translating)
    }

    /// 图片处理中切 ⌘2 再按 ↩，图片解码失败：↩ 的意图不丢，照样按文字与新语言翻译。
    func testEnterWhileProcessingSurvivesUndecodableImage() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.inputText = "Hello"
        viewModel.handlePasteImage(data: Data("坏数据".utf8))
        viewModel.setTargetMode(.manual(.zhHant))
        viewModel.submit()
        await viewModel.waitForPendingImages()
        XCTAssertEqual(viewModel.imageNotice, AppText.panelImageUndecodable)
        XCTAssertEqual(viewModel.phase, .translating, "↩ 的意图在图片处理完后兑现")
        XCTAssertEqual(viewModel.targetMode, .manual(.zhHant))
    }

    /// 只粘贴图片不按 ↩：处理完也不发请求。
    func testBackgroundImageWithoutEnterSendsNothing() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.handlePasteImage(data: pngData(width: 30))
        await viewModel.waitForPendingImages()
        XCTAssertEqual(viewModel.phase, .composing)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0)
    }

    /// 只有占位图时粘贴文字：按"已有内容"处理——不立即发纯文字请求，不重置手动语言。
    func testPastingTextWhileOnlyPlaceholdersAppends() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.handlePasteImage(data: pngData(width: 20))
        viewModel.setTargetMode(.manual(.ja))
        viewModel.handlePaste("配图说明")
        XCTAssertEqual(viewModel.targetMode, .manual(.ja), "手动语言不被重置")
        XCTAssertNotEqual(viewModel.phase, .translating, "不先发纯文字请求")
        viewModel.submit()
        await viewModel.waitForPendingImages()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    func testBackgroundBatchesKeepAddingOrder() async throws {
        let viewModel = try makeBackgroundViewModel()
        for width in [11, 22, 33] {
            viewModel.handlePasteImage(data: pngData(width: width))
        }
        XCTAssertEqual(viewModel.pendingImageCount, 3)
        await viewModel.waitForPendingImages()
        let widths = viewModel.images.compactMap { NSBitmapImageRep(data: $0.processed.data)?.pixelsWide }
        XCTAssertEqual(widths, [11, 22, 33], "图片顺序必须等于添加顺序")
    }

    func testPendingImagesCountTowardFourImageLimit() async throws {
        let viewModel = try makeBackgroundViewModel()
        for _ in 0..<5 {
            viewModel.handlePasteImage(data: pngData(width: 20))
        }
        XCTAssertEqual(viewModel.pendingImageCount, 4)
        XCTAssertEqual(viewModel.imageNotice, AppText.panelTooManyImages)
        await viewModel.waitForPendingImages()
        XCTAssertEqual(viewModel.images.count, 4)
    }

    func testClearingDiscardsImagesStillProcessing() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.handlePasteImage(data: pngData(width: 20))
        viewModel.clearRound()
        XCTAssertEqual(viewModel.pendingImageCount, 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(viewModel.images.isEmpty, "⌘N 之后迟到的图片不应再出现")
        XCTAssertEqual(viewModel.phase, .empty)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0)
    }

    func testEnterWhileImageProcessingDoesNotSendIncompleteRequest() async throws {
        let viewModel = try makeBackgroundViewModel()
        viewModel.inputText = "配图说明"
        viewModel.handlePasteImage(data: pngData(width: 20))
        viewModel.submit()
        XCTAssertNotEqual(viewModel.phase, .translating, "图片没处理完时 ↩ 不先发一个缺图的请求")
        await viewModel.waitForPendingImages()
        XCTAssertEqual(viewModel.phase, .translating)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }
}
