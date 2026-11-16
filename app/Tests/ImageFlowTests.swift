import XCTest
import AppKit
@testable import BabelTower

/// 图片流程测试：引擎请求体（图文混合）+ 视图模型图片规则。
@MainActor
final class ImageFlowTests: XCTestCase {

    // MARK: 引擎请求体（用户消息、请求参数）

    func testMixedContentBodyPartsOrder() throws {
        let config = ResolvedServiceConfig(
            presetID: "openai", displayName: "OpenAI", model: "虚构模型",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key", disableThinkingParameters: [:], supportsImages: true
        )
        let imageA = ProcessedImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let imageB = ProcessedImage(data: Data([4, 5]), mimeType: "image/jpeg")
        let body = TranslationEngine.translationBody(
            text: "看图说话", images: [imageA, imageB], target: .manual(.zhHans), config: config
        )

        let bodyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        XCTAssertEqual(bodyObject["max_tokens"] as? Int, BehaviorConstants.imageOutputTokenLimit,
                       "含图片取 4096（且 ≥ 文字规则）")
        let messages = try XCTUnwrap(bodyObject["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages[1])
        let parts = try XCTUnwrap(userMessage["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 3)
        // 文字在 <source> 标签，图片按添加顺序附在消息里
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertTrue(try XCTUnwrap(parts[0]["text"] as? String).contains("<source>\n看图说话\n</source>"))
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let firstURL = try XCTUnwrap(try XCTUnwrap(parts[1]["image_url"] as? [String: Any])["url"] as? String)
        XCTAssertTrue(firstURL.hasPrefix("data:image/png;base64,"))
        let secondURL = try XCTUnwrap(try XCTUnwrap(parts[2]["image_url"] as? [String: Any])["url"] as? String)
        XCTAssertTrue(secondURL.hasPrefix("data:image/jpeg;base64,"))
    }

    /// 图片独立成轮（无文字）：只有图片部分，不出现空 <source>。
    func testImageOnlyBodyHasNoEmptySource() throws {
        let config = ResolvedServiceConfig(
            presetID: "openai", displayName: "OpenAI", model: "虚构模型",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key", disableThinkingParameters: [:], supportsImages: true
        )
        let body = TranslationEngine.translationBody(
            text: "", images: [ProcessedImage(data: Data([9]), mimeType: "image/png")],
            target: .automatic(main: .zhHans, foreign: .en), config: config
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["type"] as? String, "image_url")
    }

    /// 模型不支持图片的判定（提示更换模型，附去设置）。
    func testImageSupportFailureMapping() {
        let unsupported = ResolvedServiceConfig(
            presetID: "custom", displayName: "自定义", model: "虚构模型",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key", disableThinkingParameters: [:], supportsImages: false
        )
        XCTAssertNotNil(PanelViewModel.imageSupportFailure(for: unsupported, hasImages: true))
        let supported = ResolvedServiceConfig(
            presetID: "custom", displayName: "自定义", model: "虚构模型",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key", disableThinkingParameters: [:], supportsImages: true
        )
        XCTAssertNil(PanelViewModel.imageSupportFailure(for: supported, hasImages: true))
        XCTAssertNil(PanelViewModel.imageSupportFailure(for: unsupported, hasImages: false),
                     "没有图片时不检查")
    }
}
