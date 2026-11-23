import Foundation
import Combine

/// 服务配置未就绪的原因（测试连接与翻译共用同一套提示）。
enum ServiceConfigError: Error, Equatable {
    case missingAPIKey
    case missingModel
    case missingBaseURL
    case invalidBaseURL
}

/// 一次模型请求所需的全部就绪信息。
struct ResolvedServiceConfig: Equatable, Sendable {
    let presetID: String
    let displayName: String
    let model: String
    /// 完整请求地址（baseURL + /chat/completions）
    let endpoint: URL
    let apiKey: String
    let disableThinkingParameters: [String: JSONValue]
    let supportsImages: Bool
}

/// API Key 自动保存的结果（设置界面在 Key 输入框旁显示）。
enum APIKeySaveStatus: Equatable {
    case none
    case saved(presetID: String)
    case failed(presetID: String)
}

/// 模型服务配置状态（F9 最小可用）：预设选择与模型名进 UserDefaults，
/// API Key 只进钥匙串、每预设独立（切换服务带回各自的 Key）。
@MainActor
final class ModelServiceSettings: ObservableObject {

    @Published var selectedPresetID: String {
        didSet { defaults.set(selectedPresetID, forKey: Keys.presetID) }
    }

    @Published var customBaseURL: String {
        didSet { defaults.set(customBaseURL, forKey: Keys.customBaseURL) }
    }

    /// 自定义服务的关闭思考选项（CustomThinkingOption.id）；内置预设不受影响。
    @Published var customThinkingOptionID: String {
        didSet { defaults.set(customThinkingOptionID, forKey: Keys.customThinkingOption) }
    }

    @Published private(set) var modelOverrides: [String: String] {
        didSet { defaults.set(modelOverrides, forKey: Keys.modelOverrides) }
    }

    /// 最近一次自动保存的结果
    @Published private(set) var apiKeySaveStatus: APIKeySaveStatus = .none

    private let keyStore: APIKeyStore
    private let defaults: UserDefaults
    /// Key 内存缓存：每个预设只读一次钥匙串，之后呼出 / 翻译都走缓存。
    /// 值为 nil 表示"读过，没有 Key"。读取失败（如拒绝授权）不缓存，下次重读。
    /// 写入（setAPIKey）同步更新缓存；Key 只在本进程内存里，不落盘。
    private var keyCache: [String: String?] = [:]
    /// 各预设待写入的 Key（停顿后写入；关窗口 / 切服务时立即写入）
    private var pendingKeySaves: [String: (key: String, task: Task<Void, Never>)] = [:]

    private enum Keys {
        static let presetID = "modelService.presetID"
        static let customBaseURL = "modelService.customBaseURL"
        static let modelOverrides = "modelService.modelOverrides"
        static let customThinkingOption = "modelService.customThinkingOption"
    }

    init(keyStore: APIKeyStore = KeychainStore(), defaults: UserDefaults = .standard) {
        self.keyStore = keyStore
        self.defaults = defaults
        // 存过且合法则恢复；否则回落到第一个内置预设
        let savedPresetID = defaults.string(forKey: Keys.presetID) ?? ""
        selectedPresetID = ServicePreset.preset(id: savedPresetID)?.id ?? ServicePreset.allPresets[0].id
        customBaseURL = defaults.string(forKey: Keys.customBaseURL) ?? ""
        let savedThinkingID = defaults.string(forKey: Keys.customThinkingOption) ?? ""
        customThinkingOptionID = CustomThinkingOption.option(id: savedThinkingID)?.id ?? CustomThinkingOption.noneID
        modelOverrides = defaults.dictionary(forKey: Keys.modelOverrides) as? [String: String] ?? [:]
    }

    var selectedPreset: ServicePreset {
        ServicePreset.preset(id: selectedPresetID) ?? ServicePreset.allPresets[0]
    }

    // MARK: 模型名（预设默认 + 用户覆盖）

    /// 该预设实际使用的模型名：覆盖值优先，空则用预设默认（自定义预设默认为空 → 需用户填写）。
    func modelName(forPresetID presetID: String) -> String {
        if let override = modelOverrides[presetID], !override.isEmpty {
            return override
        }
        return ServicePreset.preset(id: presetID)?.defaultModel ?? ""
    }

    /// 置空或填回默认值时删除覆盖，回落到预设默认。
    func setModelName(_ name: String, forPresetID presetID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var overrides = modelOverrides
        if trimmed.isEmpty || trimmed == ServicePreset.preset(id: presetID)?.defaultModel {
            overrides[presetID] = nil
        } else {
            overrides[presetID] = trimmed
        }
        modelOverrides = overrides
    }

    // MARK: API Key（只进钥匙串）

    static func apiKeyAccount(forPresetID presetID: String) -> String {
        "apiKey." + presetID
    }

    func apiKey(forPresetID presetID: String) throws -> String? {
        if let cached = keyCache[presetID] {
            return cached
        }
        let loaded = try keyStore.loadAPIKey(forAccount: Self.apiKeyAccount(forPresetID: presetID))
        keyCache[presetID] = .some(loaded)
        return loaded
    }

    /// 空串表示清除该预设的 Key。
    func setAPIKey(_ key: String, forPresetID presetID: String) throws {
        let account = Self.apiKeyAccount(forPresetID: presetID)
        if key.isEmpty {
            try keyStore.deleteAPIKey(forAccount: account)
            keyCache[presetID] = .some(nil)
        } else {
            try keyStore.saveAPIKey(key, forAccount: account)
            keyCache[presetID] = .some(key)
        }
    }

    /// 输入中的 Key 停顿 delay 秒后自动写入钥匙串（不点测试连接、不关窗口也能生效）。
    /// 连续输入只写最后一次；内容与已保存的相同不写；预设按调用时捕获。
    func scheduleAPIKeySave(_ key: String, forPresetID presetID: String, delay: TimeInterval = 0.5) {
        pendingKeySaves[presetID]?.task.cancel()
        // 正在输入：之前的"已保存"不再代表当前内容
        if apiKeySaveStatus != .none { apiKeySaveStatus = .none }
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.performAPIKeySave(forPresetID: presetID)
        }
        pendingKeySaves[presetID] = (key, task)
    }

    /// 立即写入还在等待的 Key（关闭设置 / 引导窗口、切换服务、测试连接前调用）。
    /// 设置与引导窗口不再各自用输入框里的值直接写钥匙串，避免一个窗口拿旧值覆盖另一个窗口刚保存的新值。
    func flushPendingAPIKeySaves() {
        for presetID in Array(pendingKeySaves.keys) {
            pendingKeySaves[presetID]?.task.cancel()
            performAPIKeySave(forPresetID: presetID)
        }
    }

    private func performAPIKeySave(forPresetID presetID: String) {
        guard let pending = pendingKeySaves.removeValue(forKey: presetID) else { return }
        let key = pending.key
        guard let cached = keyCache[presetID] else {
            // 这个预设的 Key 从没读成功过（如授权被拒，输入框因此是空的）：
            // 空值不能当成"用户清空了 Key"去删钥匙串里的条目；有内容则照常写入
            guard !key.isEmpty else { return }
            saveKey(key, forPresetID: presetID)
            return
        }
        guard (cached ?? "") != key else { return }   // 没变不写
        saveKey(key, forPresetID: presetID)
    }

    private func saveKey(_ key: String, forPresetID presetID: String) {
        do {
            try setAPIKey(key, forPresetID: presetID)
            apiKeySaveStatus = .saved(presetID: presetID)
        } catch {
            apiKeySaveStatus = .failed(presetID: presetID)
        }
    }

    // MARK: 组装请求配置

    func resolvedConfig() throws -> ResolvedServiceConfig {
        let preset = selectedPreset

        // 校验顺序：地址缺失 → 地址非法 → 模型缺失 → Key 缺失
        let baseString = (preset.isCustom ? customBaseURL : preset.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseString.isEmpty else { throw ServiceConfigError.missingBaseURL }
        // 去掉尾部斜杠再拼路径，避免 //chat/completions
        var normalizedBase = baseString
        while normalizedBase.hasSuffix("/") { normalizedBase.removeLast() }
        // 允许 http：自定义服务常是本机网关（如 http://localhost:11434/v1）
        guard let base = URL(string: normalizedBase),
              let scheme = base.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              base.host != nil else {
            throw ServiceConfigError.invalidBaseURL
        }

        let model = modelName(forPresetID: preset.id)
        guard !model.isEmpty else { throw ServiceConfigError.missingModel }

        guard let key = try apiKey(forPresetID: preset.id), !key.isEmpty else {
            throw ServiceConfigError.missingAPIKey
        }

        return ResolvedServiceConfig(
            presetID: preset.id,
            displayName: preset.displayName,
            model: model,
            endpoint: base.appendingPathComponent("chat/completions"),
            apiKey: key,
            disableThinkingParameters: preset.isCustom
                ? (CustomThinkingOption.option(id: customThinkingOptionID)?.parameters ?? [:])
                : preset.disableThinkingParameters,
            supportsImages: preset.supportsImages
        )
    }
}
