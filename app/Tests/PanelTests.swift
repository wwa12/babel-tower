import XCTest
import AppKit
import SwiftUI
@testable import BabelTower

/// 浮窗位置计算测试：鼠标所在显示器、水平居中、屏幕上方约四分之一处。
/// 用纯 rect 计算脱离真实 NSScreen，多屏与回退场景可稳定复现。
final class PanelGeometryTests: XCTestCase {

    /// 1440×900 主屏（左）+ 1920×1080 外接屏（右）。
    /// 可见区与真实系统一致从上下两侧收缩：顶部菜单栏 25、底部 Dock 25（maxY < frame.maxY），
    /// 这样"顶部必须用 visibleFrame 避菜单栏"才能被断言钉住。
    private let mainScreen = PanelGeometry.Screen(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 25, width: 1440, height: 850)
    )
    private let sideScreen = PanelGeometry.Screen(
        frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 1440, y: 25, width: 1920, height: 1030)
    )

    func testSingleScreenCentersHorizontallyAtQuarterHeight() {
        let frame = PanelGeometry.panelFrame(
            mouseLocation: NSPoint(x: 720, y: 450),
            screens: [mainScreen], panelSize: NSSize(width: 560, height: 200)
        )
        // 水平居中：可见区中心 - 宽度一半
        XCTAssertEqual(frame.minX, 1440 / 2 - 560 / 2, accuracy: 0.5)
        // 上方约四分之一处：可见区顶部往下 1/4 是窗口顶部
        let visibleMaxXTop = mainScreen.visibleFrame.maxY
        XCTAssertEqual(frame.maxY, visibleMaxXTop - mainScreen.visibleFrame.height / 4, accuracy: 0.5)
        XCTAssertEqual(frame.width, 560)
        XCTAssertEqual(frame.height, 200)
    }

    func testChoosesScreenContainingMouse() {
        // 鼠标在外接屏（右侧）
        let frame = PanelGeometry.panelFrame(
            mouseLocation: NSPoint(x: 2000, y: 500),
            screens: [mainScreen, sideScreen], panelSize: NSSize(width: 560, height: 200)
        )
        XCTAssertEqual(frame.minX, 1440 + (1920 - 560) / 2, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, sideScreen.visibleFrame.maxY - sideScreen.visibleFrame.height / 4, accuracy: 0.5)

        // 鼠标在主屏（左侧）
        let frameOnMain = PanelGeometry.panelFrame(
            mouseLocation: NSPoint(x: 100, y: 800),
            screens: [mainScreen, sideScreen], panelSize: NSSize(width: 560, height: 200)
        )
        XCTAssertEqual(frameOnMain.minX, (1440 - 560) / 2, accuracy: 0.5)
    }

    /// 鼠标坐标不在任何屏内（极端情况）：回落到第一个屏，不崩溃。
    func testMouseOutsideAllScreensFallsBackToFirst() {
        let frame = PanelGeometry.panelFrame(
            mouseLocation: NSPoint(x: -500, y: -500),
            screens: [mainScreen, sideScreen], panelSize: NSSize(width: 560, height: 200)
        )
        XCTAssertEqual(frame.minX, (1440 - 560) / 2, accuracy: 0.5)
    }

    /// 窗口不超过可见区底部（超高窗口贴底，不越界到 Dock 下方）。
    func testTallPanelClampedToVisibleArea() {
        let frame = PanelGeometry.panelFrame(
            mouseLocation: NSPoint(x: 720, y: 450),
            screens: [mainScreen], panelSize: NSSize(width: 560, height: 5_000)
        )
        XCTAssertGreaterThanOrEqual(frame.minY, mainScreen.visibleFrame.minY)
    }

    func testClampsToVisibleFrameWidth() {
        // 比屏还宽的窗口：贴可见区左缘，不越界
        let frame = PanelGeometry.panelFrame(
            mouseLocation: NSPoint(x: 720, y: 450),
            screens: [mainScreen], panelSize: NSSize(width: 2_000, height: 200)
        )
        XCTAssertEqual(frame.minX, mainScreen.visibleFrame.minX, accuracy: 0.5)
    }
}

/// 面板样式不变量测试：这些属性一旦回退（如丢失 nonactivatingPanel）会直接破坏
/// "不抢焦点 / 浮于全屏 / 切应用不隐藏"的行为，用测试钉住。
final class FloatingPanelTests: XCTestCase {

    @MainActor
    private func makePanel() -> FloatingPanel {
        FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200))
    }

    @MainActor
    func testStyleMaskIsNonactivating() {
        let panel = makePanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "面板必须非激活（不抢焦点）")
    }

    @MainActor
    func testCollectionBehaviorSupportsFullscreenAndAllSpaces() {
        let behavior = makePanel().collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces), "多桌面可见")
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary), "浮于全屏应用")
        XCTAssertTrue(behavior.contains(.ignoresCycle), "不参与 ⌘` 窗口轮转")
    }

    @MainActor
    func testPanelFloatsAboveNormalWindows() {
        XCTAssertGreaterThan(makePanel().level, NSWindow.Level.normal)
    }

    @MainActor
    func testDoesNotHideOnDeactivate() {
        XCTAssertFalse(makePanel().hidesOnDeactivate, "切换应用不收起（常驻只显隐）")
    }

    @MainActor
    func testKeyAndMainSemantics() {
        let panel = makePanel()
        XCTAssertTrue(panel.canBecomeKey, "非激活面板仍需接收键盘输入")
        XCTAssertFalse(panel.canBecomeMain, "不能成为主窗口（辅助面板）")
    }

    @MainActor
    func testOnlyCloseButtonAndTransparentTitlebar() {
        let panel = makePanel()
        for buttonType: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
            let button = panel.standardWindowButton(buttonType)
            XCTAssertTrue(button?.isHidden ?? true, "\(buttonType) 按钮应隐藏")
        }
        let close = panel.standardWindowButton(.closeButton)
        XCTAssertNotNil(close)
        XCTAssertFalse(close?.isHidden ?? true, "把手栏显示系统关闭按钮")
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertTrue(panel.isMovableByWindowBackground, "标题栏隐藏后靠背景拖动")
    }
}

/// ⌥T 接线与呼出 / 收起状态测试。
@MainActor
final class PanelControllerTests: XCTestCase {

    func testToggleFlipsVisibility() {
        let controller = PanelController(
            panelContent: { NSView() },
            settingsContent: { NSView() }
        )
        XCTAssertFalse(controller.isPanelVisible, "启动时不显示")

        controller.toggle()
        XCTAssertTrue(controller.isPanelVisible, "⌥T 呼出")

        controller.toggle()
        XCTAssertFalse(controller.isPanelVisible, "再按 ⌥T 收起（开关语义）")
    }

    /// 设置窗口关闭释放内容、重开重建（常驻内存门禁的窗口内容治理）。
    func testSettingsWindowReleasesAndRebuildsContent() {
        let controller = PanelController(
            panelContent: { NSView() },
            settingsContent: { NSHostingView(rootView: AnyView(EmptyView())) }
        )
        controller.showSettingsWindow()
        let window = controller.settingsWindowForTesting
        XCTAssertNotNil(window)
        // 必须断言类型：contentView 永不为 nil（系统默认视图），nil 检查防不住白板
        XCTAssertTrue(window?.contentView is NSHostingView<AnyView>, "首次打开应装入真实内容")

        // 模拟关闭：内容释放
        controller.simulateSettingsWindowCloseForTesting()
        XCTAssertNil(window?.contentView, "关闭应释放内容")

        // 重开：重建内容
        controller.showSettingsWindow()
        XCTAssertTrue(window?.contentView is NSHostingView<AnyView>, "重开应重建内容")
    }

    func testAppStateHotkeyTapsTogglePanel() {
        let state = AppState()
        state.hotkeyTapped()
        XCTAssertTrue(state.panelController.isPanelVisible)
        state.hotkeyTapped()
        XCTAssertFalse(state.panelController.isPanelVisible)
    }

    // MARK: 固定状态与收起路径

    /// 组装带真实视图模型的控制器（外部点击 / Esc 判定要读 isPinned）。
    /// 必须同时持有返回的 viewModel：控制器对它是弱引用，只留控制器会被释放。
    @MainActor
    private func makeControllerWithViewModel() -> (controller: PanelController, viewModel: PanelViewModel) {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.panelCtrl.\(UUID().uuidString)")!
        )
        try? settings.setAPIKey("虚构测试Key", forPresetID: "openai")
        let viewModel = PanelViewModel(
            engine: engine,
            settings: settings,
            pasteboard: NSPasteboard.withUniqueName(),
            now: { Date() },
            collapse: {}
        )
        let controller = PanelController(panelContent: { NSView() }, settingsContent: { NSView() })
        controller.viewModel = viewModel
        return (controller, viewModel)
    }

    func testOutsideClickCollapsesWhenNotPinned() {
        let pair = makeControllerWithViewModel()
        pair.controller.showPanel()
        pair.controller.simulateOutsideClickForTesting(at: NSPoint(x: -10_000, y: -10_000))
        XCTAssertFalse(pair.controller.isPanelVisible, "非固定：点击外部收起（现状）")
    }

    func testOutsideClickIgnoredWhenPinned() {
        let pair = makeControllerWithViewModel()
        pair.controller.showPanel()
        pair.viewModel.togglePinned()
        pair.controller.simulateOutsideClickForTesting(at: NSPoint(x: -10_000, y: -10_000))
        XCTAssertTrue(pair.controller.isPanelVisible, "固定：点击外部不收起")
        pair.controller.simulateOutsideClickForTesting(at: NSPoint(x: -10_000, y: -10_000))
        XCTAssertTrue(pair.controller.isPanelVisible, "固定期间重复外部点击仍不收起")
        pair.viewModel.togglePinned()
        pair.controller.simulateOutsideClickForTesting(at: NSPoint(x: -10_000, y: -10_000))
        XCTAssertFalse(pair.controller.isPanelVisible, "取消固定后恢复外部点击收起")
    }

    /// ⌥T 是固定中的手动收起入口（收起同时解除固定）。
    func testToggleHotkeyCollapsesEvenWhenPinned() {
        let pair = makeControllerWithViewModel()
        pair.controller.showPanel()
        pair.viewModel.togglePinned()
        pair.controller.toggle()
        XCTAssertFalse(pair.controller.isPanelVisible, "固定不挡 ⌥T 收起")
        XCTAssertFalse(pair.viewModel.isPinned, "收起同时解除固定（不等到下次呼出）")
    }

    /// 固定时 Esc 经键盘路由放行、面板保持可见；取消固定后 Esc 恢复收起。
    func testEscapeKeepsPinnedPanelVisible() {
        let pair = makeControllerWithViewModel()
        pair.controller.showPanel()
        let escapeEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        )!
        pair.viewModel.togglePinned()
        let pinnedConsumed = pair.controller.panelForTesting.keyEventHandler?(escapeEvent) ?? true
        XCTAssertFalse(pinnedConsumed, "固定时 Esc 放行（未消费）")
        XCTAssertTrue(pair.controller.isPanelVisible)

        pair.viewModel.togglePinned()
        let unpinnedConsumed = pair.controller.panelForTesting.keyEventHandler?(escapeEvent) ?? false
        XCTAssertTrue(unpinnedConsumed, "非固定时 Esc 消费并收起")
        XCTAssertFalse(pair.controller.isPanelVisible)
    }
}

/// 提示栏文案映射（含固定态变体）。
final class PanelHintTextTests: XCTestCase {

    func testUnpinnedMatchesStateTable() {
        XCTAssertEqual(AppText.panelHint(for: .empty), "⌘V 粘贴 · ⌘Y 历史 · Esc 收起")
        XCTAssertEqual(AppText.panelHint(for: .composing), "↩ 翻译 · ⇧↩ 换行")
        XCTAssertEqual(AppText.panelHint(for: .translating), "⌘1–4 切换语言 · Esc 收起")
        XCTAssertEqual(AppText.panelHint(for: .finished), "↩ 复制并收起 · ⌘C 复制 · ⌘R 重译")
        XCTAssertEqual(AppText.panelHint(for: .failed(.networkUnavailable)), "⌘R 重试 · Esc 收起")
    }

    /// 固定态：标注"固定中"，不出现"收起"字样（Esc 与 ↩ 都不再收起）。
    func testPinnedVariantsOmitCollapseCues() {
        let phases: [PanelPhase] = [.empty, .composing, .translating, .finished, .failed(.networkUnavailable)]
        for phase in phases {
            let hint = AppText.panelHint(for: phase, isPinned: true)
            XCTAssertTrue(hint.contains("固定中"), "固定态提示应标注固定中：\(hint)")
            XCTAssertFalse(hint.contains("收起"), "固定态不出现收起字样：\(hint)")
        }
    }

    /// 图钉 tooltip：说明固定语义，取消态有明确文案。
    func testPinTooltipsExist() {
        XCTAssertTrue(AppText.panelPinTooltip.contains("固定"), "固定 tooltip 应说明固定语义")
        XCTAssertTrue(AppText.panelUnpinTooltip.contains("取消"), "取消固定 tooltip")
    }
}
