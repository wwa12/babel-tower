import Foundation

/// 首行协议解析（纯函数）。契约 与
/// - 缓冲流式输出，首行出现语言标记时，其后（第二行起）为译文；
/// - `[[same]]`：原文已是目标语言；`[[none]]`：没有可翻译的文字；
/// - 前 20 个字符内没有合法标记：全部输出当译文，不报错。
enum MarkerParser {

    /// 解析出的首行标记。
    enum Marker: Equatable, Sendable {
        /// 译文目标语言（四种之一），界面高亮对应选项。
        case language(TranslationLanguage)
        /// 原文已是目标语言，正文按原样显示。
        case same
        /// 图片里没有可翻译的文字。
        case none
        /// 前 20 字符无合法标记，全部输出整体当译文（容错，不报错）。
        case passthrough
        /// 内容还不足以判定，继续缓冲流式输出。
        case pending
    }

    /// 解析结果。
    struct Result: Equatable, Sendable {
        let marker: Marker
        /// 译文正文：language / same 为标记行之后的内容；passthrough 为全部内容；none / pending 为空。
        let body: String
    }

    /// 标记原文与语义的对照表（系统提示词【输出格式】一节）。
    private static let rawMarkers: [(raw: String, marker: Marker)] = [
        ("[[zh-Hans]]", .language(.zhHans)),
        ("[[zh-Hant]]", .language(.zhHant)),
        ("[[ja]]", .language(.ja)),
        ("[[en]]", .language(.en)),
        ("[[same]]", .same),
        ("[[none]]", .none),
    ]

    static func parse(_ text: String) -> Result {
        // 在扫描窗口内找最早出现的合法标记；判定规则：标记起始位置 < 20（"前 20 个字符内"）。
        let limit = BehaviorConstants.markerScanCharacterLimit
        var hit: (range: Range<String.Index>, marker: Marker)?
        for candidate in rawMarkers {
            // 每个候选只看首个出现：更晚的出现不可能比已记录的标记更早
            guard let found = text.range(of: candidate.raw) else { continue }
            if text.distance(from: text.startIndex, to: found.lowerBound) >= limit {
                continue
            }
            if let current = hit, found.lowerBound >= current.range.lowerBound {
                continue
            }
            hit = (found, candidate.marker)
        }

        if let hit {
            // [[none]] 表示没有可翻译文字，一律没有正文。
            if case .none = hit.marker {
                return Result(marker: .none, body: "")
            }
            return Result(marker: hit.marker, body: body(after: hit.range, in: text))
        }

        // 没有标记：窗口已满（≥20 字符）或首行已完整（出现换行）→ 整体当译文；否则继续缓冲。
        let bufferedPastWindow = text.count >= limit
        let firstLineComplete = text.contains("\n")
        if bufferedPastWindow || firstLineComplete {
            return Result(marker: .passthrough, body: text)
        }
        return Result(marker: .pending, body: "")
    }

    /// 取标记所在行之后的内容：正文从标记后的首个换行开始；标记行上的多余内容按契约丢弃；
    /// 标记后还没有换行（截断/模型没按格式换行）时，取标记之后已有内容。[[none]] 一律没有正文。
    private static func body(after markerRange: Range<String.Index>, in text: String) -> String {
        let afterMarker = markerRange.upperBound
        guard afterMarker < text.endIndex else {
            return ""
        }
        if let newline = text.range(of: "\n", range: afterMarker..<text.endIndex) {
            let bodyStart = text.index(after: newline.lowerBound)
            guard bodyStart < text.endIndex else {
                return ""
            }
            return String(text[bodyStart...])
        }
        return String(text[afterMarker...])
    }
}
