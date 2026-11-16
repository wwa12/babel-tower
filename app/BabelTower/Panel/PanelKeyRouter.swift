import AppKit

/// 面板按键动作（PanelKeyRouter.Action 的顶层别名）。
typealias PanelKeyAction = PanelKeyRouter.Action

/// 目标语言选择：自动（主/外语规则）或手动指定。手动只本轮有效。
enum TargetMode: Equatable, Sendable {
    case automatic
    case manual(TranslationLanguage)
}

/// 面板按键路由（纯逻辑）。
/// 输入法组字中一律放行（↩ 和 Esc 交给输入法）。
enum PanelKeyRouter {

    /// 键盘焦点所在区域（决定 ⌘C 分流）。
    enum FocusArea: Equatable, Sendable {
        case input
        case result
        case other
    }

    enum Action: Equatable {
        /// ↩：未发送→翻译；已完成且输入未改→复制并收起
        case translateOrCopyTake
        case collapse
        /// ⌘C 无选区：复制全文，不收起
        case copyResultFull
        /// ⌘C 结果区有选区：复制选区
        case copySelectedResult
        /// ⌘V：把剪贴板文字交给视图模型（空区立即翻译 / 已有追加）
        case pasteFromClipboard
        /// ⌫ 输入框为空：删除最后一张图片
        case deleteLastImage
        case retranslate
        case clearRound
        case setTargetMode(TargetMode)
        /// ⌘,：打开设置
        case openSettings
        /// 交给系统 / 输入法 / 插入文本
        case passthrough
    }

    static func action(keyCode: UInt16,
                       modifiers: NSEvent.ModifierFlags,
                       hasMarkedText: Bool,
                       focus: FocusArea,
                       hasResultSelection: Bool,
                       hasInputSelection: Bool,
                       hasInputText: Bool = true,
                       isPinned: Bool = false) -> Action {
        // 组字未确认：一切按键先给输入法
        if hasMarkedText {
            return .passthrough
        }

        // 按位判定而非严格相等：大写锁等附加标志位不应让快捷键失灵
        let hasCommand = !modifiers.intersection(.command).isEmpty
        let hasOtherModifiers = !modifiers.intersection([.control, .option, .shift]).isEmpty

        if hasCommand && !hasOtherModifiers {
            switch keyCode {
            case 8:   // C（分流）
                if focus == .input, hasInputSelection {
                    return .passthrough   // 系统默认：复制输入文字
                }
                if focus == .result, hasResultSelection {
                    return .copySelectedResult
                }
                return .copyResultFull
            case 9:   // V（空区粘贴立即翻译 / 已有追加）
                return .pasteFromClipboard
            case 15:  // R
                return .retranslate
            case 45:  // N
                return .clearRound
            case 18:  // 1
                return .setTargetMode(.manual(.zhHans))
            case 19:  // 2
                return .setTargetMode(.manual(.zhHant))
            case 20:  // 3
                return .setTargetMode(.manual(.ja))
            case 21:  // 4
                return .setTargetMode(.manual(.en))
            case 29:  // 0
                return .setTargetMode(.automatic)
            case 43:  // ,
                return .openSettings
            default:
                return .passthrough
            }
        }

        if modifiers.intersection([.command, .control, .option]).isEmpty {
            switch keyCode {
            case 36:  // ↩
                if modifiers.contains(.shift) {
                    return .passthrough   // ⇧↩ 换行
                }
                return .translateOrCopyTake
            case 51:  // ⌫：输入框为空时删除最后一张图
                return hasInputText ? .passthrough : .deleteLastImage
            case 53:  // Esc：固定状态放行给系统默认（文本视图无副作用），不收起
                return isPinned ? .passthrough : .collapse
            default:
                return .passthrough
            }
        }

        return .passthrough
    }
}

/// 窗口位置记忆（用户拖动后记住位置）。
/// 记忆的 frame 必须仍落在某块现存屏幕的可见区上（显示器拔掉/布局变化后回落默认定位）。
enum PanelPositionMemory {

    /// frame 与任一屏幕可见区有交集即有效（允许拖到边缘露出主要部分）。
    static func frameIsValid(_ frame: NSRect?, screens: [PanelGeometry.Screen]) -> Bool {
        guard let frame, !screens.isEmpty else { return false }
        return screens.contains { $0.visibleFrame.intersects(frame) }
    }
}
