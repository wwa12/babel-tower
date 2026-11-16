import SwiftUI
import KeyboardShortcuts

/// 首次启动三步引导：①服务与 Key（含测试连接 + 隐私一句话）
/// ②主语言与常用外语 ③快捷键展示、按 ⌥T 确认。完成或关闭后不再出现。
struct OnboardingView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var modelServiceSettings: ModelServiceSettings

    @State private var step = 0
    /// 服务表单状态（真实 Binding：引导里能输入并保存 Key）
    @State private var keyInput: String = ""
    @State private var testPhase: ServiceSettingsTestPhase = .idle
    let onFinish: () -> Void
    /// 把 persistCurrentKey 注册给宿主（x 关闭前落盘用）
    let registerPersist: (@escaping () -> Void) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(AppText.onboardingTitle)
                .font(.title2.weight(.semibold))
                .padding(.top, 8)

            TabView(selection: $step) {
                serviceStep.tag(0)
                languageStep.tag(1)
                shortcutStep.tag(2)
            }
            .tabViewStyle(.automatic)
            .frame(minHeight: 300)

            HStack {
                Button(AppText.onboardingStartUsing, action: finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step < 2)
                if step < 2 {
                    Button(AppText.onboardingNext) { withAnimation { step += 1 } }
                }
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .frame(width: 520, height: 460)
    }

    // MARK: 第一步：模型服务 + 隐私一句话

    private var serviceStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppText.onboardingStep1Title).font(.headline)
                Text(AppText.onboardingPrivacyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ServiceSettingsForm(keyInput: $keyInput, testPhase: $testPhase)
                    .frame(minHeight: 240)
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            loadKey()
            registerPersist(persistCurrentKey)
        }
        .onChange(of: modelServiceSettings.selectedPresetID) { _, _ in
            modelServiceSettings.flushPendingAPIKeySaves()
            loadKey()
            testPhase = .idle
        }
    }

    private func loadKey() {
        do {
            keyInput = try modelServiceSettings.apiKey(
                forPresetID: modelServiceSettings.selectedPresetID) ?? ""
        } catch {
            keyInput = ""
            testPhase = .finished(message: AppText.testKeychainReadFailed, isSuccess: false)
        }
    }

    /// 引导结束（完成或关闭）前立即写入还在等待的 Key（输入框的值经自动保存写入）。
    private func persistCurrentKey() {
        modelServiceSettings.flushPendingAPIKeySaves()
    }

    // MARK: 第二步：语言

    private var languageStep: some View {
        Form {
            Text(AppText.onboardingStep2Title).font(.headline)
            Picker(AppText.settingsMainLanguage, selection: $appSettings.mainLanguage) {
                ForEach(TranslationLanguage.allCases, id: \.self) { Text($0.promptName).tag($0) }
            }
            Picker(AppText.settingsForeignLanguage, selection: $appSettings.foreignLanguage) {
                ForEach(TranslationLanguage.allCases, id: \.self) { Text($0.promptName).tag($0) }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    // MARK: 第三步：快捷键（按 ⌥T 确认）

    private var shortcutStep: some View {
        VStack(spacing: 16) {
            Text(AppText.onboardingStep3Title).font(.headline)
            KeyboardShortcuts.Recorder(for: .togglePanel)
            Text(AppText.onboardingStep3Hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
    }

    private func finish() {
        persistCurrentKey()
        onFinish()
    }
}

/// 引导窗口控制器：完成或点 x 关闭都记为完成（完成或关闭后不再出现）。
/// 视图 → 控制器的 Key 落盘桥（x 关闭路径用）。
@MainActor
private final class PersistBridge {
    var persist: (() -> Void)?
}

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var dependencies: Dependencies?
    private var persistBridge: PersistBridge?

    func showIfNeeded(hasAPIKey: Bool, hasCompletedOnboarding: Bool,
                      appStateDependencies: Dependencies) {
        guard OnboardingState.shouldShow(hasAPIKey: hasAPIKey,
                                         hasCompletedOnboarding: hasCompletedOnboarding) else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = AppText.onboardingTitle
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        let dependencies = appStateDependencies
        self.dependencies = dependencies
        // x 关闭前的 Key 落盘桥：视图把 persistCurrentKey 注册到这里（视图销毁时自清）
        let persistBridge = PersistBridge()
        self.persistBridge = persistBridge
        window.contentView = NSHostingView(rootView: AnyView(
            OnboardingView(onFinish: { [weak self] in
                self?.complete()
            }, registerPersist: { persist in
                persistBridge.persist = persist
            })
                .environmentObject(dependencies.appSettings)
                .environmentObject(dependencies.modelServiceSettings)
        ))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    private func complete() {
        // 点 x 与"开始使用"同一路径：先落盘当前输入的 Key，再记完成
        persistBridge?.persist?()
        dependencies?.completeOnboarding()
        window?.orderOut(nil)
        // 引导只出现一次：整窗与 SwiftUI 内容一起释放，不占常驻内存（≤100MB）
        window?.contentView = nil
        window = nil
        dependencies = nil
        persistBridge = nil
    }

    /// 点 x 关闭：同样记为完成，避免每次启动重复弹出。
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in
            self.complete()
        }
        return true
    }

    struct Dependencies {
        let appSettings: AppSettings
        let modelServiceSettings: ModelServiceSettings
        let completeOnboarding: () -> Void
    }
}
