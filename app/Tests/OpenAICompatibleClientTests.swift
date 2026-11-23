import XCTest
@testable import BabelTower

/// 测试连接的请求构造与错误映射测试（本地 mock 网络层，不连真实服务）。
/// 错误语义对应 Key 无效 / 额度或限流 / 网络问题 / 地址错误。
final class OpenAICompatibleClientTests: XCTestCase {

    private var client: OpenAICompatibleClient!
    private var stub: StubURLProtocol.Type!

    override func setUp() {
        stub = StubURLProtocol.self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [stub]
        client = OpenAICompatibleClient(session: URLSession(configuration: config))
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        client = nil
    }

    private func makeConfig() -> ResolvedServiceConfig {
        ResolvedServiceConfig(
            presetID: "openai",
            displayName: "OpenAI",
            model: "虚构模型-1",
            endpoint: URL(string: "https://api.fictional.example/v1/chat/completions")!,
            apiKey: "虚构测试Key",
            disableThinkingParameters: ["reasoning_effort": .string("none")],
            supportsImages: true
        )
    }

    // MARK: 请求构造

    func testMakeRequestURLMethodHeaders() throws {
        let request = try OpenAICompatibleClient.makeTestConnectionRequest(config: makeConfig())
        XCTAssertEqual(request.url?.absoluteString, "https://api.fictional.example/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer 虚构测试Key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, BehaviorConstants.testConnectionTimeout)
    }

    /// 流式翻译请求的空闲超时长于首字超时：首字超时先触发，不被网络超时抢先。
    func testChatRequestIdleTimeoutExceedsFirstTokenTimeout() throws {
        let request = try OpenAICompatibleClient.makeChatRequest(config: makeConfig(), body: [:])
        XCTAssertGreaterThan(request.timeoutInterval, BehaviorConstants.firstTokenTimeout)
    }

    /// 请求体：极短消息 + stream=false + 预设的关闭思考参数合并。
    func testMakeRequestBodyMergesDisableThinkingParameters() throws {
        let request = try OpenAICompatibleClient.makeTestConnectionRequest(config: makeConfig())
        let data = try XCTUnwrap(StubURLProtocol.requestBodyData(of: request))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "虚构模型-1")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertNotNil(messages[0]["content"])
    }

    // MARK: 结果映射

    /// 异常服务端可能返回超长 message，上屏前截断（防撑坏界面）。
    func testServerMessageTruncatedTo200Characters() {
        let long = String(repeating: "长", count: 500)
        let body = #"{"error":{"message":"\#(long)"}}"#.data(using: .utf8)!
        let message = OpenAICompatibleClient.serverMessage(in: body)
        XCTAssertEqual(message?.count, 201)   // 200 字符 + 省略号
        XCTAssertTrue(message?.hasSuffix("…") == true)
    }

    func testSuccessOn200() async {
        StubURLProtocol.handler = StubURLProtocol.okResponse
        let outcome = await client.testConnection(config: makeConfig())
        XCTAssertEqual(outcome, .success)
    }

    func testInvalidKeyOn401IncludesServerReason() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.errorResponse(status: 401, serverMessage: "Incorrect API key provided")
        }
        let outcome = await client.testConnection(config: makeConfig())
        guard case let .failure(message) = outcome else {
            return XCTFail("401 应判失败")
        }
        XCTAssertTrue(message.contains("API Key"), "应说明 Key 无效：\(message)")
        XCTAssertTrue(message.contains("Incorrect API key provided"), "应带服务端原因：\(message)")
    }

    func testPaymentRequiredOn402() async {
        StubURLProtocol.handler = { _ in StubURLProtocol.errorResponse(status: 402, serverMessage: nil) }
        let outcome = await client.testConnection(config: makeConfig())
        assertFailure(outcome, contains: "额度")
    }

    func testRateLimitedOn429() async {
        StubURLProtocol.handler = { _ in StubURLProtocol.errorResponse(status: 429, serverMessage: nil) }
        let outcome = await client.testConnection(config: makeConfig())
        assertFailure(outcome, contains: "稍后再试")
    }

    func testNotFoundOn404() async {
        StubURLProtocol.handler = { _ in StubURLProtocol.errorResponse(status: 404, serverMessage: nil) }
        let outcome = await client.testConnection(config: makeConfig())
        assertFailure(outcome, contains: "404")
    }

    func testServerErrorOn500() async {
        StubURLProtocol.handler = { _ in StubURLProtocol.errorResponse(status: 503, serverMessage: nil) }
        let outcome = await client.testConnection(config: makeConfig())
        assertFailure(outcome, contains: "503")
    }

    func testNoNetworkMapsToMessage() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let outcome = await client.testConnection(config: makeConfig())
        assertFailure(outcome, contains: "网络")
    }

    func testTimeoutMapsToMessage() async {
        StubURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let outcome = await client.testConnection(config: makeConfig())
        assertFailure(outcome, contains: "超时")
    }

    private func assertFailure(_ outcome: TestConnectionOutcome, contains fragment: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case let .failure(message) = outcome else {
            return XCTFail("应判失败", file: file, line: line)
        }
        XCTAssertTrue(message.contains(fragment), "提示应包含「\(fragment)」：\(message)",
                     file: file, line: line)
    }
}

// MARK: - URLProtocol 替身（仅测试目标使用）

final class StubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// 流式模式：按顺序发送多个数据块（可设块前延迟），用于 SSE 引擎测试。
    struct ScheduledChunk {
        let data: Data
        let delayBefore: TimeInterval

        static func immediate(_ data: Data) -> ScheduledChunk {
            ScheduledChunk(data: data, delayBefore: 0)
        }
    }

    nonisolated(unsafe) static var streamHandler: ((URLRequest) -> [ScheduledChunk])?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var stopLoadingCount = 0

    /// 实例级取消标记：stopLoading 后停止发送余下数据块
    private var cancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        // 流式模式优先：异步分块投递，块间延迟模拟真实流节奏
        // （同步投递会让 URLSession.bytes 等全部数据到齐才返回，测不到流式行为）
        if let streamHandler = Self.streamHandler {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let sequencer = StreamSequencer(
                chunks: streamHandler(request),
                deliver: { [weak self] data in
                    guard let self, !self.cancelled else { return }
                    self.client?.urlProtocol(self, didLoad: data)
                },
                finish: { [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.client?.urlProtocolDidFinishLoading(self)
                })
            sequencer.start()
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        cancelled = true
        Self.stopLoadingCount += 1
    }

    /// 清空流式测试的全局状态（每个用例 setUp 调用）。
    static func resetStreamingState() {
        streamHandler = nil
        capturedRequests = []
        stopLoadingCount = 0
        handler = nil
    }

    /// 按顺序异步投递数据块，块前延迟模拟真实流节奏。
    private final class StreamSequencer: @unchecked Sendable {
        private let chunks: [ScheduledChunk]
        private let deliver: (Data) -> Void
        private let finish: () -> Void
        private var index = 0

        init(chunks: [ScheduledChunk], deliver: @escaping (Data) -> Void, finish: @escaping () -> Void) {
            self.chunks = chunks
            self.deliver = deliver
            self.finish = finish
        }

        func start() {
            DispatchQueue.global().async { self.deliverNext() }
        }

        private func deliverNext() {
            guard index < chunks.count else {
                finish()
                return
            }
            let chunk = chunks[index]
            index += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + chunk.delayBefore) {
                self.deliver(chunk.data)
                self.deliverNext()
            }
        }
    }

    static func okResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        let body = """
        {"id":"t1","choices":[{"message":{"role":"assistant","content":"ok"}}]}
        """.data(using: .utf8)!
        return (response, body)
    }

    static func errorResponse(status: Int, serverMessage: String?) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://api.fictional.example/v1/chat/completions")!
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        let message = serverMessage ?? "server error"
        let body = """
        {"error":{"message":\(JSONEncodedString(message)),"type":"test"}}
        """.data(using: .utf8)!
        return (response, body)
    }

    /// URLProtocol 里 httpBody 为 nil，须读 httpBodyStream。
    static func requestBodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func JSONEncodedString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[]".utf8)
        return String(data: data.dropFirst().dropLast(), encoding: .utf8) ?? "\"\""
    }
}
