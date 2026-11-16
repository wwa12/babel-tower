import XCTest
import AppKit
@testable import BabelTower

/// 翻译历史：存储（总量上限与裁剪、去重、持久化、清空）与浮窗接线（完成即存、载入不重新请求）。
/// 存储目录一律用临时目录，不碰真实历史。
@MainActor
final class HistoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("巴别塔历史测试-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ text: String, images: [ProcessedImage] = [],
                        manual: TranslationLanguage? = nil) -> HistoryRecord {
        HistoryRecord(inputText: text, images: images, resultText: "译文：\(text)",
                      targetLanguage: manual ?? .zhHans, manualTarget: manual,
                      marker: .language(manual ?? .zhHans))
    }

    private func image(bytes: Int, seed: UInt8 = 1) -> ProcessedImage {
        ProcessedImage(data: Data(repeating: seed, count: bytes), mimeType: "image/jpeg")
    }

    func testAddedEntriesAreNewestFirstAndPersistAcrossRestart() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(directory: directory, now: { clock })
        await store.waitForPendingWork()
        store.add(record("第一条"))
        clock.addTimeInterval(1)
        store.add(record("第二条", images: [image(bytes: 100)]))
        XCTAssertEqual(store.entries.map(\.inputText), ["第二条", "第一条"])
        await store.waitForPendingWork()

        let reopened = HistoryStore(directory: directory)
        await reopened.waitForPendingWork()
        XCTAssertTrue(reopened.isLoaded)
        XCTAssertEqual(reopened.entries.map(\.inputText), ["第二条", "第一条"], "重开后记录仍在，时间倒序")
        let loadedImages = reopened.loadImages(of: reopened.entries[0])
        XCTAssertEqual(loadedImages, [image(bytes: 100)], "图片按发送给模型的版本原样存回")
    }

    func testSameContentKeepsOnlyNewest() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(directory: directory, now: { clock })
        store.add(record("同一句"))
        clock.addTimeInterval(1)
        store.add(record("另一句"))
        clock.addTimeInterval(1)
        store.add(record("同一句"))
        XCTAssertEqual(store.entries.map(\.inputText), ["同一句", "另一句"])
        await store.waitForPendingWork()
        let reopened = HistoryStore(directory: directory)
        await reopened.waitForPendingWork()
        XCTAssertEqual(reopened.entries.count, 2, "旧的重复记录在磁盘上也被删除")
    }

    func testDifferentTargetLanguageIsDifferentContent() {
        let store = HistoryStore(directory: directory)
        store.add(record("同一句"))
        store.add(record("同一句", manual: .ja))
        XCTAssertEqual(store.entries.count, 2)
    }

    /// 超过上限：从最旧整条删除，直到降到裁剪目标以下（不限条数）。
    func testOverLimitPrunesOldestUntilBelowTarget() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        // 上限 5000 字节，裁剪到 3000 以下；每条约 1000 字节图片 + 几百字节 JSON
        let store = HistoryStore(directory: directory, limitBytes: 5_000, pruneTargetBytes: 3_000,
                                 now: { clock })
        for index in 0..<5 {
            store.add(record("第\(index)条", images: [image(bytes: 1_000, seed: UInt8(index))]))
            clock.addTimeInterval(1)
            await store.waitForPendingWork()
        }
        let usage = await store.diskUsageBytes()
        XCTAssertLessThanOrEqual(usage, 5_000, "总占用不超过上限")
        XCTAssertFalse(store.entries.contains { $0.inputText == "第0条" }, "最旧的先删")
        XCTAssertTrue(store.entries.contains { $0.inputText == "第4条" }, "最新的保留")
        // 删掉的条目文件也不在磁盘上
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, store.entries.count, "删掉的记录文件不残留")
        XCTAssertEqual(files.filter { $0.hasSuffix(".jpg") }.count, store.entries.count, "删掉的图片文件不残留")
        let reopened = HistoryStore(directory: directory, limitBytes: 5_000, pruneTargetBytes: 3_000)
        await reopened.waitForPendingWork()
        XCTAssertEqual(reopened.entries.map(\.inputText), store.entries.map(\.inputText))
    }

    func testPruneRemovesDownToTargetInOneGo() async {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(directory: directory, limitBytes: 10_000, pruneTargetBytes: 4_000,
                                 now: { clock })
        for index in 0..<9 {
            store.add(record("第\(index)条", images: [image(bytes: 1_000, seed: UInt8(index))]))
            clock.addTimeInterval(1)
            await store.waitForPendingWork()
        }
        let usage = await store.diskUsageBytes()
        XCTAssertLessThan(usage, 10_000)
        // 第 9 条写入后超过 10000 → 一次删到 4000 以下，只剩最新的 2–3 条
        XCTAssertLessThanOrEqual(store.entries.count, 4)
        XCTAssertEqual(store.entries.first?.inputText, "第8条")
    }

    func testClearAllRemovesEntriesAndFiles() async {
        let store = HistoryStore(directory: directory)
        store.add(record("要清空的", images: [image(bytes: 50)]))
        await store.waitForPendingWork()
        store.clearAll()
        await store.waitForPendingWork()
        XCTAssertTrue(store.entries.isEmpty)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(files.isEmpty, "图片与记录文件都被删除：\(files)")
        let reopened = HistoryStore(directory: directory)
        await reopened.waitForPendingWork()
        XCTAssertTrue(reopened.entries.isEmpty)
    }
}

/// 浮窗接线：完成即存、失败不存、开关关闭不存、载入不重新请求。
@MainActor
final class PanelHistoryTests: XCTestCase {

    private var directory: URL!
    private var store: HistoryStore!
    private var viewModel: PanelViewModel!
    private var pasteboard: NSPasteboard!
    private var saveEnabled = true
    private var collapsed = false

    override func setUp() async throws {
        StubURLProtocol.resetStreamingState()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("巴别塔历史测试-\(UUID().uuidString)", isDirectory: true)
        store = HistoryStore(directory: directory)
        await store.waitForPendingWork()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.history.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        pasteboard = NSPasteboard.withUniqueName()
        saveEnabled = true
        collapsed = false
        viewModel = PanelViewModel(
            engine: TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config))),
            settings: settings,
            pasteboard: pasteboard,
            collapse: { [unowned self] in collapsed = true },
            imageProcessingMode: .synchronous,
            history: store,
            shouldSaveHistory: { [unowned self] in saveEnabled }
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
        try? FileManager.default.removeItem(at: directory)
    }

    private func stub(_ content: String) {
        let json = String(data: try! JSONEncoder().encode(["choices": [["delta": ["content": content]]]]),
                          encoding: .utf8)!
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data("data: \(json)\n\n".utf8)),
            .immediate(Data("data: [DONE]\n\n".utf8)),
        ] }
    }

    private func waitForTerminal() async {
        for _ in 0..<60 {
            switch viewModel.phase {
            case .finished, .failed: return
            default: try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        XCTFail("超时未结束")
    }

    func testFinishedRoundIsSaved() async {
        stub("[[ja]]\nこんにちは")
        viewModel.inputText = "你好"
        viewModel.setTargetMode(.manual(.ja))
        viewModel.submit()
        await waitForTerminal()
        let entry = try? XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry?.inputText, "你好")
        XCTAssertEqual(entry?.resultText, "こんにちは")
        XCTAssertEqual(entry?.targetLanguage, .ja)
        XCTAssertEqual(entry?.manualTarget, .ja)
    }

    func testFailedRoundIsNotSaved() async {
        StubURLProtocol.streamHandler = { _ in [
            .immediate(Data(#"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#.utf8) + Data("\n\n".utf8)),
        ] }
        viewModel.inputText = "会失败"
        viewModel.submit()
        await waitForTerminal()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSettingOffSkipsSaving() async {
        saveEnabled = false
        stub("[[zh-Hans]]\n你好")
        viewModel.inputText = "Hello"
        viewModel.submit()
        await waitForTerminal()
        XCTAssertTrue(store.entries.isEmpty, "关闭保存后不再新存")
    }

    /// 载入：原文、译文、语言回到浮窗，不发新请求；此时 ↩ 复制并收起。
    func testLoadEntryRestoresRoundWithoutRequestAndEnterCopies() async throws {
        stub("[[ja]]\nこんにちは")
        viewModel.inputText = "你好"
        viewModel.setTargetMode(.manual(.ja))
        viewModel.submit()
        await waitForTerminal()
        viewModel.clearRound()
        XCTAssertEqual(viewModel.inputText, "")
        let requestsBefore = StubURLProtocol.capturedRequests.count

        viewModel.toggleHistory()
        XCTAssertTrue(viewModel.isShowingHistory)
        XCTAssertEqual(viewModel.historySelectionID, store.entries.first?.id, "打开时选中最新一条")
        viewModel.confirmHistorySelection()

        XCTAssertFalse(viewModel.isShowingHistory, "载入后回到翻译界面")
        XCTAssertEqual(viewModel.inputText, "你好")
        XCTAssertEqual(viewModel.resultText, "こんにちは")
        XCTAssertEqual(viewModel.targetMode, .manual(.ja))
        XCTAssertEqual(viewModel.phase, .finished)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, requestsBefore, "载入不重新请求")

        viewModel.submit()
        XCTAssertTrue(collapsed, "载入后 ↩ 即复制并收起")
        XCTAssertEqual(pasteboard.string(forType: .string), "こんにちは")
    }

    func testLoadEntryRestoresImages() async throws {
        stub("[[zh-Hans]]\n图里的字")
        viewModel.handlePasteImage(data: try Self.pngData())
        viewModel.submit()
        await waitForTerminal()
        let saved = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(saved.images.count, 1)
        await store.waitForPendingWork()
        viewModel.clearRound()
        viewModel.loadHistoryEntry(saved)
        XCTAssertEqual(viewModel.images.count, 1, "图片随记录载入")
    }

    func testSelectionMovesWithinBounds() async {
        for text in ["一", "二", "三"] {
            stub("[[en]]\n\(text)")
            viewModel.clearRound()
            viewModel.inputText = text
            viewModel.submit()
            await waitForTerminal()
        }
        viewModel.toggleHistory()
        XCTAssertEqual(store.entries.count, 3)
        viewModel.moveHistorySelection(by: -1)
        XCTAssertEqual(viewModel.historySelectionID, store.entries[0].id, "到顶不越界")
        viewModel.moveHistorySelection(by: 1)
        viewModel.moveHistorySelection(by: 1)
        viewModel.moveHistorySelection(by: 1)
        XCTAssertEqual(viewModel.historySelectionID, store.entries[2].id, "到底不越界")
        viewModel.toggleHistory()
        XCTAssertFalse(viewModel.isShowingHistory)
    }

    func testShowResetsHistoryList() {
        viewModel.toggleHistory()
        viewModel.panelWillShow()
        XCTAssertFalse(viewModel.isShowingHistory, "每次呼出回到翻译界面")
    }

    static func pngData() throws -> Data {
        let context = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:]))
    }
}

/// 历史列表按键与 ⌘Y。
final class HistoryKeyRouterTests: XCTestCase {

    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                        history: Bool = false, pinned: Bool = false) -> PanelKeyRouter.Action {
        PanelKeyRouter.action(keyCode: keyCode, modifiers: modifiers, hasMarkedText: false,
                              focus: .input, hasResultSelection: false, hasInputSelection: false,
                              isPinned: pinned, isShowingHistory: history)
    }

    func testCommandYTogglesHistory() {
        XCTAssertEqual(action(16, .command), .toggleHistory)
        XCTAssertEqual(action(16, .command, history: true), .toggleHistory)
    }

    func testListKeysWhileShowingHistory() {
        XCTAssertEqual(action(126, history: true), .moveHistorySelection(-1))
        XCTAssertEqual(action(125, history: true), .moveHistorySelection(1))
        XCTAssertEqual(action(36, history: true), .confirmHistorySelection)
        XCTAssertEqual(action(53, history: true), .toggleHistory, "Esc 关闭列表而不是收起")
        XCTAssertEqual(action(53, history: true, pinned: true), .toggleHistory)
    }

    func testTranslationShortcutsInertWhileShowingHistory() {
        XCTAssertEqual(action(15, .command, history: true), .passthrough, "⌘R 不作用于背后内容")
        XCTAssertEqual(action(9, .command, history: true), .passthrough, "⌘V 不作用于背后内容")
        XCTAssertEqual(action(43, .command, history: true), .openSettings)
    }

    func testArrowsPassThroughWithoutHistory() {
        XCTAssertEqual(action(126), .passthrough, "列表外 ↑ 交给输入框移动光标")
    }
}

/// 把手栏关闭按钮 = 收起（浮窗常驻，不真正关闭）。
@MainActor
final class PanelCloseButtonTests: XCTestCase {

    func testCloseButtonCollapsesInsteadOfClosing() {
        let defaults = UserDefaults(suiteName: "test.close.\(UUID().uuidString)")!
        let controller = PanelController(panelContent: { NSView() }, settingsContent: { NSView() },
                                          defaults: defaults)
        controller.showPanel()
        XCTAssertTrue(controller.isPanelVisible)
        let panel = controller.panelForTesting
        XCTAssertFalse(controller.windowShouldClose(panel), "浮窗不允许真正关闭")
        XCTAssertFalse(controller.isPanelVisible, "点关闭按钮即收起")
        controller.showPanel()
        XCTAssertTrue(controller.isPanelVisible, "收起后可再次呼出")
        controller.hidePanel()
    }

    func testTitleShowsNameAndVersion() {
        XCTAssertTrue(AppText.panelTitle.hasPrefix("巴别塔"))
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            XCTAssertTrue(AppText.panelTitle.contains(version))
        }
    }
}
