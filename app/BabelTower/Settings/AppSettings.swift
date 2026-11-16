import Foundation
import Combine
import ServiceManagement

/// 偏好设置：主语言、常用外语、引导完成标记、登录时启动。
/// 界面语言跟随系统（简中/繁中/日/英文案本地化基础设施后续版本接入，此处只展示说明）。
@MainActor
final class AppSettings: ObservableObject {

    @Published var mainLanguage: TranslationLanguage {
        didSet {
            defaults.set(mainLanguage.rawValue, forKey: Keys.mainLanguage)
            // 常用外语不允许与主语言相同（自动模式将无意义）
            if foreignLanguage == mainLanguage {
                foreignLanguage = TranslationLanguage.allCases.first { $0 != mainLanguage } ?? .en
            }
        }
    }

    @Published var foreignLanguage: TranslationLanguage {
        didSet {
            guard foreignLanguage != oldValue else { return }
            if foreignLanguage == mainLanguage {
                // 拒绝写成与主语言相同：回滚
                foreignLanguage = oldValue
                return
            }
            defaults.set(foreignLanguage.rawValue, forKey: Keys.foreignLanguage)
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboardingCompleted) }
    }

    /// 自定义系统提示词：编辑框预填默认模板全文；
    /// 发送时 {目标语言} 占位符替换、纯空白兜底默认由 TranslationPrompt 负责。
    /// 空字符串 = 用户清空留存空（发送时按默认全文兜底）。
    @Published var customPrompt: String {
        didSet {
            guard customPrompt != oldValue else { return }
            // 超上限截断（赋值再触发一次 didSet 落盘截断值）
            if customPrompt.count > BehaviorConstants.maxPromptCharacters {
                customPrompt = String(customPrompt.prefix(BehaviorConstants.maxPromptCharacters))
                return
            }
            defaults.set(customPrompt, forKey: Keys.customPrompt)
        }
    }

    /// 保存翻译历史（默认开；关闭后不再新存，已有记录保留）。
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: Keys.saveHistory) }
    }

    /// 登录时启动开关（与系统登录项双向同步；SMAppService，macOS 13+）。
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // 注册失败（如策略限制）：回读真实状态保持 UI 一致
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
            }
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let mainLanguage = "settings.mainLanguage"
        static let foreignLanguage = "settings.foreignLanguage"
        static let onboardingCompleted = "settings.onboardingCompleted"
        static let customPrompt = "settings.customPrompt"
        static let saveHistory = "settings.saveHistory"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMain = TranslationLanguage(rawValue: defaults.string(forKey: Keys.mainLanguage) ?? "")
            ?? .zhHans
        let storedForeign = TranslationLanguage(rawValue: defaults.string(forKey: Keys.foreignLanguage) ?? "")
            ?? .en
        mainLanguage = storedMain
        foreignLanguage = storedForeign == storedMain ? .en : storedForeign
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingCompleted)
        // 无存量时预填默认模板全文
        customPrompt = defaults.string(forKey: Keys.customPrompt) ?? TranslationPrompt.builtinTemplate
        saveHistory = defaults.object(forKey: Keys.saveHistory) as? Bool ?? true
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

/// 首启引导的显示条件（首次启动分三步；配置过的用户不打扰）。
enum OnboardingState {
    static func shouldShow(hasAPIKey: Bool, hasCompletedOnboarding: Bool) -> Bool {
        !hasAPIKey && !hasCompletedOnboarding
    }
}
