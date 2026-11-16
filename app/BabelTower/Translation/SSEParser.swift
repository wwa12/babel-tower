import Foundation

/// SSE 流式事件的解析产出。
enum SSEEvent: Equatable, Sendable {
    /// 一个内容增量（choices[].delta.content）
    case content(String)
    /// data: [DONE]，流正常结束
    case finished
    /// 流中 error 事件（部分服务在流里报错），携带服务端 message
    case streamError(String)
    /// 模型拒绝处理内容（finish_reason = content_filter"模型拒绝了这段内容"）
    case refusal
}

/// OpenAI 兼容 SSE 响应的增量解析器（纯值类型，自解析，不引第三方）。
///
/// 按 SSE 行协议处理：`data: <payload>\n` 为事件行，`:` 开头为注释行（心跳），空行为分隔。
/// 字节级缓冲：块边界可以落在 UTF-8 多字节字符或 JSON 行中间，凑齐一行才解码，
/// 因此中文被拆在任何字节边界都不丢字不乱码（UTF-8 续字节 ≥ 0x80，不会与行分隔 0x0A 混淆）。
struct SSEParser: Sendable {
    private var buffer = Data()
    private(set) var isFinished = false

    /// 喂入一段字节，返回其中完整解析出的事件（不完整的行留在缓冲里）。
    mutating func append(_ data: Data) -> [SSEEvent] {
        guard !isFinished, !data.isEmpty else { return [] }
        buffer.append(data)

        var events: [SSEEvent] = []
        // 按 0x0A 切行；最后一行（无换行）留在缓冲
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }   // CRLF
            guard let line = String(data: Data(lineData), encoding: .utf8) else {
                continue   // 非法 UTF-8 行：丢弃，不中断后续
            }
            if let event = Self.parse(line: line) {
                events.append(event)
                if case .finished = event {
                    isFinished = true
                    return events
                }
            }
        }
        return events
    }

    /// 单行解析：注释行与空行忽略；data 载荷为 JSON（取 delta.content）或 [DONE]。
    private static func parse(line: String) -> SSEEvent? {
        if line.isEmpty || line.hasPrefix(":") { return nil }
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst("data:".count)
        if payload.hasPrefix(" ") { payload = payload.dropFirst() }

        if payload == "[DONE]" { return .finished }

        // best-effort：非法 JSON 行（协议噪音）跳过；取不到 content 的行（如 role-only 增量）跳过
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return .streamError(message)
        }
        if let choices = object["choices"] as? [[String: Any]] {
            // 先看拒绝：content_filter 时有些服务同时给空 delta
            if let finishReason = choices.first?["finish_reason"] as? String,
               finishReason == "content_filter" {
                return .refusal
            }
            if let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                return .content(content)
            }
        }
        return nil
    }
}
