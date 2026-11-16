import Foundation

/// 呼出时对所选服务预热连接（URLSession 复用连接，压首字延迟）。
/// 只发一个到服务地址的轻量 GET 建立 DNS + TCP + TLS 并入连接池，不产生 token 消耗、
/// 不解析结果——目的仅是让随后的翻译请求省去建连时间。
enum ConnectionWarmer {

    /// 预热节流：同一服务地址 60 秒内只预热一次。频繁开关浮窗时
    /// 连接本来就还在连接池里，重复预热只会在服务端留下无效请求。
    struct Throttle {
        static let interval: TimeInterval = 60
        private var lastWarmed: [URL: Date] = [:]

        mutating func shouldWarm(_ endpoint: URL, now: Date) -> Bool {
            if let last = lastWarmed[endpoint], now.timeIntervalSince(last) < Self.interval {
                return false
            }
            lastWarmed[endpoint] = now
            return true
        }
    }

    @MainActor private static var throttle = Throttle()

    @MainActor
    static func warm(config: ResolvedServiceConfig, now: Date = Date()) {
        // 单元测试不发真实网络请求
        guard !AppState.isRunningUnitTests,
              throttle.shouldWarm(config.endpoint, now: now) else { return }
        var request = URLRequest(
            url: config.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        // fire-and-get 预热：结果（多半是 404/405）与错误都不关心，连接已建立即达目的
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
