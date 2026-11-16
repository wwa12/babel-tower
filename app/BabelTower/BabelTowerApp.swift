import SwiftUI

@main
struct BabelTowerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // LSUIElement（无 Dock 图标、无应用菜单，见 pbxproj INFOPLIST_KEY_LSUIElement）：
        // 浮窗由 PanelController 常驻管理，设置窗口从浮窗内容打开。
        // Settings 场景仅为满足 Scene 结构要求，LSUIElement 下不可见、不使用。
        Settings { EmptyView() }
    }
}
