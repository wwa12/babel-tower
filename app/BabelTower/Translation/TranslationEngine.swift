import Foundation

/// 翻译引擎对外的事件流。界面按序消费：
/// 标记判定 → 译文增量 → 终态（finished / failed 二选一，必有其一）。
enum TranslationEvent: Equatable, Sendable {
    /// 首行标记判定完成，界面高亮语言或显示 same / none 提示
    case markerResolved(MarkerParser.Marker)
    /// 译文增量（已剥掉首行标记；标记判定前不会收到任何增量）
    case delta(String)
    /// 正常完成：最终标记与完整译文正文
    case finished(marker: MarkerParser.Marker, body: String)
    /// 失败：分类见 TranslationFailure
    case failed(TranslationFailure)
}

/// 翻译引擎：
/// - 同一时间只保留一个请求，新请求取消旧请求；被取代的旧请求不再上报任何事件；
/// - 首字（首个内容增量）15 秒超时，超时取消请求并报错；
/// - 标记感知缓冲：接 MarkerParser，判定前缓冲、判定后直通；
/// - SSE 解析在后台任务执行，事件经 AsyncStream 回主线程。
@MainActor
final class TranslationEngine {

    private let client: OpenAICompatibleClient
    private let firstTokenTimeout: TimeInterval

    /// 代际计数：每次新翻译 +1。旧任务用它判断自己是否已被取代（取代后静默）。
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    /// 触发了首字超时的代际（区分"超时取消"与"被取代/显式取消"）
    private var timedOutGeneration: Int?

    init(client: OpenAICompatibleClient = OpenAICompatibleClient(),
         firstTokenTimeout: TimeInterval = BehaviorConstants.firstTokenTimeout) {
        self.client = client
        self.firstTokenTimeout = firstTokenTimeout
    }

    /// 是否有进行中的请求（未终态、未被取代）。
    var hasActiveRequest: Bool { currentTask != nil }

    // MARK: 请求构造（纯函数，供测试与请求体校验）

    /// 最大输出 token：输入字符数的 3 倍且不少于 512。
    /// 字符数近似 token 数（CJK 约一字一 token；英文按字符数会高估，但 max_tokens 只是上限，不多耗）。
    static func maxOutputTokens(forTextLength characterCount: Int) -> Int {
        max(BehaviorConstants.textOutputTokenFloor,
            characterCount * BehaviorConstants.textOutputTokenMultiplier)
    }

    /// 翻译请求体：Prompt 契约（系统提示词 + `<source>` 用户消息）+ stream + max_tokens
    /// + 预设关闭思考参数（参数在配置，不在代码分支）。
    /// customPrompt：自定义系统提示词模板，空则用内置默认。
    static func translationBody(text: String,
                                target: TranslationTarget,
                                customPrompt: String = "",
                                config: ResolvedServiceConfig) -> [String: JSONValue] {
        [
            "model": .string(config.model),
            "messages": .array([
                .object([
                    "role": .string("system"),
                    "content": .string(TranslationPrompt.resolvedSystemPrompt(template: customPrompt, for: target)),
                ]),
                .object([
                    "role": .string("user"),
                    "content": .string(TranslationPrompt.userMessage(text: text)),
                ]),
            ]),
            "stream": .bool(true),
            "max_tokens": .number(Double(maxOutputTokens(forTextLength: text.count))),
        ].merging(config.disableThinkingParameters) { current, _ in current }
    }

    /// 图文混合请求体（文字放 <source>，图片按添加顺序附加）。
    /// 纯文字时 content 为字符串（与上一个方法一致）；含图片时为 parts 数组。
    /// max_tokens：图片取 4,096，与文字规则取大。
    static func translationBody(text: String,
                                images: [ProcessedImage],
                                target: TranslationTarget,
                                customPrompt: String = "",
                                config: ResolvedServiceConfig) -> [String: JSONValue] {
        var userContent: JSONValue
        if images.isEmpty {
            userContent = .string(TranslationPrompt.userMessage(text: text))
        } else {
            var parts: [JSONValue] = []
            if !text.isEmpty {
                parts.append(.object([
                    "type": .string("text"),
                    "text": .string(TranslationPrompt.userMessage(text: text)),
                ]))
            }
            for image in images {
                parts.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:\(image.mimeType);base64,\(image.data.base64EncodedString())"),
                    ]),
                ]))
            }
            userContent = .array(parts)
        }

        let textTokens = maxOutputTokens(forTextLength: text.count)
        let outputTokens = images.isEmpty ? textTokens : max(textTokens, BehaviorConstants.imageOutputTokenLimit)

        return [
            "model": .string(config.model),
            "messages": .array([
                .object([
                    "role": .string("system"),
                    "content": .string(TranslationPrompt.resolvedSystemPrompt(template: customPrompt, for: target)),
                ]),
                .object([
                    "role": .string("user"),
                    "content": userContent,
                ]),
            ]),
            "stream": .bool(true),
            "max_tokens": .number(Double(outputTokens)),
        ].merging(config.disableThinkingParameters) { current, _ in current }
    }

    // MARK: 执行

    /// 发起翻译。开始前取消进行中的请求（单请求语义）；
    /// 事件经 onEvent 在主线程上报；被取代或显式取消的请求不再上报。
    /// customPrompt：自定义系统提示词模板，空则用内置默认。
    func translate(text: String,
                   target: TranslationTarget,
                   customPrompt: String = "",
                   config: ResolvedServiceConfig,
                   onEvent: @escaping (TranslationEvent) -> Void) {
        translate(text: text, images: [], target: target, customPrompt: customPrompt, config: config, onEvent: onEvent)
    }

    /// 图文混合翻译：一轮请求同时携带文字与图片，取消/超时/流式语义与纯文字一致。
    func translate(text: String,
                   images: [ProcessedImage],
                   target: TranslationTarget,
                   customPrompt: String = "",
                   config: ResolvedServiceConfig,
                   onEvent: @escaping (TranslationEvent) -> Void) {
        generation += 1
        let myGeneration = generation
        // 先作废旧请求：其挂起的网络与待发事件全部失效
        currentTask?.cancel()

        currentTask = Task { [weak self] in
            guard let self else { return }

            /// 只按代际判定有效性：被取代 / 显式取消都会推进代际。
            /// 不能检查 Task.isCancelled——首字超时正是靠取消本任务中断流的，超时事件仍需上报。
            let emit: @MainActor (TranslationEvent) -> Void = { event in
                guard self.generation == myGeneration else { return }
                onEvent(event)
            }

            // 首字看门狗：从请求发出就开始计时，覆盖建连与等待首个内容增量的全程
            // （URLSession.bytes 可能等到响应体首字节才返回，计时不能晚于它）；
            // 首字到达即解除。睡眠只是挂起，不阻塞主线程；先算秒再转纳秒（直接转 UInt64 会截断小数）。
            let watchdog = Task { [weak self] in
                let nanoseconds = UInt64((self?.firstTokenTimeout ?? 0) * 1_000_000_000)
                // try? 吞的是看门狗自身被取消的 CancellationError——那正是"首字已到、解除计时"的预期路径
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.enforceFirstTokenTimeout(generation: myGeneration)
            }
            defer { watchdog.cancel() }

            let body = Self.translationBody(text: text, images: images, target: target, customPrompt: customPrompt, config: config)
            let bytes: URLSession.AsyncBytes
            do {
                bytes = try await self.client.openStream(config: config, body: body)
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession 取消抛 URLError(.cancelled)：首字超时取消（上报超时）
                // 或被取代 / 显式取消（静默）
                if self.timedOutGeneration == myGeneration {
                    emit(.failed(.firstTokenTimeout))
                }
                self.finishTask(generation: myGeneration)
                return
            } catch is CancellationError {
                if self.timedOutGeneration == myGeneration {
                    emit(.failed(.firstTokenTimeout))
                }
                self.finishTask(generation: myGeneration)
                return
            } catch let failure as TranslationFailure {
                emit(.failed(failure))
                self.finishTask(generation: myGeneration)
                return
            } catch let urlError as URLError {
                emit(.failed(TranslationFailure.from(error: urlError)))
                self.finishTask(generation: myGeneration)
                return
            } catch {
                emit(.failed(.requestBuildFailed))
                self.finishTask(generation: myGeneration)
                return
            }

            // 后台任务消费 SSE 字节流，事件经 AsyncStream（Sendable 通道）回主线程
            let (stream, continuation) = AsyncStream<InternalEvent>.makeStream()
            let outcome: ConsumptionOutcome = await withTaskGroup(of: ConsumptionOutcome.self) { group in
                group.addTask {
                    let result = await Self.consume(bytes: bytes, continuation: continuation)
                    continuation.finish()
                    return result
                }
                var received = ConsumptionOutcome.cancelled
                for await internalEvent in stream {
                    switch internalEvent {
                    case .firstContent:
                        watchdog.cancel()   // 首字到达，解除看门狗（Task.cancel 线程安全）
                    case .ui(let event):
                        emit(event)
                    case .outcome(let result):
                        received = result
                    }
                }
                group.cancelAll()
                if let groupResult = await group.next() {
                    received = groupResult
                }
                return received
            }

            watchdog.cancel()
            if outcome == .cancelled, self.timedOutGeneration == myGeneration {
                emit(.failed(.firstTokenTimeout))
            }
            self.finishTask(generation: myGeneration)
        }
    }

    /// 显式取消当前请求（如 ⌘N 清空），取消后不再上报事件（收起不取消，仅清空取消）。
    func cancel() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: 内部

    /// 后台消费任务 → 主线程的内部事件。
    private enum InternalEvent: Sendable {
        case firstContent
        case ui(TranslationEvent)
        case outcome(ConsumptionOutcome)
    }

    /// 流消费的终态。
    private enum ConsumptionOutcome: Sendable {
        /// 正常完成或失败（对应 ui 事件已发出）
        case terminal
        /// 流被取消：超时（由 translate 上报 firstTokenTimeout）或被取代/显式取消（静默）
        case cancelled
    }

    private func enforceFirstTokenTimeout(generation targetGeneration: Int) {
        guard generation == targetGeneration, currentTask != nil else { return }
        timedOutGeneration = targetGeneration
        currentTask?.cancel()
    }

    private func finishTask(generation finishedGeneration: Int) {
        if generation == finishedGeneration {
            currentTask = nil
        }
    }

    /// 消费 SSE 字节流直到终态（非隔离 async：在全局执行器上运行，SSE 解析离主线程）。
    /// 事件全部经 continuation 投递；返回消费终态。
    nonisolated private static func consume(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncStream<InternalEvent>.Continuation
    ) async -> ConsumptionOutcome {
        var parser = SSEParser()
        var pendingBeforeMarker = ""
        var resolvedMarker: MarkerParser.Marker?
        /// 标记已判定但标记行还没结束（未见换行）：标记后的内容按"候选正文"暂存——
        /// 换行到达则弃候选、正文从换行后开始（对齐 MarkerParser 完整文本语义：正文从第二行起）；
        /// 流结束仍无换行则采用候选（对齐 MarkerParser 的截断 fallback：取标记之后已有内容）。
        var awaitingMarkerNewline = false
        var candidateBody = ""
        var body = ""
        var firstContentSeen = false

        /// 流结束时的收尾：还有未上屏的候选正文就补上（fallback 语义），再发终态事件。
        /// 事件经闭包构造：必须在补发之后求值，finished 里携带的才是完整 body。
        func terminal(flushUnmarked: Bool = false,
                      _ makeEvent: () -> TranslationEvent) -> ConsumptionOutcome {
            // 正常结束时标记仍未判定（输出不足 20 字、单行、没有合法标记——模型漏写标记的短译文）：
            // 按首行协议的容错规则整体当译文，不能丢（翻单词短句时译文被吞成空白）。
            // 只在正常完成时补发；拒绝 / 出错时不把未判定内容当译文；
            // 以 "[[" 开头的是写了一半的标记，不是译文
            if flushUnmarked, resolvedMarker == nil, !pendingBeforeMarker.isEmpty,
               !pendingBeforeMarker.hasPrefix("[[") {
                resolvedMarker = .passthrough
                continuation.yield(.ui(.markerResolved(.passthrough)))
                body += pendingBeforeMarker
                continuation.yield(.ui(.delta(pendingBeforeMarker)))
                pendingBeforeMarker = ""
            }
            if awaitingMarkerNewline, !candidateBody.isEmpty,
               !(resolvedMarker?.isNoneMarker ?? false) {
                let flush = candidateBody
                candidateBody = ""
                awaitingMarkerNewline = false
                body += flush
                continuation.yield(.ui(.delta(flush)))
            }
            continuation.yield(.ui(makeEvent()))
            return .terminal
        }

        do {
            // 逐字节迭代：AsyncBytes 无块接口；翻译流为 KB 量级，开销可忽略
            for try await byte in bytes {
                for event in parser.append(Data([byte])) {
                    switch event {
                    case .content(let chunk):
                        if !firstContentSeen {
                            firstContentSeen = true
                            continuation.yield(.firstContent)
                        }
                        if let marker = resolvedMarker {
                            guard !marker.isNoneMarker else { continue }   // [[none]] 一律没有正文
                            if awaitingMarkerNewline {
                                if let newline = chunk.firstIndex(of: "\n") {
                                    // 标记行结束：候选作废，正文从换行后开始
                                    awaitingMarkerNewline = false
                                    candidateBody = ""
                                    let rest = String(chunk[chunk.index(after: newline)...])
                                    if !rest.isEmpty {
                                        body += rest
                                        continuation.yield(.ui(.delta(rest)))
                                    }
                                } else {
                                    // 还在标记行上：继续攒候选，不上报
                                    candidateBody += chunk
                                }
                            } else {
                                body += chunk
                                continuation.yield(.ui(.delta(chunk)))
                            }
                        } else {
                            pendingBeforeMarker += chunk
                            let result = MarkerParser.parse(pendingBeforeMarker)
                            switch result.marker {
                            case .pending:
                                break   // 继续缓冲，不上报任何正文
                            case .none, .same, .language, .passthrough:
                                resolvedMarker = result.marker
                                continuation.yield(.ui(.markerResolved(result.marker)))
                                // passthrough 无标记行，正文直通；其余标记若已见换行，正文从换行后起；
                                // 未见换行则标记后内容先按候选暂存
                                let markerLineOpen = !pendingBeforeMarker.contains("\n")
                                    && result.marker != .passthrough
                                if markerLineOpen {
                                    awaitingMarkerNewline = true
                                    candidateBody = result.body
                                } else if !result.body.isEmpty, !result.marker.isNoneMarker {
                                    body += result.body
                                    continuation.yield(.ui(.delta(result.body)))
                                }
                            }
                        }
                    case .refusal:
                        // 模型拒绝处理内容（显示"模型拒绝了这段内容"，不留空白）
                        return terminal { .failed(.modelRefused) }
                    case .finished:
                        return terminal(flushUnmarked: true) { .finished(marker: resolvedMarker ?? .passthrough, body: body) }
                    case .streamError(let message):
                        // 流中断：已发出的增量与候选正文都有效（保留已收到的译文并标注未完成）
                        if firstContentSeen {
                            return terminal { .failed(.streamInterrupted(detail: message)) }
                        }
                        return terminal { .failed(.serviceError(status: 0, detail: message)) }
                    }
                }
            }
            // 字节流正常结束但没有 [DONE]：按完成处理
            return terminal(flushUnmarked: true) { .finished(marker: resolvedMarker ?? .passthrough, body: body) }
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession 取消抛 URLError(.cancelled)：视为取消，不做失败上报
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch let urlError as URLError {
            // 已有译文上屏后断网 / 连接中断：已收到的译文有效，按"流式中断"处理（保留并标注未完成）。
            // 标记还没判定、界面上什么都没有时，仍按网络问题提示
            if !body.isEmpty {
                return terminal { .failed(.streamInterrupted(detail: nil)) }
            }
            return terminal { .failed(TranslationFailure.from(error: urlError)) }
        } catch {
            return terminal { .failed(.streamInterrupted(detail: nil)) }
        }
    }
}

private extension MarkerParser.Marker {
    var isNoneMarker: Bool {
        if case .none = self { return true }
        return false
    }
}
