import AppKit

/// 非激活浮窗面板。
/// 样式不变量（被 FloatingPanelTests 钉住，改动需同步测试）：
/// - nonactivatingPanel：呼出不激活本 App、不抢原应用焦点，但仍可接收键盘输入；
/// - canJoinAllSpaces + fullScreenAuxiliary：多桌面可见、浮于全屏应用之上；
/// - hidesOnDeactivate = false：切换应用不收起，常驻只显隐；
/// - 顶部把手栏只显示系统关闭按钮（点它 = 收起，由 PanelController 拦截，不销毁窗口），黄、绿按钮隐藏。
final class FloatingPanel: NSPanel {

    /// 键盘事件过滤器：返回 true 表示已消费（不进入文本视图 / 系统默认处理）。
    /// 由 PanelController 安装，用于 ↩/Esc/⌘X 等面板快捷键。
    var keyEventHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true   // 把手栏与背景都可拖动
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        for buttonType: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            standardWindowButton(buttonType)?.isHidden = true
        }
    }

    /// 键盘事件先给面板快捷键路由，未消费的再走系统默认（文本输入、输入法）。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyEventHandler, keyEventHandler(event) {
            return
        }
        super.sendEvent(event)
    }

    /// 非激活面板的要点：可以成为 key 窗口接收键盘（但不激活 App）。
    override var canBecomeKey: Bool { true }

    /// 辅助面板不能成为主窗口。
    override var canBecomeMain: Bool { false }
}
