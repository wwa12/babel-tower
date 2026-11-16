import XCTest
import AppKit
import SwiftUI
@testable import BabelTower

/// 白板 BUG 回归测试（2026-11-14 修复）：浮窗内容必须真实渲染。
/// 背景：contentView 永不为 nil（系统默认视图），曾导致真实内容从未装入、浮窗纯白。
/// 直接构建内容视图并做像素分析（非白、颜色多样性）。
@MainActor
final class PanelRenderDiagnostic: XCTestCase {

    func testPanelContentNotBlank() throws {
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let settings = ModelServiceSettings(
            keyStore: InMemoryAPIKeyStore(),
            defaults: UserDefaults(suiteName: "test.render.\(UUID().uuidString)")!
        )
        let viewModel = PanelViewModel(
            engine: TranslationEngine(client: OpenAICompatibleClient(session: URLSession(configuration: config))),
            settings: settings,
            pasteboard: NSPasteboard.withUniqueName(),
            now: { Date() },
            collapse: {}
        )
        viewModel.inputText = "诊断样本文字"

        let hosting = NSHostingView(rootView: AnyView(
            PanelContentView(viewModel: viewModel)
        ))
        hosting.sizingOptions = [.preferredContentSize]

        let panel = FloatingPanel(contentRect: NSRect(x: 100, y: 400, width: 560, height: 240))
        panel.setFrame(NSRect(x: 100, y: 400, width: 560, height: 240), display: true)
        panel.contentView = hosting
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // 给 SwiftUI 一个布局周期

        // 渲染到像素：hosting view 自身位图（不依赖窗口合成）
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let analysis = Self.analyze(cg)
        print("[诊断] hosting尺寸=\(hosting.bounds.size) 尺寸px=\(cg.width)x\(cg.height) \(analysis)")

        // 窗口级合成截图（含 VisualEffect 与面板背景）
        XCTAssertFalse(analysis.isUniformBlank, "面板内容不应是纯色白板：\(analysis)")
        panel.orderOut(nil)
    }

    struct PixelAnalysis {
        let distinctColors: Int
        let nonWhiteRatio: Double
        // 单色即视为空板（默认视图是 windowBackgroundColor 灰色，纯白判据防不住灰板）
        var isUniformBlank: Bool { distinctColors <= 4 }
    }

    /// 降采样统计颜色多样性与非白像素占比。
    static func analyze(_ image: CGImage) -> PixelAnalysis {
        let width = 80, height = 60
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var colors = Set<UInt32>()
        var nonWhite = 0
        let total = width * height
        for offset in stride(from: 0, to: total * 4, by: 4) {
            let r = buffer[offset], g = buffer[offset + 1], b = buffer[offset + 2], a = buffer[offset + 3]
            colors.insert(UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a))
            if r < 245 || g < 245 || b < 245 { nonWhite += 1 }
        }
        return PixelAnalysis(distinctColors: colors.count, nonWhiteRatio: Double(nonWhite) / Double(total))
    }
}
