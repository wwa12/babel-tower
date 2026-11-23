import Foundation

/// 预设服务定义。全部字段是配置数据：
/// 接口地址、默认模型、关闭思考参数随预设声明，代码逻辑不按服务名分支。
/// 默认模型名目前是占位值，待用真实服务实测后回填。
struct ServicePreset: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let displayName: String
    /// OpenAI 兼容接口根地址（到版本路径，如 …/v1），请求地址 = baseURL + "chat/completions"。
    /// 自定义预设为空，由用户填写。
    let baseURL: String
    let defaultModel: String
    /// 关闭思考 / 推理的附加请求参数，原样并入请求体；自定义预设默认不附加。
    let disableThinkingParameters: [String: JSONValue]
    /// 该预设的模型是否支持图片输入（不支持时图片翻译提示更换模型）。
    /// 目前占位为 true，待实测后回填。
    let supportsImages: Bool

    var isCustom: Bool { id == Self.customPresetID }
}

extension ServicePreset {
    static let customPresetID = "custom"

    /// 展示顺序即列表顺序；默认选中第一个内置预设（默认预设待实测后定）。
    static let allPresets: [ServicePreset] = [
        ServicePreset(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-6-luna",   // 占位：实测后回填
            disableThinkingParameters: ["reasoning_effort": .string("none")],
            supportsImages: true
        ),
        ServicePreset(
            id: "dashscope",
            displayName: "阿里云百炼",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            defaultModel: "qwen3.8-flash",   // 占位：实测后回填
            disableThinkingParameters: ["enable_thinking": .bool(false)],
            supportsImages: true
        ),
        ServicePreset(
            id: "volcengineArk",
            displayName: "火山方舟",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            defaultModel: "Doubao-Seed-2.0-mini",   // 占位：实测后回填
            disableThinkingParameters: ["thinking": .object(["type": .string("disabled")])],
            supportsImages: true
        ),
        ServicePreset(
            id: customPresetID,
            displayName: "自定义",
            baseURL: "",
            defaultModel: "",
            disableThinkingParameters: [:],
            supportsImages: true   // 自定义服务无法预知，默认支持；不支持时由服务报错兜底
        ),
    ]

    static func preset(id: String) -> ServicePreset? {
        allPresets.first { $0.id == id }
    }
}

/// 自定义服务的「关闭思考」选项：自定义服务无法预知接口写法，由用户按服务选择。
/// 参数与内置预设同源（百炼 / OpenAI / 火山方舟各一种写法），代码不按服务名分支。
struct CustomThinkingOption: Identifiable, Hashable, Sendable {
    static let noneID = "none"

    let id: String
    /// 下拉框里显示的名称
    let displayName: String
    /// 原样并入请求体的参数；「不发送」为空
    let parameters: [String: JSONValue]

    /// 展示顺序即列表顺序；默认「不发送」，保持升级前的请求体不变。
    static let all: [CustomThinkingOption] = [
        CustomThinkingOption(id: noneID, displayName: AppText.settingsCustomThinkingNone, parameters: [:]),
        option(id: "enableThinking", copying: "dashscope", displayName: "enable_thinking: false（通义千问等）"),
        option(id: "reasoningEffort", copying: "openai", displayName: "reasoning_effort: none（OpenAI 等）"),
        option(id: "thinkingType", copying: "volcengineArk", displayName: "thinking.type: disabled（豆包等）"),
    ]

    static func option(id: String) -> CustomThinkingOption? {
        all.first { $0.id == id }
    }

    private static func option(id: String, copying presetID: String, displayName: String) -> CustomThinkingOption {
        CustomThinkingOption(
            id: id,
            displayName: displayName,
            parameters: ServicePreset.preset(id: presetID)?.disableThinkingParameters ?? [:]
        )
    }
}
