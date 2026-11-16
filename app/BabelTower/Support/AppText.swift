/// 面向用户的文案集中存放（不散落字符串字面量）。
/// 本地化（简中 / 繁中 / 日 / 英）基础设施随 F10 设置任务落地。
enum AppText {
    static let placeholderTitle = "巴别塔 · 工程验证占位窗口"
    static let hotkeyCountLabel = "⌥T 触发次数："
    static let placeholderHint = "切到其他应用按 ⌥T，这里计数会 +1"

    // MARK: 模型服务设置（F9 最小可用）

    static let settingsOpenHint = "打开设置 ⌘,"
    static let settingsServicePicker = "服务"
    static let settingsAPIKeyField = "API Key"
    static let settingsModelField = "模型名称"
    static let settingsBaseURLField = "接口地址"
    static let settingsBaseURLPlaceholder = "https://api.example.com/v1"
    static let settingsAPIKeyPlaceholder = "sk-…"
    static let settingsAPIKeySaved = "已保存到钥匙串"
    static let settingsAPIKeyCleared = "已从钥匙串删除"
    static let settingsModelPlaceholder = "例如 gpt-6-luna"
    static let settingsTestButton = "测试连接"
    static let settingsTesting = "测试中…"
    static let settingsKeychainPrivacyNote = "API Key 只保存在本机系统钥匙串，不随设置同步；除你选择的模型服务外，不发送给任何一方。"

    // MARK: 浮窗界面

    static let settingsWindowTitle = "设置"
    static let panelInputPlaceholder = "粘贴文字或图片，或直接输入"
    static let panelLanguageAutomatic = "自动"

    /// 语言栏短标签（简/繁/日/EN）。
    static func panelLanguageShort(_ language: TranslationLanguage) -> String {
        switch language {
        case .zhHans: "简"
        case .zhHant: "繁"
        case .ja: "日"
        case .en: "EN"
        }
    }
    static let panelCopy = "复制"
    static let panelCopyDone = "已复制"
    static let panelRetry = "重试"
    static let panelGoSettings = "去设置"

    // MARK: 图钉固定

    static let panelPinTooltip = "固定浮窗（固定后点击外部与 Esc 不收起，⌥T 仍可收起）"
    static let panelUnpinTooltip = "取消固定"

    static let panelHintEmpty = "⌘V 粘贴 · Esc 收起"
    static let panelHintComposing = "↩ 翻译 · ⇧↩ 换行"
    static let panelHintTranslating = "⌘1–4 切换语言 · Esc 收起"
    static let panelHintFinished = "↩ 复制并收起 · ⌘C 复制 · ⌘R 重译"
    static let panelHintFailed = "⌘R 重试 · Esc 收起"

    /// 固定态提示：标注"固定中"，不出现"收起"字样（固定时 Esc 与 ↩ 都不再收起）。
    static let panelHintPinnedEmpty = "⌘V 粘贴 · 固定中"
    static let panelHintPinnedComposing = "↩ 翻译 · ⇧↩ 换行 · 固定中"
    static let panelHintPinnedTranslating = "⌘1–4 切换语言 · 固定中"
    static let panelHintPinnedFinished = "↩ 复制 · ⌘C 复制 · ⌘R 重译 · 固定中"
    static let panelHintPinnedFailed = "⌘R 重试 · 固定中"

    /// 提示栏文案映射（状态表 + 固定态变体）。
    static func panelHint(for phase: PanelPhase, isPinned: Bool = false) -> String {
        switch phase {
        case .empty: isPinned ? panelHintPinnedEmpty : panelHintEmpty
        case .composing: isPinned ? panelHintPinnedComposing : panelHintComposing
        case .translating: isPinned ? panelHintPinnedTranslating : panelHintTranslating
        case .finished: isPinned ? panelHintPinnedFinished : panelHintFinished
        case .failed: isPinned ? panelHintPinnedFailed : panelHintFailed
        }
    }

    /// 原文已是目标语言的提示（语言名随实际情况）。
    static func panelSameAsSource(_ languageName: String) -> String {
        "原文已是\(languageName)"
    }

    static let panelNoTextInImage = "图片里没有可翻译的文字"

    /// 文字超限提示（显示当前字数，禁止发送）。
    static func panelCharCount(_ count: Int) -> String {
        "已超出上限：当前 \(count) / \(BehaviorConstants.maxTextCharacters) 字符"
    }

    // MARK: 测试连接结果与错误

    static let testSuccess = "连接成功，模型可用。"
    static let testNeedAPIKey = "请先填写 API Key。"
    static let testNeedModel = "请先填写模型名称。"
    static let testNeedBaseURL = "请先填写接口地址。"
    static let testInvalidBaseURL = "接口地址无效，应以 http(s):// 开头，例如 https://api.example.com/v1。"
    static let testKeyRejected = "API Key 无效或无权访问该服务。"
    static let testPaymentRequired = "账户额度不足或需要付费。"
    static let testRateLimited = "请求被限流，请稍后再试。"
    static let testNotFound = "接口地址不存在（404），请检查服务地址。"
    static let testServerErrorPrefix = "服务暂时不可用（HTTP "
    static let testHTTPErrorPrefix = "服务返回了错误（HTTP "
    static let testNetworkDown = "没有网络连接，请检查网络后重试。"
    static let testTimeout = "连接超时，请检查网络或换一个服务地址后重试。"
    static let testNetworkErrorPrefix = "网络错误："
    static let testNotHTTPResponse = "服务未返回有效响应。"
    static let testRequestBuildFailed = "无法构造请求，请检查服务配置。"
    static let testKeychainReadFailed = "读取钥匙串失败，请重试或重新填写 API Key。"
    static let testKeychainWriteFailed = "保存 API Key 到钥匙串失败，请重试。"

    // MARK: 翻译引擎错误

    /// 首字超过 15 秒。数字与 BehaviorConstants.firstTokenTimeout 对应。
    static let translateFirstTokenTimeout = "15 秒内没有收到译文开头，已停止请求。可以重试。"
    static let translateStreamInterrupted = "译文传输中断，已收到的部分标注为未完成。"
    static let translateModelNoImages = "所选模型不支持图片输入，请在设置里更换模型。"
    static let translateModelRefused = "模型拒绝了这段内容。"
    static let panelEmptyResultHint = "没有返回译文，可以 ⌘R 重试。"
    static let panelResultAccessibilityLabel = "译文"

    // MARK: 设置与引导

    static let settingsShortcutSection = "快捷键"
    static let settingsLanguageSection = "翻译语言"
    static let settingsMainLanguage = "主语言"
    static let settingsForeignLanguage = "常用外语"
    static let settingsGeneralSection = "通用"
    static let settingsLaunchAtLogin = "登录时启动"
    static let settingsUILanguageNote = "界面语言跟随系统设置（当前提供简体中文界面）。"
    static let settingsServiceSectionTitle = "模型服务"

    // MARK: 自定义提示词

    static let settingsPromptSection = "提示词"
    static let settingsPromptRestoreDefault = "恢复默认"

    /// 字数显示（与文字输入上限一致的 10,000 字符上限）。
    static func settingsPromptCharCount(_ count: Int) -> String {
        "\(count) / \(BehaviorConstants.maxPromptCharacters) 字符"
    }

    static let settingsPromptNote = "这里就是发给模型的完整系统提示词：{目标语言} 会自动替换为当前语言指令（⌘1–4 与语言设置照常生效）。留空时按默认全文发送。若删除首行语言标记（[[zh-Hans]] 等）的输出格式要求，语言识别与高亮会失效，译文仍会正常显示。"

    // MARK: 菜单栏

    static let menuOpenPanel = "打开翻译窗口"
    static let menuSettings = "设置…"
    static let menuCheckForUpdates = "检查更新"
    static let menuQuit = "退出巴别塔"

    // MARK: 首启引导

    static let onboardingTitle = "欢迎使用巴别塔"
    static let onboardingPrivacyNote = "翻译内容会发送到你在下面选择的模型服务；API Key 只保存在本机钥匙串。"
    static let onboardingStep1Title = "1 · 配置模型服务"
    static let onboardingStep2Title = "2 · 选择语言"
    static let onboardingStep3Title = "3 · 快捷键"
    static let onboardingStep3Hint = "按一次 ⌥T（呼出浮窗）确认快捷键可用，然后开始使用。"
    static let onboardingStartUsing = "开始使用"
    static let onboardingNext = "下一步"

    // MARK: 图片输入

    static let panelTooManyImages = "最多 4 张图片，多出的没有添加。"
    static let panelImageFileTooLarge = "单张图片文件不能超过 20 MB，这张没有添加。"
    static let panelImageUndecodable = "无法读取这张图片。"
    static let panelImageProcessing = "图片处理中"
}
