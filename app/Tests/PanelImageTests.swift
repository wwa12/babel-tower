import XCTest
import AppKit
@testable import BabelTower

/// 视图模型的图片规则：粘贴立即重译、上限拒绝、
/// 解码失败提示、⌫ 删末图、呼出带入图片、图文混合重译。
@MainActor
final class PanelImageTests: XCTestCase {

    private var viewModel: PanelViewModel!
    private var pasteboard: NSPasteboard!
    private var settings: ModelServiceSettings!
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        pasteboard = NSPasteboard.withUniqueName()
        settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.panelImage.\(UUID().uuidString)")!
        )
        try settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        viewModel = PanelViewModel(
            engine: engine, settings: settings,
            pasteboard: pasteboard, now: { [self] in now }, collapse: {},
            imageProcessingMode: .synchronous
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
    }

    private func pngData(width: Int = 40, height: Int = 30) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func stubSSE(body: String = "图里的文字") {
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[zh-Hans]]\n\(body)"),
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

    private func waitForTerminal(timeout: TimeInterval = 2) async {
        let terminal = expectation(description: "terminal")
        let cancellable = viewModel.$phase.dropFirst().sink { phase in
            switch phase {
            case .finished, .failed: terminal.fulfill()
            default: break
            }
        }
        await fulfillment(of: [terminal], timeout: timeout)
        cancellable.cancel()
    }

    private func requestBodyStrings() -> [String] {
        StubURLProtocol.capturedRequests.compactMap { request in
            StubURLProtocol.requestBodyData(of: request).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    // MARK: 粘贴图片（只放进输入区，↩ 才翻译；第二张后 ↩ 两图一起译）

    func testPasteImageWaitsForEnter() async throws {
        stubSSE()
        viewModel.handlePasteImage(data: try pngData())
        XCTAssertEqual(viewModel.images.count, 1)
        XCTAssertEqual(viewModel.phase, .composing)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0, "粘贴图片不发请求")
    }

    func testPasteImageThenEnterTranslatesWithContentParts() async throws {
        stubSSE()
        viewModel.handlePasteImage(data: try pngData())
        viewModel.submit()
        await waitForTerminal()
        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(viewModel.images.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        let body = try XCTUnwrap(requestBodyStrings().last)
        XCTAssertTrue(body.contains("image_url"), "请求应携带图片部分")
    }

    func testSecondImageRetranslatesWithBoth() async throws {
        stubSSE()
        viewModel.handlePasteImage(data: try pngData())
        viewModel.submit()
        await waitForTerminal()
        viewModel.handlePasteImage(data: try pngData(width: 20, height: 20))
        XCTAssertEqual(viewModel.phase, .composing, "第二张只追加，等 ↩")
        viewModel.submit()
        await waitForTerminal()
        try await Task.sleep(nanoseconds: 200_000_000)
        let body = try XCTUnwrap(requestBodyStrings().last)
        XCTAssertEqual(body.components(separatedBy: "\"type\":\"image_url\"").count - 1, 2, "两图一起重译")
    }

    /// 图文混合：已有文字时粘图 → 一轮请求同时含 <source> 与图片。
    func testMixedTextAndImageSingleRound() async throws {
        stubSSE()
        viewModel.inputText = "结合图里的语境"
        viewModel.handlePasteImage(data: try pngData())
        viewModel.submit()
        await waitForTerminal()
        try await Task.sleep(nanoseconds: 200_000_000)
        let body = try XCTUnwrap(requestBodyStrings().last)
        XCTAssertTrue(body.contains("<source>"))
        XCTAssertTrue(body.contains("image_url"))
    }

    // MARK: 上限与解码

    func testFifthImageRejectedWithNotice() async throws {
        for _ in 0..<4 {
            viewModel.handlePasteImage(data: try pngData())
        }
        XCTAssertEqual(viewModel.images.count, 4)
        viewModel.handlePasteImage(data: try pngData())
        XCTAssertEqual(viewModel.images.count, 4, "第 5 张拒绝")
        XCTAssertNotNil(viewModel.imageNotice, "应有拒绝提示")
    }

    func testUndecodableImageNoticesAndNotAdded() {
        viewModel.handlePasteImage(data: Data("坏数据".utf8))
        XCTAssertEqual(viewModel.images.count, 0)
        XCTAssertNotNil(viewModel.imageNotice)
    }

    // MARK: ⌫ 删末图（输入框空时 ⌫ 删除最后一张）

    func testBackspaceRemovesLastImageWhenInputEmpty() async throws {
        viewModel.handlePasteImage(data: try pngData())
        viewModel.handlePasteImage(data: try pngData(width: 20, height: 20))
        viewModel.deleteLastImage()
        XCTAssertEqual(viewModel.images.count, 1)
    }

    func testRemoveImageAtIndex() async throws {
        viewModel.handlePasteImage(data: try pngData())
        viewModel.handlePasteImage(data: try pngData(width: 20, height: 20))
        if let first = viewModel.images.first {
            viewModel.removeImage(first.id)
        }
        XCTAssertEqual(viewModel.images.count, 1)
    }

    // MARK: 呼出不带入图片

    func testPanelShowDoesNotBringInImage() async throws {
        pasteboard.setData(try pngData(), forType: .png)
        viewModel.panelWillShow()
        XCTAssertEqual(viewModel.images.count, 0, "呼出不读剪贴板")
    }

    /// 有图片时粘贴文字：只追加等 ↩，不立即翻译（已有内容）。
    func testPasteTextWithExistingImageOnlyAppends() async throws {
        stubSSE()
        viewModel.handlePasteImage(data: try pngData())
        viewModel.submit()
        await waitForTerminal()
        let requestsBefore = StubURLProtocol.capturedRequests.count
        viewModel.handlePaste("补充文字")
        XCTAssertEqual(viewModel.inputText, "补充文字", "文字应追加")
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, requestsBefore,
                       "已有图片时粘文字不应立即发包")
    }

    /// 单文件超过 20MB：拒绝并提示。
    func testOversizeImageFileRejected() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("超大虚构图-\(UUID().uuidString).png")
        try Data(repeating: 0, count: BehaviorConstants.maxImageFileSize + 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.handlePasteImageFile(url: url)
        XCTAssertEqual(viewModel.images.count, 0)
        XCTAssertEqual(viewModel.imageNotice, AppText.panelImageFileTooLarge)
    }

    /// 白名单外的文件（如 PDF）拖入：无反应（与 ⌘V 白名单口径一致）。
    func testNonImageFileIgnored() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("虚构文档-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4 虚构".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.handlePasteImageFile(url: url)
        XCTAssertEqual(viewModel.images.count, 0)
        XCTAssertNil(viewModel.imageNotice, "非图片文件无反应、不提示")
    }

    // MARK: 清空与轮次

    func testClearRoundRemovesImages() async throws {
        viewModel.handlePasteImage(data: try pngData())
        viewModel.clearRound()
        XCTAssertEqual(viewModel.images.count, 0)
        XCTAssertNil(viewModel.imageNotice)
    }
}
