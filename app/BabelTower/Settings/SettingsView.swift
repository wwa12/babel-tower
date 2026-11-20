import SwiftUI
import AppKit
import KeyboardShortcuts

/// 完整设置窗口：模型服务、快捷键、翻译语言、登录时启动、界面语言说明。
/// 服务区复用 ServiceSettingsForm；快捷键用 KeyboardShortcuts.Recorder（自带冲突检测）。
struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    /// 翻译历史（清空用）；nil 时不显示清空按钮
    var history: HistoryStore?
    var requestLog: RequestLog?
    @State private var confirmingClearHistory = false

    var body: some View {
        Form {
            Section(AppText.settingsServiceSectionTitle) {
                ServiceSettingsSection()
            }

            Section(AppText.settingsShortcutSection) {
                KeyboardShortcuts.Recorder(for: .togglePanel)
            }

            Section(AppText.settingsLanguageSection) {
                Picker(AppText.settingsMainLanguage, selection: $appSettings.mainLanguage) {
                    ForEach(TranslationLanguage.allCases, id: \.self) { language in
                        Text(language.promptName).tag(language)
                    }
                }
                Picker(AppText.settingsForeignLanguage, selection: $appSettings.foreignLanguage) {
                    ForEach(TranslationLanguage.allCases, id: \.self) { language in
                        Text(language.promptName).tag(language)
                    }
                }
            }

            // 自定义提示词：预填默认全文，所见即所发。
            // TextEditor 自带滚动视图：macOS 的 TextField(axis:) 内容超出可视高度时无法滚动
            Section(AppText.settingsPromptSection) {
                TextEditor(text: $appSettings.customPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 200, maxHeight: 280)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(0.15))
                    )
                HStack {
                    Text(AppText.settingsPromptCharCount(appSettings.customPrompt.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppText.settingsPromptRestoreDefault) {
                        appSettings.customPrompt = TranslationPrompt.builtinTemplate
                    }
                }
                Text(AppText.settingsPromptNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(AppText.settingsGeneralSection) {
                Toggle(AppText.settingsLaunchAtLogin, isOn: $appSettings.launchAtLogin)
                Toggle(AppText.settingsSaveHistory, isOn: $appSettings.saveHistory)
                HStack {
                    Text(AppText.settingsSaveHistoryNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if history != nil {
                        Button(AppText.settingsClearHistory) {
                            confirmingClearHistory = true
                        }
                    }
                }
                if let requestLog {
                    HStack {
                        Text(AppText.settingsRequestLogNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(AppText.settingsOpenRequestLog) {
                            try? FileManager.default.createDirectory(
                                at: requestLog.directory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(requestLog.directory)
                        }
                    }
                }
                Text(AppText.settingsUILanguageNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .alert(AppText.settingsClearHistoryConfirmTitle, isPresented: $confirmingClearHistory) {
            Button(AppText.settingsClearHistoryConfirmButton, role: .destructive) {
                history?.clearAll()
            }
            Button(AppText.settingsCancel, role: .cancel) {}
        } message: {
            Text(AppText.settingsClearHistoryConfirmMessage)
        }
    }
}

/// 服务设置区（嵌入完整设置窗口；Key 生命周期在这里处理）。
struct ServiceSettingsSection: View {
    @EnvironmentObject private var settings: ModelServiceSettings

    @State private var keyInput: String = ""
    @State private var testPhase: ServiceSettingsTestPhase = .idle

    var body: some View {
        ServiceSettingsForm(keyInput: $keyInput, testPhase: $testPhase)
            .onAppear { loadKey() }
            // 切服务 / 关窗口时立即写入还在等待的 Key（输入框的值经自动保存写入，
            // 这里不再直接用输入框的值写钥匙串）
            .onChange(of: settings.selectedPresetID) { _, _ in
                settings.flushPendingAPIKeySaves()
                loadKey()
                testPhase = .idle
            }
            .onDisappear { settings.flushPendingAPIKeySaves() }
    }

    private func loadKey() {
        do {
            keyInput = try settings.apiKey(forPresetID: settings.selectedPresetID) ?? ""
        } catch {
            keyInput = ""
            testPhase = .finished(message: AppText.testKeychainReadFailed, isSuccess: false)
        }
    }

}
