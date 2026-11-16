import AppKit

/// 菜单栏常驻图标与菜单：打开翻译窗口、设置、检查更新、退出。
/// 「检查更新」：V1.0 自用无更新机制（Sparkle 随对外分发引入），显示当前版本与说明，不假报"已是最新"。
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private weak var panelController: PanelController?

    func install(panelController: PanelController) {
        self.panelController = panelController
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: AppText.settingsWindowTitle)
        let menu = NSMenu()

        let openItem = NSMenuItem(title: AppText.menuOpenPanel, action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: AppText.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: AppText.menuCheckForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: AppText.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    // MARK: 动作（菜单 target-action 在主线程）

    @objc private func openPanel() {
        panelController?.showPanel()
    }

    @objc private func openSettings() {
        panelController?.showSettingsWindow()
    }

    @objc private func checkForUpdates() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "\(AppText.menuCheckForUpdates)"
        alert.informativeText = "当前版本 \(version)（自用构建）。自动更新机制随对外分发版本引入。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
