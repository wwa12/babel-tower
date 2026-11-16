import XCTest
import AppKit
import SwiftUI
@testable import BabelTower

/// 设置窗口渲染诊断（提示词编辑框不可滚动的回归测试）：
/// 提示词编辑框内容超长时必须可滚动（macOS 的 TextField(axis: .vertical) 内容超高不可滚，
/// 换 TextEditor + 外层 ScrollView 后必须有真实 NSScrollView 存在）；窗口内容不得空白。
@MainActor
final class SettingsRenderDiagnostic: XCTestCase {

    func testSettingsContentScrollableAndNotBlank() throws {
        let appSettings = AppSettings(
            defaults: UserDefaults(suiteName: "test.settingsRender.\(UUID().uuidString)")!)
        let serviceSettings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.settingsRender.svc.\(UUID().uuidString)")!
        )
        // 预填的默认模板三十多行，必然超过编辑框可视高度
        XCTAssertEqual(appSettings.customPrompt, TranslationPrompt.builtinTemplate)

        let hosting = NSHostingView(rootView: AnyView(
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(serviceSettings)
        ))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // 给 SwiftUI 一个布局周期

        // 可滚动性：层级里必须存在真实 NSScrollView（SwiftUI ScrollView/TextEditor 的底层）
        let scrollViews = Self.collectScrollViews(from: hosting)
        XCTAssertFalse(scrollViews.isEmpty,
                       "设置窗内容超高时必须挂在真实滚动视图上（TextField(axis:) 不可滚）")
        // 编辑框本体也要有自己的滚动（TextEditor），而非只有外层窗口滚动
        XCTAssertGreaterThanOrEqual(scrollViews.count, 2,
                       "提示词编辑框与外层内容各自需要滚动视图：\(scrollViews.count)")

        // 渲染到像素：不得空白（沿用浮窗白板判据）
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let analysis = PanelRenderDiagnostic.analyze(cg)
        print("[诊断] 设置窗尺寸px=\(cg.width)x\(cg.height) \(analysis)")
        XCTAssertFalse(analysis.isUniformBlank, "设置窗内容不应是纯色空白：\(analysis)")
    }

    /// 递归收集视图树里的 NSScrollView。
    private static func collectScrollViews(from view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scroll = view as? NSScrollView { result.append(scroll) }
        for sub in view.subviews { result.append(contentsOf: collectScrollViews(from: sub)) }
        return result
    }
}
