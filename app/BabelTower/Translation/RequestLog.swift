import Foundation

/// 一次模型请求的日志记录（一行 JSON）。
/// 记录原文与译文以便分析超时、失败与翻译质量；API Key 与请求头不记录。
struct RequestLogRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case success
        /// 首字超时
        case timeout
        /// 服务端 / 网络 / 流式中断 / 模型拒绝等失败
        case failed
        /// 被新请求取代或被取消（清空、重新呼出），没有结果
        case cancelled
    }

    let id: UUID
    let startedAt: Date
    let presetID: String
    let model: String
    /// 完整请求地址
    let endpoint: String
    /// "auto:主语言/常用外语" 或 "manual:目标语言"
    let target: String
    let sourceText: String
    let imageCount: Int
    /// 发送的图片（压缩后）总字节数
    let imageBytes: Int
    let outcome: Outcome
    /// 失败分类与服务端原因（如 serviceError(status: 503, detail: "...")）
    let failure: String?
    /// 界面上显示给用户的失败提示
    let failureMessage: String?
    /// 首行标记："en" / "same" / "none" / "passthrough"
    let marker: String?
    /// 收到的译文（失败时为已收到的部分）
    let resultText: String
    /// 从发出请求到收到首个内容的毫秒数；没收到为 nil
    let firstTokenMs: Int?
    /// 从发出请求到结束（完成 / 失败 / 取消）的毫秒数
    let totalMs: Int
}

/// 模型请求日志：本机按天写 JSON Lines 文件，保留 90 天。
/// 写入在后台串行队列执行，不阻塞主线程。
final class RequestLog: @unchecked Sendable {

    let directory: URL
    private let retentionDays: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "BabelTower.RequestLog", qos: .utility)
    private let encoder: JSONEncoder
    /// 最近一次执行过期清理的日期文件名（每天至多清理一次）
    private var lastPrunedDay: String?

    init(directory: URL = RequestLog.defaultDirectory,
         retentionDays: Int = BehaviorConstants.requestLogRetentionDays,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// ~/Library/Application Support/<Bundle ID>/RequestLogs
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BabelTower", isDirectory: true)
            .appendingPathComponent("RequestLogs", isDirectory: true)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 追加一条记录（按请求开始日期分文件）。
    func append(_ record: RequestLogRecord) {
        queue.async { [self] in
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(Self.fileName(for: record.startedAt))
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
            pruneIfNewDay()
        }
    }

    /// 删除超过保留期的日志文件。
    func pruneExpired() {
        queue.async { [self] in prune() }
    }

    /// 等待已排队的写入与清理完成（测试用）。
    func flush() {
        queue.sync {}
    }

    // MARK: 内部（均在 queue 上执行）

    private func pruneIfNewDay() {
        let today = Self.fileName(for: now())
        guard lastPrunedDay != today else { return }
        prune()
    }

    private func prune() {
        let current = now()
        lastPrunedDay = Self.fileName(for: current)
        let calendar = Calendar(identifier: .gregorian)
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays,
                                         to: calendar.startOfDay(for: current)) else { return }
        let cutoffName = Self.fileName(for: cutoff)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            // 文件名按日期排序：早于截止日的整个文件删除
            if file.lastPathComponent < cutoffName {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// requests-2026-11-20.jsonl（本地日期）
    private static func fileName(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "requests-%04d-%02d-%02d.jsonl",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// 引擎内一次请求的日志草稿：随事件累积，请求结束时生成记录。
@MainActor
final class RequestLogDraft {
    private let id = UUID()
    private let startedAt: Date
    private let config: ResolvedServiceConfig
    private let target: TranslationTarget
    private let sourceText: String
    private let imageCount: Int
    private let imageBytes: Int
    private var firstContentAt: Date?
    private var resultText = ""
    private var marker: MarkerParser.Marker?
    private var terminal: TranslationEvent?
    /// 请求是否真正发出（发出前就被取消的不记日志）
    private(set) var wasSent = false

    init(startedAt: Date, config: ResolvedServiceConfig, target: TranslationTarget,
         text: String, images: [ProcessedImage]) {
        self.startedAt = startedAt
        self.config = config
        self.target = target
        self.sourceText = text
        self.imageCount = images.count
        self.imageBytes = images.reduce(0) { $0 + $1.data.count }
    }

    func markSent() {
        wasSent = true
    }

    func markFirstContent(at date: Date) {
        if firstContentAt == nil { firstContentAt = date }
    }

    func observe(_ event: TranslationEvent) {
        switch event {
        case .markerResolved(let resolved):
            marker = resolved
        case .delta(let text):
            resultText += text
        case .finished(let finishedMarker, let body):
            marker = finishedMarker
            resultText = body
            terminal = event
        case .failed:
            terminal = event
        }
    }

    func record(endedAt: Date) -> RequestLogRecord {
        let outcome: RequestLogRecord.Outcome
        var failure: TranslationFailure?
        switch terminal {
        case .finished: outcome = .success
        case .failed(.firstTokenTimeout): outcome = .timeout; failure = .firstTokenTimeout
        case .failed(let reason): outcome = .failed; failure = reason
        default: outcome = .cancelled
        }
        return RequestLogRecord(
            id: id,
            startedAt: startedAt,
            presetID: config.presetID,
            model: config.model,
            endpoint: Self.redacted(config.endpoint),
            target: Self.describe(target),
            sourceText: sourceText,
            imageCount: imageCount,
            imageBytes: imageBytes,
            outcome: outcome,
            failure: failure.map { String(describing: $0) },
            failureMessage: failure?.userMessage,
            marker: marker.map(Self.describe),
            resultText: resultText,
            firstTokenMs: firstContentAt.map { Self.milliseconds(from: startedAt, to: $0) },
            totalMs: Self.milliseconds(from: startedAt, to: endedAt)
        )
    }

    /// 请求地址去掉账号密码与查询参数（自定义地址里可能带凭据），只留 scheme、host、port、path。
    static func redacted(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) * 1_000).rounded())
    }

    private static func describe(_ target: TranslationTarget) -> String {
        switch target {
        case .automatic(let main, let foreign): "auto:\(main.rawValue)/\(foreign.rawValue)"
        case .manual(let language): "manual:\(language.rawValue)"
        }
    }

    private static func describe(_ marker: MarkerParser.Marker) -> String {
        switch marker {
        case .language(let language): language.rawValue
        case .same: "same"
        case .none: "none"
        case .passthrough: "passthrough"
        case .pending: "pending"
        }
    }
}
