import XCTest
@testable import BabelTower

/// 错误分类测试：HTTP 状态 / URLError / 流中断 → 按用户可理解的语义分类，
/// 提示文案与按钮建议（去设置 / 重试），文案不含 API Key。
final class TranslationFailureTests: XCTestCase {

    // MARK: HTTP 状态映射

    func testHTTPStatusMapping() {
        XCTAssertEqual(TranslationFailure.from(statusCode: 401, detail: nil), .keyRejected(detail: nil))
        XCTAssertEqual(TranslationFailure.from(statusCode: 403, detail: "no access"), .keyRejected(detail: "no access"))
        XCTAssertEqual(TranslationFailure.from(statusCode: 402, detail: nil), .quotaExhausted(detail: nil))
        XCTAssertEqual(TranslationFailure.from(statusCode: 429, detail: nil), .rateLimited)
        XCTAssertEqual(TranslationFailure.from(statusCode: 404, detail: nil), .endpointNotFound(detail: nil))
        XCTAssertEqual(TranslationFailure.from(statusCode: 500, detail: nil), .serviceError(status: 500, detail: nil))
        XCTAssertEqual(TranslationFailure.from(statusCode: 503, detail: "busy"), .serviceError(status: 503, detail: "busy"))
        XCTAssertEqual(TranslationFailure.from(statusCode: 418, detail: nil), .serviceError(status: 418, detail: nil))
    }

    // MARK: URLError 映射

    func testURLErrorMapping() {
        XCTAssertEqual(TranslationFailure.from(error: URLError(.timedOut)), .networkUnavailable)
        XCTAssertEqual(
            TranslationFailure.from(error: URLError(.notConnectedToInternet)),
            .networkUnavailable
        )
        XCTAssertEqual(TranslationFailure.from(error: URLError(.cannotConnectToHost)), .networkUnavailable)
    }

    // MARK: 用户文案与按钮建议

    func testUserMessagesContainExpectedSemantics() {
        XCTAssertTrue(TranslationFailure.keyRejected(detail: "bad key").userMessage.contains("API Key"))
        XCTAssertTrue(TranslationFailure.keyRejected(detail: "bad key").userMessage.contains("bad key"))
        XCTAssertTrue(TranslationFailure.quotaExhausted(detail: nil).userMessage.contains("额度"))
        XCTAssertTrue(TranslationFailure.rateLimited.userMessage.contains("稍后再试"))
        XCTAssertTrue(TranslationFailure.endpointNotFound(detail: nil).userMessage.contains("404"))
        XCTAssertTrue(TranslationFailure.serviceError(status: 503, detail: nil).userMessage.contains("503"))
        XCTAssertTrue(TranslationFailure.networkUnavailable.userMessage.contains("网络"))
        XCTAssertTrue(TranslationFailure.firstTokenTimeout.userMessage.contains("60"))
        XCTAssertTrue(TranslationFailure.streamInterrupted(detail: nil).userMessage.contains("中断"))
    }

    func testButtonSuggestions() {
        // 去设置：Key 无效、额度用完、配置坏
        XCTAssertTrue(TranslationFailure.keyRejected(detail: nil).suggestsSettings)
        XCTAssertTrue(TranslationFailure.quotaExhausted(detail: nil).suggestsSettings)
        XCTAssertTrue(TranslationFailure.requestBuildFailed.suggestsSettings)
        XCTAssertFalse(TranslationFailure.keyRejected(detail: nil).suggestsRetry)

        // 重试：网络、超时、5xx、流中断、限流（手动重试，不自动）
        XCTAssertTrue(TranslationFailure.networkUnavailable.suggestsRetry)
        XCTAssertTrue(TranslationFailure.firstTokenTimeout.suggestsRetry)
        XCTAssertTrue(TranslationFailure.serviceError(status: 503, detail: nil).suggestsRetry)
        XCTAssertTrue(TranslationFailure.streamInterrupted(detail: nil).suggestsRetry)
        XCTAssertTrue(TranslationFailure.rateLimited.suggestsRetry)
        XCTAssertFalse(TranslationFailure.networkUnavailable.suggestsSettings)
    }
}
