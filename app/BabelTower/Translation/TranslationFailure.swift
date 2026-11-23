import Foundation

/// 翻译失败的分类，。界面按分类决定提示文案与按钮（去设置 / 重试）。
enum TranslationFailure: Error, Equatable, Sendable {
    /// Key 无效或无权访问（401/403）→ 去设置
    case keyRejected(detail: String?)
    /// 额度用完 / 需要付费（402）→ 去设置
    case quotaExhausted(detail: String?)
    /// 被服务限流 → 稍后再试，不自动重试
    case rateLimited
    /// 接口地址不存在（404）
    case endpointNotFound(detail: String?)
    /// 其他服务端错误（5xx / 未归类状态码）
    case serviceError(status: Int, detail: String?)
    /// 没有网络 / 连接失败 / 连接超时 → 重试
    case networkUnavailable
    /// 首字超过 60 秒→ 重试
    case firstTokenTimeout
    /// 流式输出中断：已发出的译文增量有效，界面标注"未完成"→ 重试
    case streamInterrupted(detail: String?)
    /// 请求无法构造（配置问题）→ 去设置
    case requestBuildFailed
    /// 服务配置未就绪（没 Key / 缺模型名 / 地址问题）→ 去设置（第一行）
    case configuration(ServiceConfigError)
    /// 所选模型不支持图片输入 → 去设置换模型
    case modelDoesNotSupportImages
    /// 模型拒绝处理这段内容（content_filter）→ 显示"模型拒绝了这段内容"，不留空白
    case modelRefused

    /// 用户可见提示（AppText 集中存放；detail 为服务端原因，已在上游截断）。
    var userMessage: String {
        switch self {
        case .keyRejected(let detail):
            return AppText.testKeyRejected + Self.detailSuffix(detail)
        case .quotaExhausted(let detail):
            return AppText.testPaymentRequired + Self.detailSuffix(detail)
        case .rateLimited:
            return AppText.testRateLimited
        case .endpointNotFound(let detail):
            return AppText.testNotFound + Self.detailSuffix(detail)
        case .serviceError(let status, let detail):
            let prefix = status >= 500 ? AppText.testServerErrorPrefix : AppText.testHTTPErrorPrefix
            return prefix + "\(status)）。" + Self.detailSuffix(detail)
        case .networkUnavailable:
            return AppText.testNetworkDown
        case .firstTokenTimeout:
            return AppText.translateFirstTokenTimeout
        case .streamInterrupted(let detail):
            return AppText.translateStreamInterrupted + Self.detailSuffix(detail)
        case .requestBuildFailed:
            return AppText.testRequestBuildFailed
        case .configuration(let error):
            return Self.message(for: error)
        case .modelDoesNotSupportImages:
            return AppText.translateModelNoImages
        case .modelRefused:
            return AppText.translateModelRefused
        }
    }

    /// 是否应附「去设置」按钮。Key / 额度 / 配置问题。
    var suggestsSettings: Bool {
        switch self {
        case .keyRejected, .quotaExhausted, .requestBuildFailed,
             .configuration, .modelDoesNotSupportImages:
            return true
        default:
            return false
        }
    }

    /// 是否应附「重试」按钮（手动重试；限流也不自动重试）。
    var suggestsRetry: Bool {
        switch self {
        case .rateLimited, .endpointNotFound, .serviceError,
             .networkUnavailable, .firstTokenTimeout, .streamInterrupted: true
        default: false
        }
    }

    /// 服务配置错误的用户提示（提示并给出「去设置」）。
    private static func message(for error: ServiceConfigError) -> String {
        switch error {
        case .missingAPIKey: AppText.testNeedAPIKey
        case .missingModel: AppText.testNeedModel
        case .missingBaseURL: AppText.testNeedBaseURL
        case .invalidBaseURL: AppText.testInvalidBaseURL
        }
    }

    /// HTTP 状态码到分类的映射（非 2xx 时）。detail 为服务端 error.message（可为 nil）。
    static func from(statusCode: Int, detail: String?) -> TranslationFailure {
        switch statusCode {
        case 401, 403: .keyRejected(detail: detail)
        case 402: .quotaExhausted(detail: detail)
        case 429: .rateLimited
        case 404: .endpointNotFound(detail: detail)
        default: .serviceError(status: statusCode, detail: detail)
        }
    }

    /// 网络层错误到分类的映射：全部网络层错误统一归"网络问题，可重试"——
    /// 断网、DNS、连接失败、连接超时对用户没有行动差异（都是检查网络后重试），
    /// 首字 60 秒超时是引擎层的看门狗，不走此映射。
    static func from(error _: URLError) -> TranslationFailure {
        .networkUnavailable
    }

    private static func detailSuffix(_ detail: String?) -> String {
        detail.map { "：\($0)" } ?? ""
    }
}
