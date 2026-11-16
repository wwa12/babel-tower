import XCTest
import AppKit
import SwiftUI
@testable import BabelTower

/// 白板 BUG 回归测试（2026-11-14 修复）：完整生产路径——PanelController + 延迟 configure
/// + showPanel 全流程（setFrame / 装内容 / 淡入 / 聚焦），断言装入的是真实宿主视图且渲染非白。
/// 钉住根因：contentView 永不为 nil，装内容必须用安装标记而非 nil 判断。
@MainActor
final class PanelShowPathDiagnostic: XCTestCase {

    func testProductionShowPathRenders() async throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.showpath.\(UUID().uuidString)")!
        )

        // 与 AppState 相同的装配方式：controller 先建，Task 里再 configure
        let controller = PanelController()
        let viewModelHolder = Box<PanelViewModel?>(nil)
        let engine = TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config)))
        Task { @MainActor in
            let viewModel = PanelViewModel(
                engine: engine, settings: settings,
                pasteboard: NSPasteboard.withUniqueName(), now: { Date() }, collapse: {}
            )
            viewModelHolder.value = viewModel
            controller.viewModel = viewModel
            controller.configure(
                panelContent: { [weak viewModelHolder] in
                    guard let viewModel = viewModelHolder?.value else {
                        return NSHostingView(rootView: AnyView(EmptyView()))
                    }
                    return NSHostingView(rootView: AnyView(PanelContentView(viewModel: viewModel)))
                },
                settingsContent: { NSHostingView(rootView: AnyView(EmptyView())) }
            )
        }
        // 等 configure Task 落地（生产中这一步在 App 启动后毫秒级完成）
        try await Task.sleep(nanoseconds: 200_000_000)

        controller.showPanel()
        // 等淡入动画（0.1s）+ 布局 + 首帧绘制
        try await Task.sleep(nanoseconds: 700_000_000)

        let panel = controller.panelForTesting
        let contentView = try XCTUnwrap(panel.contentView, "面板应有内容视图")
        let hosting = try XCTUnwrap(contentView as? NSHostingView<AnyView>, "应是 NSHostingView<AnyView>")
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let analysis = PanelRenderDiagnostic.analyze(cg)
        print("[诊断2] 生产路径 hosting尺寸=\(hosting.bounds.size) px=\(cg.width)x\(cg.height) alpha=\(panel.alphaValue) \(analysis)")
        print("[诊断2] 面板可见=\(panel.isVisible) key=\(panel.isKeyWindow)")

        XCTAssertFalse(analysis.isUniformBlank, "生产路径面板不应白板：\(analysis)")
        controller.hidePanel()
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }
}
