import AppKit

/// 浮窗几何（纯函数）：鼠标所在显示器、水平居中、窗口顶部位于可见区上方约四分之一处。
/// 用户拖动后的位置记忆由 PanelController 处理；这里只算默认位置。
enum PanelGeometry {

    /// 屏幕的抽象（frame 全屏坐标 / visibleFrame 去菜单栏与 Dock），便于脱离真实 NSScreen 测试。
    struct Screen: Equatable {
        let frame: NSRect
        let visibleFrame: NSRect
    }

    static func panelFrame(mouseLocation: NSPoint,
                           screens: [Screen],
                           panelSize: NSSize) -> NSRect {
        guard let screen = screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? screens.first else {
            return NSRect(origin: .zero, size: panelSize)
        }
        let visible = screen.visibleFrame
        // 超出可见区尺寸的窗口贴边收缩，不越界
        let width = min(panelSize.width, visible.width)
        let height = min(panelSize.height, visible.height)
        let x = visible.midX - width / 2
        // 上 1/4：窗口顶部从可见区顶部往下四分之一处（"上方约四分之一处"）
        let desiredTop = visible.maxY - visible.height / 4
        let y = max(visible.minY, desiredTop - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// 当前系统屏幕采集。
    static func currentScreens() -> [Screen] {
        NSScreen.screens.map { Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}
