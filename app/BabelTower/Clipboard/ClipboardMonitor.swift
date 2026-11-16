import Foundation
import AppKit

/// 剪贴板变化监测状态机：
/// - 变化检测只读 changeCount（不读内容）：每秒轮询一次，空闲 CPU 接近 0；
/// - 本 App 写入剪贴板（复制译文）不算新内容；
/// - 被 App 带入过的内容不再新鲜（同一份不重复带入）；
/// - 新鲜 = 60 秒内变化 + 非本 App 写入 + 未带入过。
/// 时钟与计数可注入，状态逻辑全部可单测；真实轮询从 AppState 启动。
@MainActor
final class ClipboardMonitor: ObservableObject {

    /// 只读计数的高频轮询间隔（秒）。
    static let pollInterval: TimeInterval = 1.0

    struct Snapshot: Equatable {
        let changeCount: Int
        /// 观察到该变化的时间（变化无法取真实时间戳，以观察到的时间近似——
        /// 轮询间隔 1 秒，误差在新鲜窗口里可忽略）
        let date: Date
        let isOwnWrite: Bool
    }

    private let now: () -> Date
    private var lastObservedChangeCount: Int
    /// 保序队列：裁剪时移除最旧的，避免 Set.removeFirst 随机移除掉"刚写入还没被轮询观察到"的计数
    private var ownWriteChangeCounts: [Int] = []
    private var consumedChangeCounts: [Int] = []
    private(set) var lastSnapshot: Snapshot?
    private var timer: Timer?

    init(initialChangeCount: Int = NSPasteboard.general.changeCount,
         now: @escaping () -> Date = { Date() }) {
        self.lastObservedChangeCount = initialChangeCount
        self.now = now
    }

    // MARK: 变化观察（只读计数，不读内容）

    /// 检查 changeCount：变化则记录快照并返回，未变化返回 nil。
    @discardableResult
    func update(changeCount: Int) -> Snapshot? {
        guard changeCount != lastObservedChangeCount else { return nil }
        lastObservedChangeCount = changeCount
        let snapshot = Snapshot(
            changeCount: changeCount,
            date: now(),
            isOwnWrite: ownWriteChangeCounts.contains(changeCount)
        )
        lastSnapshot = snapshot
        return snapshot
    }

    // MARK: 新鲜判定（定义）

    var hasFreshContent: Bool {
        guard let snapshot = lastSnapshot else { return false }
        return isFreshContent(snapshot)
    }

    func isFreshContent(_ snapshot: Snapshot) -> Bool {
        guard !snapshot.isOwnWrite else { return false }
        guard !consumedChangeCounts.contains(snapshot.changeCount) else { return false }
        return ClipboardFreshness.isFresh(lastChangeDate: snapshot.date, now: now())
    }

    // MARK: 标记

    /// App 即将写入剪贴板（复制译文）后调用：把该计数标记为自身写入（不算新内容）。
    func noteOwnWrite(changeCount: Int) {
        ownWriteChangeCounts.removeAll { $0 == changeCount }
        ownWriteChangeCounts.append(changeCount)
        // 只保留最近几个用于比对新计数
        if ownWriteChangeCounts.count > 8 {
            ownWriteChangeCounts.removeFirst()
        }
    }

    /// 带入过一次后标记：同一份内容不再自动带入。
    func markConsumed(_ snapshot: Snapshot) {
        consumedChangeCounts.removeAll { $0 == snapshot.changeCount }
        consumedChangeCounts.append(snapshot.changeCount)
        if consumedChangeCounts.count > 8 {
            consumedChangeCounts.removeFirst()
        }
    }

    // MARK: 真实轮询

    /// 开始每秒只读 changeCount 的轮询（内容解析按需在呼出时做，不在这里读）。
    /// 挂 common mode：菜单跟踪 / 窗口拖动期间不停摆。
    func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update(changeCount: NSPasteboard.general.changeCount)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
}
