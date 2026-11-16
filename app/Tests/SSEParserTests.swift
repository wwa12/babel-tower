import XCTest
@testable import BabelTower

/// SSE 增量解析测试：任意字节边界分块（含多字节中文拆开）、CRLF、注释行、
/// role-only 增量、[DONE]、流中 error 事件（自解析 SSE，不引第三方）。
final class SSEParserTests: XCTestCase {

    private func contentLine(_ text: String) -> String {
        let json = #"{"choices":[{"delta":{"content":\#(encodeJSONString(text))}}]}"#
        return "data: \(json)\n\n"
    }

    private var doneBlock: String { "data: [DONE]\n\n" }

    private func encodeJSONString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[]".utf8)
        return String(data: data.dropFirst().dropLast(), encoding: .utf8) ?? "\"\""
    }

    private func parse(_ chunks: [Data]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks {
            events += parser.append(chunk)
        }
        return events
    }

    func testWholeBlockAtOnce() {
        let data = Data((contentLine("你好") + doneBlock).utf8)
        XCTAssertEqual(parse([data]), [.content("你好"), .finished])
    }

    func testMultipleContentEventsInOneChunk() {
        let data = Data((contentLine("你") + contentLine("好") + doneBlock).utf8)
        XCTAssertEqual(parse([data]), [.content("你"), .content("好"), .finished])
    }

    /// 逐字节喂入：多字节 UTF-8 与 JSON 行在任意边界拆开都不丢字不乱码。
    func testByteByByteFeedingWithMultibyteSplit() {
        let text = contentLine("你好，世界") + contentLine("héllo") + doneBlock
        let data = Data(text.utf8)
        let chunks = data.map { Data([$0]) }
        XCTAssertEqual(parse(chunks), [.content("你好，世界"), .content("héllo"), .finished])
    }

    func testCRLFLineEndings() {
        let json = #"{"choices":[{"delta":{"content":"好"}}]}"#
        let text = "data: \(json)\r\n\r\ndata: [DONE]\r\n\r\n"
        XCTAssertEqual(parse([Data(text.utf8)]), [.content("好"), .finished])
    }

    /// 有些服务会发 `: ping` 注释行作心跳，忽略。
    func testCommentLinesIgnored() {
        let text = ": ping\n\n" + contentLine("好") + ": keep-alive\n\n" + doneBlock
        XCTAssertEqual(parse([Data(text.utf8)]), [.content("好"), .finished])
    }

    /// 首个增量常只有 role 没有 content，忽略而不是报错。
    func testRoleOnlyDeltaIgnored() {
        let text = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"# + "\n\n" + doneBlock
        XCTAssertEqual(parse([Data(text.utf8)]), [.finished])
    }

    func testStreamErrorEventMidStream() {
        let text = contentLine("部分译文")
            + #"data: {"error":{"message":"Provider overloaded"}}"# + "\n\n"
        XCTAssertEqual(parse([Data(text.utf8)]), [.content("部分译文"), .streamError("Provider overloaded")])
    }

    /// 没有合法 JSON 的 data 行（协议噪音）：跳过该行，不中断后续解析。
    func testMalformedDataLineSkipped() {
        let text = "data: not-json\n\n" + contentLine("好") + doneBlock
        XCTAssertEqual(parse([Data(text.utf8)]), [.content("好"), .finished])
    }

    /// DONE 之后到达的字节不再产出事件。
    func testEventsAfterDoneIgnored() {
        var parser = SSEParser()
        var events = parser.append(Data((contentLine("好") + doneBlock).utf8))
        events += parser.append(Data(contentLine("迟到的").utf8))
        XCTAssertEqual(events, [.content("好"), .finished])
    }
}
