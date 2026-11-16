import XCTest
@testable import BabelTower

/// 模型服务配置存取测试，对应
/// 选择与模型名进 UserDefaults，API Key 只进钥匙串，每预设独立。
@MainActor
final class ModelServiceSettingsTests: XCTestCase {

    private var keyStore: InMemoryAPIKeyStore!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        keyStore = InMemoryAPIKeyStore()
        suiteName = "test.modelServiceSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func makeSettings() -> ModelServiceSettings {
        ModelServiceSettings(keyStore: keyStore, defaults: defaults)
    }

    // MARK: 默认状态

    func testDefaultSelectionIsFirstBuiltInPreset() {
        let settings = makeSettings()
        XCTAssertEqual(settings.selectedPresetID, ServicePreset.allPresets[0].id)
        XCTAssertEqual(settings.modelName(forPresetID: "openai"),
                       ServicePreset.preset(id: "openai")!.defaultModel)
    }

    // MARK: API Key：每预设独立、只进钥匙串

    func testAPIKeyPerPresetIsolation() throws {
        let settings = makeSettings()
        try settings.setAPIKey("虚拟测试Key-openai", forPresetID: "openai")
        try settings.setAPIKey("虚构测试Key-dashscope", forPresetID: "dashscope")

        XCTAssertEqual(try settings.apiKey(forPresetID: "openai"), "虚拟测试Key-openai")
        XCTAssertEqual(try settings.apiKey(forPresetID: "dashscope"), "虚构测试Key-dashscope")
        XCTAssertNil(try settings.apiKey(forPresetID: "volcengineArk"))
    }

    func testSetEmptyAPIKeyDeletesStoredKey() throws {
        let settings = makeSettings()
        try settings.setAPIKey("虚构测试Key-openai", forPresetID: "openai")
        try settings.setAPIKey("", forPresetID: "openai")
        XCTAssertNil(try settings.apiKey(forPresetID: "openai"))
    }

    /// Key 不得进入 UserDefaults（设置项之外的任何落盘位置都不允许）。
    func testAPIKeyNeverWrittenToUserDefaults() throws {
        let settings = makeSettings()
        try settings.setAPIKey("绝不应出现在UserDefaults的虚构Key", forPresetID: "openai")
        settings.selectedPresetID = "dashscope"
        settings.customBaseURL = "https://虚构.example/v1"
        settings.setModelName("虚构模型", forPresetID: "openai")

        for (key, value) in defaults.dictionaryRepresentation() {
            let rendered = "\(value)"
            XCTAssertFalse(rendered.contains("绝不应出现在UserDefaults的虚构Key"),
                           "UserDefaults 键 \(key) 泄漏了 API Key")
        }
    }

    // MARK: 模型名覆盖与持久化

    func testModelNameOverrideAndFallback() {
        let settings = makeSettings()
        settings.setModelName("虚构模型-x", forPresetID: "openai")
        XCTAssertEqual(settings.modelName(forPresetID: "openai"), "虚构模型-x")

        // 置空回到预设默认模型
        settings.setModelName("", forPresetID: "openai")
        XCTAssertEqual(settings.modelName(forPresetID: "openai"),
                       ServicePreset.preset(id: "openai")!.defaultModel)
    }

    func testSelectionAndOverridesPersistAcrossInstances() throws {
        let first = makeSettings()
        first.selectedPresetID = "dashscope"
        first.customBaseURL = "https://虚构.example/v1"
        first.setModelName("虚构模型-y", forPresetID: "dashscope")
        try first.setAPIKey("虚构测试Key-dashscope", forPresetID: "dashscope")

        let second = ModelServiceSettings(keyStore: keyStore, defaults: defaults)
        XCTAssertEqual(second.selectedPresetID, "dashscope")
        XCTAssertEqual(second.customBaseURL, "https://虚构.example/v1")
        XCTAssertEqual(second.modelName(forPresetID: "dashscope"), "虚构模型-y")
        XCTAssertEqual(try second.apiKey(forPresetID: "dashscope"), "虚构测试Key-dashscope")
    }

    /// UserDefaults 里存了类型不符的损坏数据（非字符串/非字典）时，应回落安全默认值，不崩溃。
    func testCorruptedDefaultsFallBackToSafeValues() {
        defaults.set(["不是", "字符串"], forKey: "modelService.presetID")
        defaults.set(["不是", "字典"], forKey: "modelService.modelOverrides")
        defaults.set(["不是", "字符串"], forKey: "modelService.customBaseURL")

        let settings = makeSettings()
        XCTAssertEqual(settings.selectedPresetID, ServicePreset.allPresets[0].id)
        XCTAssertEqual(settings.modelOverrides, [:])
        XCTAssertEqual(settings.customBaseURL, "")
    }

    /// 数字会被 plist 字符串化后残留（如 "7"）：不崩溃，最终走 invalidBaseURL 的安全报错。
    func testNumericDefaultsSurfaceAsInvalidURL() throws {
        let settings = makeSettings()
        settings.selectedPresetID = ServicePreset.customPresetID
        settings.setModelName("虚构模型", forPresetID: ServicePreset.customPresetID)
        try settings.setAPIKey("虚构测试Key-custom", forPresetID: ServicePreset.customPresetID)
        settings.customBaseURL = "7"

        XCTAssertThrowsError(try settings.resolvedConfig()) { error in
            XCTAssertEqual(error as? ServiceConfigError, .invalidBaseURL)
        }
    }

    // MARK: resolvedConfig：请求所需的一切就绪（测试连接与翻译共用）

    func testResolvedConfigForBuiltInPreset() throws {
        let settings = makeSettings()
        try settings.setAPIKey("虚构测试Key-openai", forPresetID: "openai")

        let config = try settings.resolvedConfig()
        XCTAssertEqual(config.presetID, "openai")
        XCTAssertEqual(config.model, ServicePreset.preset(id: "openai")!.defaultModel)
        XCTAssertEqual(config.apiKey, "虚构测试Key-openai")
        XCTAssertEqual(config.endpoint.absoluteString,
                       ServicePreset.preset(id: "openai")!.baseURL + "/chat/completions")
    }

    func testResolvedConfigForCustomPreset() throws {
        let settings = makeSettings()
        settings.selectedPresetID = ServicePreset.customPresetID
        settings.customBaseURL = "  http://localhost:11434/v1  "
        settings.setModelName("虚构本地模型", forPresetID: ServicePreset.customPresetID)
        try settings.setAPIKey("虚构测试Key-custom", forPresetID: ServicePreset.customPresetID)

        let config = try settings.resolvedConfig()
        XCTAssertEqual(config.endpoint.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(config.model, "虚构本地模型")
    }

    func testResolvedConfigValidationErrors() throws {
        // 未填 Key
        let settings = makeSettings()
        XCTAssertThrowsError(try settings.resolvedConfig()) { error in
            XCTAssertEqual(error as? ServiceConfigError, .missingAPIKey)
        }

        // 自定义缺地址
        try settings.setAPIKey("虚构测试Key-custom", forPresetID: ServicePreset.customPresetID)
        settings.selectedPresetID = ServicePreset.customPresetID
        settings.setModelName("虚构模型", forPresetID: ServicePreset.customPresetID)
        XCTAssertThrowsError(try settings.resolvedConfig()) { error in
            XCTAssertEqual(error as? ServiceConfigError, .missingBaseURL)
        }

        // 自定义地址非法
        settings.customBaseURL = "不是一个地址"
        XCTAssertThrowsError(try settings.resolvedConfig()) { error in
            XCTAssertEqual(error as? ServiceConfigError, .invalidBaseURL)
        }

        // 地址合法但缺模型名（自定义预设默认模型为空，先清掉先前的覆盖）
        settings.customBaseURL = "https://虚构.example/v1"
        settings.setModelName("", forPresetID: ServicePreset.customPresetID)
        XCTAssertThrowsError(try settings.resolvedConfig()) { error in
            XCTAssertEqual(error as? ServiceConfigError, .missingModel)
        }
    }
}

/// 内存版 Keychain 替身：让设置层测试不碰真实钥匙串。
final class InMemoryAPIKeyStore: APIKeyStore {
    private var storage: [String: String] = [:]

    func saveAPIKey(_ key: String, forAccount account: String) throws {
        storage[account] = key
    }

    func loadAPIKey(forAccount account: String) throws -> String? {
        storage[account]
    }

    func deleteAPIKey(forAccount account: String) throws {
        storage[account] = nil
    }
}
