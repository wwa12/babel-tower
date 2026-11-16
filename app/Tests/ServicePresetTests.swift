import XCTest
@testable import BabelTower

/// 预设服务配置完整性测试：
/// 预设差异全部在配置里，代码不按服务名分支。
final class ServicePresetTests: XCTestCase {

    func testAllPresetIDs() {
        XCTAssertEqual(
            ServicePreset.allPresets.map(\.id),
            ["openai", "dashscope", "volcengineArk", "custom"]
        )
    }

    func testPresetLookupByID() {
        XCTAssertNotNil(ServicePreset.preset(id: "openai"))
        XCTAssertNotNil(ServicePreset.preset(id: "custom"))
        XCTAssertNil(ServicePreset.preset(id: "不存在的预设"))
    }

    func testBuiltInPresetsHaveHTTPSBaseURLAndDefaultModel() {
        for preset in ServicePreset.allPresets where !preset.isCustom {
            XCTAssertTrue(preset.baseURL.hasPrefix("https://"), "\(preset.id) 地址应为 https")
            XCTAssertTrue(preset.baseURL.hasSuffix("/v1") || preset.id == "volcengineArk",
                          "\(preset.id) 地址应为 OpenAI 兼容版本路径")
            XCTAssertFalse(preset.defaultModel.isEmpty, "\(preset.id) 应有默认模型")
            XCTAssertFalse(preset.displayName.isEmpty)
        }
    }

    func testCustomPresetIsEmptyForUserInput() {
        let custom = ServicePreset.preset(id: ServicePreset.customPresetID)
        XCTAssertNotNil(custom)
        XCTAssertTrue(custom!.isCustom)
        XCTAssertTrue(custom!.baseURL.isEmpty)
        XCTAssertTrue(custom!.defaultModel.isEmpty)
        XCTAssertTrue(custom!.disableThinkingParameters.isEmpty)
    }

    /// 关闭思考/推理的参数按预设声明，形状各不相同：字符串、布尔、嵌套对象。
    func testDisableThinkingParametersPerPreset() {
        let openai = ServicePreset.preset(id: "openai")!
        XCTAssertEqual(openai.disableThinkingParameters["reasoning_effort"], .string("none"))

        let dashscope = ServicePreset.preset(id: "dashscope")!
        XCTAssertEqual(dashscope.disableThinkingParameters["enable_thinking"], .bool(false))

        let ark = ServicePreset.preset(id: "volcengineArk")!
        XCTAssertEqual(
            ark.disableThinkingParameters["thinking"],
            .object(["type": .string("disabled")])
        )
    }
}
