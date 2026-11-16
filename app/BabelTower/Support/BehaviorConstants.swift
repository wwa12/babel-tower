import Foundation
import CoreGraphics

/// 对外行为常量集中定义：改动这些值就是改产品行为。
enum BehaviorConstants {
    /// 文字单次上限 10,000 字符。
    static let maxTextCharacters = 10_000

    /// 自定义提示词上限 10,000 字符（与文字输入上限一致）。
    static let maxPromptCharacters = 10_000

    /// 收起后内容保留 10 分钟。
    static let contentRetentionInterval: TimeInterval = 60 * 10

    /// 首字超时 15 秒，超时按异常提示并附重试。
    static let firstTokenTimeout: TimeInterval = 15

    /// 首行标记扫描窗口：前 20 个字符内没有合法标记则整体当译文。
    static let markerScanCharacterLimit = 20

    /// 图片最多 4 张。
    static let maxImageCount = 4

    /// 单张图片文件上限 20 MB。
    static let maxImageFileSize = 20 * 1024 * 1024

    /// 发送前图片长边本地压缩上限 2,000 像素。
    static let imageMaxLongEdge: CGFloat = 2_000

    /// 图片本地预处理预算：单张 ≤100 毫秒。
    static let imagePreprocessBudget: TimeInterval = 0.1

    /// 文字请求最大输出：输入长度 3 倍。
    static let textOutputTokenMultiplier = 3

    /// 文字请求最大输出下限 512 token。
    static let textOutputTokenFloor = 512

    /// 图片请求最大输出 4,096 token。
    static let imageOutputTokenLimit = 4_096

    /// 测试连接请求超时：极短请求，超时给明确提示。
    static let testConnectionTimeout: TimeInterval = 10

    /// 浮窗宽度 560pt。
    static let panelWidth: CGFloat = 560

    /// 浮窗高度下限 120pt。
    static let panelMinHeight: CGFloat = 120

    /// 浮窗高度上限 640pt。
    static let panelMaxHeight: CGFloat = 640
}
