import XCTest
@testable import BabelTower

/// 首行协议解析契约测试：
/// 标记解析、same / none、前 20 字符容错、空行与截断。
final class MarkerParserTests: XCTestCase {

    // MARK: 四种语言标记

    func testLanguageMarkers() {
        expect("[[zh-Hans]]\n你好", marker: .language(.zhHans), body: "你好")
        expect("[[zh-Hant]]\n你好", marker: .language(.zhHant), body: "你好")
        expect("[[ja]]\nこんにちは", marker: .language(.ja), body: "こんにちは")
        expect("[[en]]\nHello", marker: .language(.en), body: "Hello")
    }

    func testSameMarker() {
        expect("[[same]]\nHello", marker: .same, body: "Hello")
    }

    func testNoneMarkerIgnoresFollowingText() {
        expect("[[none]]", marker: .none, body: "")
        expect("[[none]]\n多余内容", marker: .none, body: "")
        expect("[[none]]多余内容", marker: .none, body: "")
    }

    // MARK: 前 20 字符无合法标记 → 整体当译文，不报错

    func testNoMarkerPastScanWindowTreatedAsTranslation() {
        let text = String(repeating: "译", count: 21)
        expect(text, marker: .passthrough, body: text)
    }

    func testFirstLineCompleteWithoutMarkerTreatedAsTranslation() {
        let text = "译文第一行\n第二行"
        expect(text, marker: .passthrough, body: text)
    }

    func testMarkerStartingAtTwentiethCharIgnored() {
        // 标记起始位置在第 20 个字符（0 起算为 20）即超出扫描窗口
        let text = String(repeating: "前", count: 20) + "[[ja]]\n译文"
        expect(text, marker: .passthrough, body: text)
    }

    func testEmptyFirstLineTreatedAsTranslation() {
        expect("\n", marker: .passthrough, body: "\n")
    }

    // MARK: 缓冲与截断

    func testIncompleteBufferKeepsPending() {
        expect("", marker: .pending, body: "")
        expect("[[zh-Ha", marker: .pending, body: "")
        expect("还在缓冲，未到20字符也没有换行", marker: .pending, body: "")
    }

    func testMarkerWithoutTrailingNewlineYieldsBodyAfterMarker() {
        expect("[[ja]]", marker: .language(.ja), body: "")
        expect("[[ja]]こんにちは", marker: .language(.ja), body: "こんにちは")
    }

    // MARK: 宽容解析

    func testMarkerStartingInsideScanWindowValid() {
        // 标记起始位置 18 < 20，虽跨过窗口边界仍然有效
        let text = String(repeating: "·", count: 18) + "[[ja]]\n译文"
        expect(text, marker: .language(.ja), body: "译文")
        // 起始位置 19 是窗口内最后一个有效位
        let lastValid = String(repeating: "·", count: 19) + "[[ja]]\n译文"
        expect(lastValid, marker: .language(.ja), body: "译文")
    }

    func testJunkOnMarkerLineDropped() {
        expect("[[ja]] 前置杂物\n译文", marker: .language(.ja), body: "译文")
    }

    func testMultilineBodyPreserved() {
        expect("[[en]]\nline1\n\nline3", marker: .language(.en), body: "line1\n\nline3")
    }

    private func expect(_ text: String, marker: MarkerParser.Marker, body: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let result = MarkerParser.parse(text)
        XCTAssertEqual(result.marker, marker, "输入：\(text.debugDescription)", file: file, line: line)
        XCTAssertEqual(result.body, body, "输入：\(text.debugDescription)", file: file, line: line)
    }
}
