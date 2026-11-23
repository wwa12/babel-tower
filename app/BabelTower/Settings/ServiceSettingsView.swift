import SwiftUI

/// 模型服务设置的测试连接状态。
enum ServiceSettingsTestPhase: Equatable {
    case idle
    case running
    case finished(message: String, isSuccess: Bool)
}

/// 模型服务表单（F9）：预设、API Key（只进钥匙串）、模型名、测试连接。
/// 无状态宿主：Key 的读取与落盘由宿主（设置窗口 / 首启引导）经 Binding 与生命周期钩子处理。
struct ServiceSettingsForm: View {
    @EnvironmentObject private var settings: ModelServiceSettings
    @Binding var keyInput: String
    @Binding var testPhase: ServiceSettingsTestPhase

    private let client = OpenAICompatibleClient()

    var body: some View {
        Form {
            Picker(AppText.settingsServicePicker, selection: $settings.selectedPresetID) {
                ForEach(ServicePreset.allPresets) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }

            if settings.selectedPreset.isCustom {
                TextField(AppText.settingsBaseURLField, text: $settings.customBaseURL,
                          prompt: Text(AppText.settingsBaseURLPlaceholder))
            }

            SecureField(AppText.settingsAPIKeyField, text: $keyInput,
                        prompt: Text(AppText.settingsAPIKeyPlaceholder))
                .onChange(of: keyInput) { _, newValue in
                    settings.scheduleAPIKeySave(newValue, forPresetID: settings.selectedPresetID)
                }
            switch settings.apiKeySaveStatus {
            case .saved(let presetID) where presetID == settings.selectedPresetID:
                Text(keyInput.isEmpty ? AppText.settingsAPIKeyCleared : AppText.settingsAPIKeySaved)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let presetID) where presetID == settings.selectedPresetID:
                Text(AppText.testKeychainWriteFailed)
                    .font(.caption)
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }

            TextField(AppText.settingsModelField, text: modelBinding, prompt: Text(modelPlaceholder))

            if settings.selectedPreset.isCustom {
                Picker(AppText.settingsCustomThinkingField, selection: $settings.customThinkingOptionID) {
                    ForEach(CustomThinkingOption.all) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                // 换了写法，上一次的测试结果不再代表当前配置
                .onChange(of: settings.customThinkingOptionID) { _, _ in
                    testPhase = .idle
                }
                Text(AppText.settingsCustomThinkingNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(AppText.settingsTestButton, action: runTestConnection)
                    .disabled(testPhase == .running)
                if testPhase == .running {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppText.settingsTesting).foregroundStyle(.secondary)
                }
            }

            switch testPhase {
            case .finished(let message, let isSuccess):
                Label {
                    Text(message).textSelection(.enabled)
                } icon: {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(isSuccess ? Color.green : Color.orange)
            default:
                EmptyView()
            }

            Text(AppText.settingsKeychainPrivacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelPlaceholder: String {
        let preset = settings.selectedPreset
        return preset.defaultModel.isEmpty ? AppText.settingsModelPlaceholder : preset.defaultModel
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.modelName(forPresetID: settings.selectedPresetID) },
            set: { settings.setModelName($0, forPresetID: settings.selectedPresetID) }
        )
    }

    private func runTestConnection() {
        // 先立即写入还在等待的 Key（自动保存的停顿还没到），再按就绪配置发请求
        settings.flushPendingAPIKeySaves()
        if case .failed(let presetID) = settings.apiKeySaveStatus, presetID == settings.selectedPresetID {
            testPhase = .finished(message: AppText.testKeychainWriteFailed, isSuccess: false)
            return
        }

        let config: ResolvedServiceConfig
        do {
            config = try settings.resolvedConfig()
        } catch let error as ServiceConfigError {
            testPhase = .finished(message: Self.message(for: error), isSuccess: false)
            return
        } catch {
            testPhase = .finished(message: AppText.testKeychainReadFailed, isSuccess: false)
            return
        }

        testPhase = .running
        let thinkingOptionID = settings.customThinkingOptionID
        Task { @MainActor in
            let outcome = await client.testConnection(config: config)
            // 请求期间可能已切换预设或关闭思考写法，旧配置的结果不得上屏
            guard config.presetID == settings.selectedPresetID,
                  thinkingOptionID == settings.customThinkingOptionID else { return }
            switch outcome {
            case .success:
                testPhase = .finished(message: AppText.testSuccess, isSuccess: true)
            case .failure(let message):
                testPhase = .finished(message: message, isSuccess: false)
            }
        }
    }

    static func message(for error: ServiceConfigError) -> String {
        switch error {
        case .missingAPIKey: AppText.testNeedAPIKey
        case .missingModel: AppText.testNeedModel
        case .missingBaseURL: AppText.testNeedBaseURL
        case .invalidBaseURL: AppText.testInvalidBaseURL
        }
    }
}
