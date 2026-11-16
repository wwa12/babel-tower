import Foundation

/// 剪贴板新鲜度（纯函数）：
/// 最近一次变化发生在 60 秒内才算新鲜（"60 秒内"含边界）。
/// 是否"本 App 写入 / 已被带入过"由 ClipboardMonitor 状态机判断，这里只管时间窗。
enum ClipboardFreshness {

    static func isFresh(
        lastChangeDate: Date?,
        now: Date = .init(),
        interval: TimeInterval = BehaviorConstants.clipboardFreshnessInterval
    ) -> Bool {
        guard let lastChangeDate else { return false }
        return now.timeIntervalSince(lastChangeDate) <= interval
    }
}
