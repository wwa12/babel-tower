import XCTest
@testable import BabelTower

/// 模型请求日志：每次请求（成功 / 超时 / 失败 / 取消）在本机记一行，保留 90 天。
@MainActor
final class RequestLogTests: XCTestCase {

    private var directory: URL!
    private let clock = TestClock()
    private var client: OpenAICompatibleClient!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RequestLogTests-\(UUID().uuidString)", isDirectory: true)
        StubURLProtocol.resetStreamingState()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = OpenAICompatibleClient(session: URLSession(configuration: config))
    }

    override func tearDown() async throws {
        StubURLProtocol.resetStreamingState()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 工具

    private func makeLog() -> RequestLog {
        RequestLog(directory: directory, now: { [clock] in clock.date })
    }

    private func makeEngine(_ log: RequestLog?, timeout: TimeInterval = 2) -> TranslationEngine {
        TranslationEngine(client: client, firstTokenTimeout: timeout, requestLog: log)
    }

    private func makeConfig(endpoint: String = "https://api.fictional.example/v1/chat/completions") -> ResolvedServiceConfig {
        ResolvedServiceConfig(
            presetID: "openai",
            displayName: "OpenAI",
            model: "虚构模型-1",
            endpoint: URL(string: endpoint)!,
            apiKey: "虚构测试Key-不得入日志",
            disableThinkingParameters: [:],
            supportsImages: true
        )
    }

    private static func contentChunk(_ text: String, delayBefore: TimeInterval = 0) -> StubURLProtocol.ScheduledChunk {
        let data = (try? JSONEncoder().encode(["choices": [["delta": ["content": text]]]])) ?? Data()
        return StubURLProtocol.ScheduledChunk(data: Data("data: ".utf8) + data + Data("\n\n".utf8),
                                              delayBefore: delayBefore)
    }

    private static var doneChunk: StubURLProtocol.ScheduledChunk {
        .immediate(Data("data: [DONE]\n\n".utf8))
    }

    private static func rawChunk(_ json: String) -> StubURLProtocol.ScheduledChunk {
        .immediate(Data(("data: " + json + "\n\n").utf8))
    }

    /// 读出全部记录（按开始时间排序）。
    private func readRecords(_ log: RequestLog) throws -> [RequestLogRecord] {
        log.flush()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = RequestLog.makeDecoder()
        return try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .map { try decoder.decode(RequestLogRecord.self, from: Data($0.utf8)) }
        }.sorted { $0.startedAt < $1.startedAt }
    }

    /// 轮询直到记录数达到 count 或超时（日志在引擎任务收尾时异步写入，不靠固定睡眠）。
    private func waitForRecords(_ log: RequestLog, count: Int, timeout: TimeInterval = 3) async throws -> [RequestLogRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        var records = try readRecords(log)
        while records.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            records = try readRecords(log)
        }
        return records
    }

    private func translate(_ engine: TranslationEngine, text: String = "你好",
                           config: ResolvedServiceConfig? = nil) async {
        let terminal = expectation(description: "terminal")
        engine.translate(text: text, target: .manual(.en), config: config ?? makeConfig()) { event in
            switch event {
            case .finished, .failed: terminal.fulfill()
            default: break
            }
        }
        await fulfillment(of: [terminal], timeout: 3)
    }

    private func waitForRequestSent(count: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(3)
        while StubURLProtocol.capturedRequests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: 结果分类

    func testSuccessfulRequestIsLoggedWithTextAndTiming() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [Self.contentChunk("[[en]]\nHello"), Self.doneChunk] }

        await translate(makeEngine(log), text: "你好")

        let records = try await waitForRecords(log, count: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .success)
        XCTAssertEqual(record.sourceText, "你好")
        XCTAssertEqual(record.resultText, "Hello")
        XCTAssertEqual(record.marker, "en")
        XCTAssertEqual(record.model, "虚构模型-1")
        XCTAssertEqual(record.endpoint, "https://api.fictional.example/v1/chat/completions")
        XCTAssertEqual(record.target, "manual:en")
        XCTAssertNotNil(record.firstTokenMs)
        XCTAssertGreaterThanOrEqual(record.totalMs, record.firstTokenMs ?? 0)
        XCTAssertNil(record.failure)
    }

    func testTimeoutIsLogged() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [
            StubURLProtocol.ScheduledChunk(data: Data(), delayBefore: 0.6),
            Self.contentChunk("[[en]]\n迟到"),
            Self.doneChunk,
        ] }
        await translate(makeEngine(log, timeout: 0.15))

        let records = try await waitForRecords(log, count: 1)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .timeout)
        XCTAssertNil(record.firstTokenMs)
        XCTAssertGreaterThanOrEqual(record.totalMs, 150)
        XCTAssertEqual(record.resultText, "")
    }

    func testHTTPFailureIsLoggedWithDetail() async throws {
        let log = makeLog()
        StubURLProtocol.handler = { _ in
            StubURLProtocol.errorResponse(status: 503, serverMessage: "upstream overloaded")
        }
        await translate(makeEngine(log))

        let records = try await waitForRecords(log, count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertTrue(record.failure?.contains("503") ?? false, "\(String(describing: record.failure))")
        XCTAssertTrue(record.failure?.contains("upstream overloaded") ?? false)
        XCTAssertNotNil(record.failureMessage)
    }

    func testNetworkFailureIsLogged() async throws {
        let log = makeLog()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await translate(makeEngine(log))

        let records = try await waitForRecords(log, count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failure, "networkUnavailable")
    }

    func testStreamInterruptedKeepsPartialResult() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [
            Self.contentChunk("[[en]]\nHalf"),
            Self.rawChunk(#"{"error":{"message":"Provider overloaded"}}"#),
        ] }
        await translate(makeEngine(log))

        let records = try await waitForRecords(log, count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertTrue(record.failure?.hasPrefix("streamInterrupted") ?? false)
        XCTAssertEqual(record.resultText, "Half", "失败时记录已收到的部分译文")
    }

    func testRefusalIsLogged() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [
            Self.rawChunk(#"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#),
        ] }
        await translate(makeEngine(log))

        let records = try await waitForRecords(log, count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.failure, "modelRefused")
    }

    // MARK: 取消与取代

    func testCancelledRequestIsLogged() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [Self.contentChunk("[[en]]\n慢", delayBefore: 0.5), Self.doneChunk] }
        let engine = makeEngine(log)
        engine.translate(text: "要取消的", target: .manual(.en), config: makeConfig()) { _ in }
        try await waitForRequestSent()
        engine.cancel()

        let records = try await waitForRecords(log, count: 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .cancelled)
        XCTAssertEqual(records.first?.sourceText, "要取消的")
    }

    func testSupersededRequestLoggedAsCancelledAndNewOneAsSuccess() async throws {
        let log = makeLog()
        // 第一个请求慢（会被取代），第二个立即完成
        let isFirst = FirstCallFlag()
        StubURLProtocol.streamHandler = { _ in
            if isFirst.take() {
                return [Self.contentChunk("[[en]]\nold", delayBefore: 0.5), Self.doneChunk]
            }
            return [Self.contentChunk("[[en]]\nnew"), Self.doneChunk]
        }
        let engine = makeEngine(log)
        engine.translate(text: "旧的", target: .manual(.en), config: makeConfig()) { _ in }
        try await waitForRequestSent()
        await translate(engine, text: "新的")

        let records = try await waitForRecords(log, count: 2)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first { $0.sourceText == "旧的" }?.outcome, .cancelled)
        XCTAssertEqual(records.first { $0.sourceText == "新的" }?.outcome, .success)
    }

    /// 同一回合内就被取代（请求还没发出）的不记日志。
    func testRequestCancelledBeforeSendingIsNotLogged() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [Self.contentChunk("[[en]]\nHi"), Self.doneChunk] }
        let engine = makeEngine(log)
        engine.translate(text: "立刻被取代", target: .manual(.en), config: makeConfig()) { _ in }
        await translate(engine, text: "留下的")

        let records = try await waitForRecords(log, count: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try readRecords(log).map(\.sourceText), ["留下的"], "\(records)")
    }

    // MARK: 隐私

    func testAPIKeyNeverWrittenToLog() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [Self.contentChunk("[[en]]\nHi"), Self.doneChunk] }
        await translate(makeEngine(log))
        _ = try await waitForRecords(log, count: 1)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(all.isEmpty)
        XCTAssertFalse(all.contains("虚构测试Key"), "API Key 不得写入日志")
    }

    func testEndpointCredentialsAndQueryAreRedacted() async throws {
        let log = makeLog()
        StubURLProtocol.streamHandler = { _ in [Self.contentChunk("[[en]]\nHi"), Self.doneChunk] }
        await translate(makeEngine(log),
                        config: makeConfig(endpoint: "https://user:secret@api.fictional.example:8443/v1/chat/completions?key=abc"))

        let records = try await waitForRecords(log, count: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.endpoint, "https://api.fictional.example:8443/v1/chat/completions")
    }

    func testNoLogWhenLoggerAbsent() async throws {
        StubURLProtocol.streamHandler = { _ in [Self.contentChunk("[[en]]\nHi"), Self.doneChunk] }
        await translate(makeEngine(nil))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: 文件与保留期

    func testRecordsGoToOneFilePerDay() throws {
        let log = makeLog()
        log.append(.fixture(startedAt: clock.date))
        log.flush()
        clock.advance(days: 1)
        log.append(.fixture(startedAt: clock.date))
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "jsonl" })
    }

    /// 第 90 天的文件保留，第 91 天的删除。
    func testRetentionBoundaryIs90Days() throws {
        let log = makeLog()
        log.append(.fixture(startedAt: clock.date))        // 第 0 天
        log.flush()
        clock.advance(days: 1)
        log.append(.fixture(startedAt: clock.date))        // 第 1 天
        log.flush()

        clock.advance(days: 90)                             // 现在：第 0 天的文件 91 天，第 1 天的 90 天
        log.pruneExpired()
        log.flush()
        let records = try readRecords(log)
        XCTAssertEqual(records.count, 1, "只删超过 90 天的文件")
        XCTAssertEqual(BehaviorConstants.requestLogRetentionDays, 90)
    }
}

/// 只有第一次 take() 返回 true（流式桩按请求顺序区分）。
private final class FirstCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { taken = true }
        return !taken
    }
}

/// 可在测试中拨动的时钟（日志在后台队列读取时间，读写加锁）。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _date = Date(timeIntervalSince1970: 1_800_000_000)

    var date: Date {
        lock.lock(); defer { lock.unlock() }
        return _date
    }

    func advance(days: Int) {
        lock.lock(); defer { lock.unlock() }
        _date = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: _date) ?? _date
    }
}

private extension RequestLogRecord {
    static func fixture(startedAt: Date) -> RequestLogRecord {
        RequestLogRecord(
            id: UUID(), startedAt: startedAt, presetID: "openai", model: "m",
            endpoint: "https://api.fictional.example/v1/chat/completions", target: "manual:en",
            sourceText: "x", imageCount: 0, imageBytes: 0, outcome: .success,
            failure: nil, failureMessage: nil, marker: "en", resultText: "y",
            firstTokenMs: 10, totalMs: 20)
    }
}
