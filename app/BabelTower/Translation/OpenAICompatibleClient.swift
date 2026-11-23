import Foundation

/// 测试连接结果（返回成功或具体的错误原因）。
enum TestConnectionOutcome: Equatable {
    case success
    case failure(String)
}

/// OpenAI 兼容客户端（项目只对接这一种协议）。「测试连接」发一条极短的非流式请求，
/// 验证地址、Key 与模型可用性；流式翻译请求由翻译引擎通过 openStream 发起。
struct OpenAICompatibleClient {

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: 请求构造（纯函数，供单元测试）

    /// 请求体：极短消息 + stream=false，并合并预设的关闭思考参数，
    /// 让测试连接与真实翻译走同一套参数。
    static func testConnectionBody(config: ResolvedServiceConfig) -> [String: JSONValue] {
        [
            "model": .string(config.model),
            "messages": .array([
                .object(["role": .string("user"), "content": .string("hi")])
            ]),
            "stream": .bool(false),
        ].merging(config.disableThinkingParameters) { current, _ in current }
    }

    static func makeTestConnectionRequest(config: ResolvedServiceConfig) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = BehaviorConstants.testConnectionTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(testConnectionBody(config: config))
        return request
    }

    /// 通用聊天请求（翻译引擎用）：请求体由调用方构造（翻译 / 未来的其他用途）。
    static func makeChatRequest(config: ResolvedServiceConfig,
                                body: [String: JSONValue]) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        // 流式请求的超时是相邻数据包间的空闲超时；首字超时由引擎层计时。
        // 空闲超时须长于首字超时，否则没有心跳的服务会先报网络错误而不是首字超时。
        request.timeoutInterval = BehaviorConstants.firstTokenTimeout + 30
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// 打开流式响应：校验 HTTP 状态，非 2xx 时读取错误体并抛出分类后的失败。
    /// 成功返回字节流（SSE），由调用方用 SSEParser 增量解析。
    func openStream(config: ResolvedServiceConfig,
                    body: [String: JSONValue]) async throws -> URLSession.AsyncBytes {
        let request = try Self.makeChatRequest(config: config, body: body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationFailure.networkUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            // best-effort 读取错误体：读不到只影响提示详略，不影响分类
            var errorBody = Data()
            do {
                for try await byte in bytes { errorBody.append(byte) }
            } catch { /* 保留已读部分 */ }
            let detail = Self.serverMessage(in: errorBody)
            throw TranslationFailure.from(statusCode: http.statusCode, detail: detail)
        }
        return bytes
    }

    // MARK: 执行与错误映射

    func testConnection(config: ResolvedServiceConfig) async -> TestConnectionOutcome {
        let request: URLRequest
        do {
            request = try Self.makeTestConnectionRequest(config: config)
        } catch {
            return .failure(AppText.testRequestBuildFailed)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            return .failure(Self.failureMessage(for: error))
        } catch {
            return .failure(AppText.testNetworkErrorPrefix + error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(AppText.testNetworkErrorPrefix + AppText.testNotHTTPResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            // 显示服务返回的原因（Key 无效或额度用完 → 显示服务返回的原因）
            return .failure(Self.failureMessage(
                statusCode: http.statusCode,
                serverMessage: Self.serverMessage(in: data)
            ))
        }
        return .success
    }

    // MARK: 提示文案映射

    /// 尽力提取 OpenAI 兼容错误体里的 message 字段，取不到只影响提示详略，不影响错误本身。
    /// 截断到 200 字符：异常服务端可能返回超长文本，不能原样撑上界面。
    static func serverMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw: String?
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            raw = message
        } else if let message = object["message"] as? String, !message.isEmpty {
            raw = message
        } else {
            raw = nil
        }
        guard let message = raw else { return nil }
        if message.count > 200 {
            return String(message.prefix(200)) + "…"
        }
        return message
    }

    static func failureMessage(statusCode: Int, serverMessage: String?) -> String {
        let detail = serverMessage.map { "：\($0)" } ?? ""
        switch statusCode {
        case 401, 403:
            return AppText.testKeyRejected + detail
        case 402:
            return AppText.testPaymentRequired + detail
        case 404:
            return AppText.testNotFound + detail
        case 429:
            // 被限流提示稍后再试；服务端 message 不再追加，避免噪音
            return AppText.testRateLimited
        case 500...599:
            return AppText.testServerErrorPrefix + "\(statusCode)）。" + detail
        default:
            return AppText.testHTTPErrorPrefix + "\(statusCode)）。" + detail
        }
    }

    static func failureMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return AppText.testTimeout
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return AppText.testNetworkDown
        default:
            return AppText.testNetworkErrorPrefix + error.localizedDescription
        }
    }
}
