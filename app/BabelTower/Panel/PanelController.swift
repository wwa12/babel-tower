import AppKit
import SwiftUI

/// 浮窗生命周期：
/// - 面板常驻，呼出 / 收起只做显示隐藏与 ≤120ms 淡入淡出；
/// - ⌥T 开关；呼出记录原应用，收起把焦点还回去（不用私有 API）；
/// - 键盘事件经 PanelKeyRouter 分发到视图模型（组字中放行输入法）；
/// - 点击面板外区域收起；拖动后记住位置（显示器拔掉后回落默认定位）。
@MainActor
final class PanelController: NSObject, ObservableObject, NSWindowDelegate {

    @Published private(set) var isPanelVisible = false

    private let panel: FloatingPanel
    private var panelContentProvider: (() -> NSView)?
    private var settingsContentProvider: (() -> NSView)?
    private var settingsWindow: NSWindow?
    /// 呼出时的原应用，收起时归还焦点
    private var applicationBeforeReveal: NSRunningApplication?
    /// 点击面板外的全局监听（只在面板可见期间安装）
    private var outsideClickMonitor: Any?
    /// 记忆的窗口位置（用户拖动后记住）。只用其左上角（x 与顶边），
    /// 高度随内容伸缩，不随记忆恢复。
    private var savedFrame: NSRect?
    /// 当前呼出期间的顶边锚点：内容变高变矮时顶边不动、向下伸缩（不抖动）
    private var anchoredTop: CGFloat?
    /// 位置记忆的存储（测试注入独立域，避免写入真实 App 的偏好设置）
    private let defaults: UserDefaults
    /// 本控制器自己移动窗口期间为 true：这类移动不是用户拖动，不进位置记忆
    private var isMovingProgrammatically = false
    /// 浮窗真实内容是否已装入（contentView 永不为 nil，不能用 nil 判断）
    private var panelContentLoaded = false
    /// 设置窗真实内容是否已装入（同上）
    private var settingsContentLoaded = false

    /// 由 AppState 注入的视图模型（键盘路由用）；面板内容经 provider 注入
    weak var viewModel: PanelViewModel?

    private static let savedFrameKey = "panel.savedFrame"
    /// 呼出/收起淡入淡出时长（≤120ms）
    private static let fadeDuration: TimeInterval = 0.1

    init(panelContent: (() -> NSView)? = nil, settingsContent: (() -> NSView)? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let size = NSSize(width: BehaviorConstants.panelWidth, height: 240)
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panelContentProvider = panelContent
        settingsContentProvider = settingsContent
        super.init()
        panel.delegate = self
        panel.keyEventHandler = { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyEvent(event) ?? false
            }
        }
        if let stored = defaults.string(forKey: Self.savedFrameKey) {
            savedFrame = NSRectFromString(stored)
        }
    }

    /// AppState 组装时注入内容（init 时 AppState 尚未完成初始化，闭包需引用 self）。
    func configure(panelContent: @escaping () -> NSView, settingsContent: @escaping () -> NSView) {
        panelContentProvider = panelContent
        settingsContentProvider = settingsContent
    }

    // MARK: 呼出与收起

    func toggle() {
        isPanelVisible ? hidePanel() : showPanel()
    }

    func showPanel() {
        guard !isPanelVisible else { return }
        // 记录呼出前的应用，收起时归还焦点
        applicationBeforeReveal = NSWorkspace.shared.frontmostApplication
        // 剪贴板带入 / 保留期判定在显示前完成
        viewModel?.panelWillShow()

        let currentSize = panel.frame.size
        if let savedFrame {
            // 记忆的是左上角：按当前高度从记忆的顶边往下放
            let restored = NSRect(x: savedFrame.minX, y: savedFrame.maxY - currentSize.height,
                                  width: currentSize.width, height: currentSize.height)
            if PanelPositionMemory.frameIsValid(restored, screens: PanelGeometry.currentScreens()) {
                setPanelFrameProgrammatically(restored)
            } else {
                setPanelFrameProgrammatically(defaultFrame(size: currentSize))
            }
        } else {
            setPanelFrameProgrammatically(defaultFrame(size: currentSize))
        }
        anchoredTop = panel.frame.maxY
        // 注意不能用 contentView == nil 判断：窗口创建时系统就装了默认内容视图（永不为 nil），
        // 首个版本因此从未装入真实内容、浮窗一直白板。用安装标记判断。
        if !panelContentLoaded, let provider = panelContentProvider {
            let hosting = provider()
            // 高度随内容伸缩（120–640）：内容理想尺寸一变就由本控制器显式改窗口高度。
            // 原实现只开 preferredContentSize，宿主视图不产生尺寸约束，窗口永远停在初始 240pt；
            // 依赖 AppKit 按固有尺寸自动改窗口实测也不生效，所以显式驱动
            if let hostingView = hosting as? PanelHostingView {
                hostingView.sizingOptions = [.intrinsicContentSize]
                hostingView.onIntrinsicSizeChange = { [weak self] size in
                    self?.fitPanelHeight(toContentHeight: size.height)
                }
            }
            panel.contentView = hosting
            panelContentLoaded = true
            hosting.layoutSubtreeIfNeeded()
            fitPanelHeight(toContentHeight: hosting.intrinsicContentSize.height)
        }

        panel.alphaValue = 0
        // nonactivatingPanel 的 makeKey 不激活本 App（不抢焦点），面板获得键盘输入
        panel.makeKeyAndOrderFront(nil)
        // 呼出即可输入（快捷键到可输入 ≤150ms）：面板成 key 后聚焦输入区。
        // 首次呼出时 SwiftUI TextEditor 的宿主 NSTextView 要等首个布局周期才创建，
        // 先强制同步布局再查找，避免第一次 ⌥T 打字无反应。
        if let contentView = panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            if let inputTextView = Self.firstEditableTextView(in: contentView) {
                panel.makeFirstResponder(inputTextView)
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
        isPanelVisible = true
        installOutsideClickMonitor()
    }

    func hidePanel() {
        guard isPanelVisible else { return }
        removeOutsideClickMonitor()
        viewModel?.panelDidCollapse()   // 内容保留锚定（收起不清空）
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // 淡出期间又被呼出（快速连按 ⌥T）：不能把刚呼出的面板藏掉
                guard let self, !self.isPanelVisible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
        isPanelVisible = false
        let previous = applicationBeforeReveal
        applicationBeforeReveal = nil
        // 焦点回原应用：原应用已终止 / 就是本 App / 前台已是它时跳过。
        // 注意：用户中途主动切到别的应用再收起时，焦点仍会拉回呼出前的应用（按设计如此）。
        if let previous, !previous.isTerminated,
           previous.bundleIdentifier != Bundle.main.bundleIdentifier,
           previous != NSWorkspace.shared.frontmostApplication {
            previous.activate()
        }
    }

    // MARK: 键盘路由

    /// ⌘V 读取的粘贴板（系统剪贴板；测试可注入）。
    var pasteboardForKeys: NSPasteboard = .general

    /// 返回 true 表示已消费。组字中的一切按键先放行输入法（路由器保证）。
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let viewModel else { return false }

        let textView = panel.firstResponder as? NSTextView
        // 输入法组字范围：非空表示未确认组字（此时按键交给输入法）
        let markedRange = textView?.markedRange() ?? NSRange(location: NSNotFound, length: 0)
        let hasMarkedText = markedRange.length > 0 && markedRange.location != NSNotFound
        // 输入区 TextEditor 可编辑、结果区只读可选，用 isEditable 区分焦点区域
        let focus: PanelKeyRouter.FocusArea = {
            guard let textView else { return .other }
            return textView.isEditable ? .input : .result
        }()
        let hasSelection = (textView?.selectedRange().length ?? 0) > 0

        let pasteboardForInput = pasteboardForKeys
        let action = PanelKeyRouter.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            hasMarkedText: hasMarkedText,
            focus: focus,
            hasResultSelection: hasSelection && focus == .result,
            hasInputSelection: hasSelection && focus == .input,
            hasInputText: !viewModel.inputText.isEmpty,
            isPinned: viewModel.isPinned,
            isShowingHistory: viewModel.isShowingHistory
        )

        switch action {
        case .translateOrCopyTake:
            viewModel.submit()
            return true
        case .collapse:
            hidePanel()
            return true
        case .copyResultFull:
            viewModel.copyResult(selection: nil, andCollapse: false)
            return true
        case .copySelectedResult:
            viewModel.copyResult(selection: textView.flatMap(Self.selectedText(of:)), andCollapse: false)
            return true
        case .pasteFromClipboard:
            // 粘贴文字：交给输入框自己插入——落在光标处、替换选区、可撤销，不翻译（↩ 才翻译）
            if focus == .input, let textView,
               case .plainText(let text) = ClipboardParser.parse(pasteboardForInput) {
                // insertText 是输入法通道，撤销会和之前的打字合并；先断开，粘贴单独一步撤销
                textView.breakUndoCoalescing()
                textView.insertText(text, replacementRange: textView.selectedRange())
                return true
            }
            // 其余：图片放进输入区（不翻译）；焦点不在输入框时文字追加到末尾；空剪贴板消费但无反应
            viewModel.handlePasteboardContent(pasteboardForInput)
            return true
        case .deleteLastImage:
            viewModel.deleteLastImage()
            return true
        case .retranslate:
            viewModel.retranslate()
            return true
        case .clearRound:
            viewModel.clearRound()
            return true
        case .setTargetMode(let mode):
            viewModel.setTargetMode(mode)
            return true
        case .openSettings:
            showSettingsWindow()
            return true
        case .toggleHistory:
            viewModel.toggleHistory()
            return true
        case .moveHistorySelection(let offset):
            viewModel.moveHistorySelection(by: offset)
            return true
        case .confirmHistorySelection:
            viewModel.confirmHistorySelection()
            return true
        case .passthrough:
            return false
        }
    }

    /// 把键盘焦点放回输入区（历史列表关闭后输入框重新出现时调用）。
    func focusInputArea() {
        guard isPanelVisible, let contentView = panel.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        if let inputTextView = Self.firstEditableTextView(in: contentView) {
            panel.makeFirstResponder(inputTextView)
        }
    }

    /// 深度优先找输入区文本视图（SwiftUI TextEditor 的宿主 NSTextView，可编辑）。
    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable {
            return textView
        }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 结果区选中文本（⌘C 复制选区用）。
    private static func selectedText(of textView: NSTextView) -> String? {
        let range = textView.selectedRange()
        guard range.length > 0, range.location != NSNotFound else { return nil }
        let source = textView.string as NSString
        guard range.location + range.length <= source.length else { return nil }
        return source.substring(with: range)
    }

    // MARK: 点击面板外收起（固定状态不收起）

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleOutsideClick(at: event.locationInWindow)
            }
        }
    }

    /// 点击面板外收起；固定状态放行。坐标为屏幕坐标，与窗口 frame 同系。
    private func handleOutsideClick(at screenPoint: NSPoint) {
        guard isPanelVisible, !panel.frame.contains(screenPoint) else { return }
        guard viewModel?.isPinned != true else { return }
        hidePanel()
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: 位置记忆

    func windowDidMove(_ notification: Notification) {
        // 只记忆浮窗自身的拖动；本控制器也是设置窗的 delegate，设置窗拖动不写入
        guard notification.object as? NSWindow === panel else { return }
        // 只记用户拖动。呼出定位、随内容伸缩时的顶边校正都是程序移动，
        // 记下来会让浮窗从此不再跟随鼠标所在显示器
        guard !isMovingProgrammatically else { return }
        anchoredTop = panel.frame.maxY
        savedFrame = panel.frame
        defaults.set(NSStringFromRect(panel.frame), forKey: Self.savedFrameKey)
    }

    /// 高度随内容变化时保持顶边不动（AppKit 默认保持左下角，窗口会向上长）。
    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, anchoredTop != nil else { return }
        let frame = panel.frame
        let top = displayTop(forHeight: frame.height, fallbackTop: frame.maxY)
        guard abs(frame.maxY - top) > 0.5 else { return }
        setPanelFrameProgrammatically(NSRect(x: frame.minX, y: top - frame.height,
                                             width: frame.width, height: frame.height))
    }

    /// 按内容理想高度设窗口高度（夹在 120–640），顶边不动。
    private func fitPanelHeight(toContentHeight contentHeight: CGFloat) {
        guard contentHeight > 0 else { return }
        var height = min(max(contentHeight, BehaviorConstants.panelMinHeight),
                         BehaviorConstants.panelMaxHeight)
        let frame = panel.frame
        if let visible = panel.screen?.visibleFrame {
            height = min(height, visible.height)
        }
        guard abs(frame.height - height) > 0.5 else { return }
        let top = displayTop(forHeight: height, fallbackTop: frame.maxY)
        setPanelFrameProgrammatically(NSRect(x: frame.minX, y: top - height,
                                             width: frame.width, height: height))
    }

    /// 给定高度时窗口顶边应在的位置：优先锚点；向下长会越过屏幕可见区底边时，
    /// 本次整体上移到刚好露出底边（锚点不变，内容变短后回到锚点）。
    private func displayTop(forHeight height: CGFloat, fallbackTop: CGFloat) -> CGFloat {
        let top = anchoredTop ?? fallbackTop
        guard let visible = panel.screen?.visibleFrame else { return top }
        return min(max(top, visible.minY + height), visible.maxY)
    }

    private func setPanelFrameProgrammatically(_ frame: NSRect) {
        isMovingProgrammatically = true
        defer { isMovingProgrammatically = false }
        panel.setFrame(frame, display: false)
    }

    private func defaultFrame(size: NSSize) -> NSRect {
        PanelGeometry.panelFrame(
            mouseLocation: NSEvent.mouseLocation,
            screens: PanelGeometry.currentScreens(),
            panelSize: size
        )
    }

    // MARK: 设置窗口（LSUIElement 下无应用菜单，从浮窗打开）

    func showSettingsWindow() {
        rebuildSettingsContentIfNeeded()
        guard let settingsWindow else { return }
        // 普通窗口需要 App 激活后才能交互（LSUIElement 不影响手动激活）
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func rebuildSettingsContentIfNeeded() {
        if settingsWindow == nil {
            let contentRect = NSRect(x: 0, y: 0, width: 520, height: 620)
            let window = NSWindow(contentRect: contentRect,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = AppText.settingsWindowTitle
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        // 关闭时内容已释放（省常驻内存），重开时重建（contentView 永不为 nil，用标记判断）
        if !settingsContentLoaded {
            settingsWindow?.contentView = settingsContentProvider?()
            settingsWindow?.center()
            settingsContentLoaded = true
        }
    }

    #if DEBUG
    /// 测试钩子：暴露面板（渲染诊断用例）。
    var panelForTesting: FloatingPanel { panel }

    /// 测试钩子：暴露设置窗口与关闭路径断言（内存治理用例）。
    var settingsWindowForTesting: NSWindow? { settingsWindow }

    func simulateSettingsWindowCloseForTesting() {
        guard let window = settingsWindow else { return }
        windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    /// 测试钩子：模拟点击面板外一点（外部点击收起/固定放行用例；
    /// 真实全局监听不可注入）。
    func simulateOutsideClickForTesting(at screenPoint: NSPoint) {
        handleOutsideClick(at: screenPoint)
    }
    #endif

    /// 浮窗把手栏的关闭按钮 = 收起（与 ⌥T 相同：收起并解除固定、焦点还回原应用）。
    /// 浮窗常驻只做显隐，不允许真正关闭。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === panel else { return true }
        hidePanel()
        return false
    }

    /// 设置窗口关闭：释放 SwiftUI 内容（重开时重建），压常驻内存。
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsWindow?.contentView = nil
        settingsContentLoaded = false
    }
}

/// 浮窗内容宿主：SwiftUI 内容理想尺寸变化时通知控制器调整窗口高度。
final class PanelHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: ((NSSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard onIntrinsicSizeChange != nil else { return }
        // 异步回调：避免在布局过程中同步改窗口尺寸造成布局递归
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onIntrinsicSizeChange?(self.intrinsicContentSize)
        }
    }
}
