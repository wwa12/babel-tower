import SwiftUI
import AppKit
import KeyboardShortcuts

/// 全局快捷键名。默认 ⌥T，将来在设置中可改（F10 任务实现录制控件）。
extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
}

/// 应用根状态：组装浮窗、视图模型、翻译引擎、服务配置与翻译历史。
/// ⌥T 在这里接到浮窗的呼出 / 收起。
@MainActor
final class AppState: ObservableObject {

    let modelServiceSettings = ModelServiceSettings()
    let appSettings = AppSettings()
    let panelController: PanelController
    let translationEngine = TranslationEngine()
    private let menuBarController = MenuBarController()
    private let onboardingController = OnboardingController()
    private(set) var panelViewModel: PanelViewModel?
    /// 翻译历史（测试宿主不创建，避免读写真实历史目录）
    private(set) var historyStore: HistoryStore?

    /// 是否作为单元测试宿主启动。测试宿主是完整 App，但测试只需要其中的类型：
    /// 不注册全局快捷键（不和正在用的那份抢 ⌥T）、不装菜单栏图标、
    /// 不读真实钥匙串（读不同签名创建的条目会弹授权框，测试卡死）。
    static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let controller = PanelController()
        panelController = controller
        guard !Self.isRunningUnitTests else { return }

        // 首次启动写入默认快捷键 ⌥T；已设置过（含用户自定义）则不动
        if KeyboardShortcuts.getShortcut(for: .togglePanel) == nil {
            KeyboardShortcuts.setShortcut(.init(.t, modifiers: [.option]), for: .togglePanel)
        }
        menuBarController.install(panelController: controller)

        // 内容闭包要引用 self，init 期间不能捕获；装配延后到初始化完成后。
        // 内容视图在首次呼出时才构建，此处时序无实际影响。
        let historyStore = HistoryStore()
        self.historyStore = historyStore

        Task { [weak self] in
            guard let self else { return }
            let appSettings = self.appSettings
            let viewModel = PanelViewModel(
                engine: self.translationEngine,
                settings: self.modelServiceSettings,
                collapse: { [weak self] in
                    self?.panelController.hidePanel()
                },
                // 设置里的语言修改从下一轮翻译起生效（调用时求值）
                mainLanguage: { [weak appSettings] in appSettings?.mainLanguage ?? .zhHans },
                foreignLanguage: { [weak appSettings] in appSettings?.foreignLanguage ?? .en },
                // 自定义提示词同样下一轮生效
                customPrompt: { [weak appSettings] in appSettings?.customPrompt ?? "" },
                history: historyStore,
                shouldSaveHistory: { [weak appSettings] in appSettings?.saveHistory ?? true }
            )
            self.panelViewModel = viewModel
            controller.viewModel = viewModel
            controller.configure(
                panelContent: { [weak self] in
                    guard let self, let viewModel = self.panelViewModel else { return NSHostingView(rootView: AnyView(EmptyView())) }
                    return PanelHostingView(rootView: AnyView(
                        PanelContentView(viewModel: viewModel)
                            .environmentObject(self)
                    ))
                },
                settingsContent: { [weak self] in
                    guard let self else { return NSHostingView(rootView: AnyView(EmptyView())) }
                    return NSHostingView(rootView: AnyView(
                        SettingsView(history: self.historyStore)
                            .environmentObject(self.appSettings)
                            .environmentObject(self.modelServiceSettings)
                    ))
                }
            )
        }

        // 按下即触发：松开才触发会白白吃掉"呼出 ≤150ms"的预算。
        // 全局快捷键按住不放不会重复触发，不会出现连续开关
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            self?.hotkeyTapped()
        }

        // 首启引导：未配置 Key 且未完成过才出现
        Task { [weak self] in
            guard let self else { return }
            let hasKey: Bool
            do {
                hasKey = !(try self.modelServiceSettings.apiKey(
                    forPresetID: self.modelServiceSettings.selectedPresetID) ?? "").isEmpty
            } catch {
                hasKey = false
            }
            self.onboardingController.showIfNeeded(
                hasAPIKey: hasKey,
                hasCompletedOnboarding: self.appSettings.hasCompletedOnboarding,
                appStateDependencies: .init(
                    appSettings: self.appSettings,
                    modelServiceSettings: self.modelServiceSettings,
                    completeOnboarding: { [weak self] in
                        self?.appSettings.hasCompletedOnboarding = true
                    }
                )
            )
        }
    }

    func hotkeyTapped() {
        panelController.toggle()
    }
}
