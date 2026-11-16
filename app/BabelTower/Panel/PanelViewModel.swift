import Foundation
import AppKit
import Combine

/// 浮窗一轮翻译的相位。
enum PanelPhase: Equatable {
    case empty
    case composing
    case translating
    case finished
    case failed(TranslationFailure)
}

/// 结果区上方 / 内嵌的提示条内容。
enum PanelBanner: Equatable {
    /// 原文已是目标语言（语言名随实际情况）
    case sameAsSource(language: TranslationLanguage)
    /// 图片里没有可翻译的文字（[[none]]）
    case noTextInImage
}

/// 输入区的图片项：缩略图用于显示，processed 用于请求。
struct PanelImage: Identifiable {
    let id = UUID()
    let thumbnail: NSImage
    let processed: ProcessedImage
}

/// 图片预处理在哪里执行。
enum ImageProcessingMode {
    /// 后台执行，处理期间显示占位缩略图（App 使用：大图解码不卡界面）
    case background
    /// 当场同步执行（单元测试使用：断言不必等待）
    case synchronous
}

/// 一张待处理的图片来源。
private enum ImageInput: Sendable {
    case data(Data)
    case file(URL)

    func process() -> ProcessedImage? {
        switch self {
        case .data(let data): ImagePreprocessor.process(data: data)
        case .file(let url): ImagePreprocessor.process(fileURL: url)
        }
    }
}

/// 浮窗视图模型：一轮翻译的完整状态机。
/// 事件消费来自 TranslationEngine；剪贴板带入来自 ClipboardMonitor；
/// 复制写剪贴板并标记 ownWrite；收起不清内容（保留 10 分钟）。
@MainActor
final class PanelViewModel: ObservableObject {

    @Published private(set) var phase: PanelPhase = .empty
    /// 输入文字。直接绑定输入框；didIt 更新超限标记与相位
    @Published var inputText: String = "" {
        didSet { inputDidChange(from: oldValue) }
    }
    @Published private(set) var resultText: String = ""
    @Published private(set) var marker: MarkerParser.Marker?
    @Published private(set) var targetMode: TargetMode = .automatic
    @Published private(set) var isInputOverLimit = false
    /// 复制按钮的对勾标记（0.8 秒后自动复位）
    @Published private(set) var copyConfirmed = false
    /// 输入区图片（≤4 张，缩略图显示）
    @Published private(set) var images: [PanelImage] = []
    /// 正在后台处理的图片数（输入区显示同等数量的占位缩略图）
    @Published private(set) var pendingImageCount = 0
    /// 图片相关提示（超上限 / 无法解码），下一步操作时清除
    @Published private(set) var imageNotice: String?
    /// 图钉固定状态：固定时点击外部/Esc 不收起、↩ 复制不收起。
    /// 不跨呼出记忆：呼出时复位。
    @Published private(set) var isPinned = false

    /// 主语言 / 常用外语（默认简中、英语）。闭包调用时求值：
    /// 设置里的修改从下一轮翻译起生效。
    private let mainLanguage: () -> TranslationLanguage
    private let foreignLanguage: () -> TranslationLanguage

    /// 自定义系统提示词。闭包调用时求值：
    /// 设置里的修改从下一轮翻译起生效；空字符串发送时按内置默认兜底。
    private let customPrompt: () -> String

    private let engine: TranslationEngine
    private let settings: ModelServiceSettings
    private let clipboardMonitor: ClipboardMonitor
    private let pasteboard: NSPasteboard
    private let now: () -> Date
    private let collapseHandler: () -> Void

    /// 本轮翻译发起时的输入（判定"完成后 ↩ 且输入未改"才复制收起）
    private var inputAtRoundStart = ""
    /// 本轮翻译发起时的图片（按身份比对：删一张再加一张数量不变，但内容变了）
    private var imageIDsAtRoundStart: [UUID] = []
    /// 最近一轮活动时间（收起时锚定，10 分钟保留判定）
    private var lastRoundActivityAt: Date?
    private var copyConfirmTask: Task<Void, Never>?
    private let imageProcessingMode: ImageProcessingMode
    /// 图片批次代际：新一轮 / 清空时 +1，作废尚未处理完的批次
    private var imageBatchGeneration = 0
    /// 批次串行链：后粘贴的批次等前一批完成再追加，保证图片顺序 = 添加顺序
    private var imageBatchChain: Task<Void, Never>?
    /// 图片处理期间收到了"要翻译"的意图（↩ / ⌘R / 切语言 / 新图追加）：
    /// 全部批次处理完后统一发一次请求，意图不丢、也不发缺图的请求
    private var translateWhenImagesReady = false

    private var hasPendingImages: Bool { pendingImageCount > 0 }

    init(engine: TranslationEngine,
         settings: ModelServiceSettings,
         clipboardMonitor: ClipboardMonitor,
         pasteboard: NSPasteboard = .general,
         now: @escaping () -> Date = { Date() },
         collapse: @escaping () -> Void,
         mainLanguage: @escaping () -> TranslationLanguage = { .zhHans },
         foreignLanguage: @escaping () -> TranslationLanguage = { .en },
         customPrompt: @escaping () -> String = { "" },
         imageProcessingMode: ImageProcessingMode = .background) {
        self.imageProcessingMode = imageProcessingMode
        self.engine = engine
        self.settings = settings
        self.clipboardMonitor = clipboardMonitor
        self.pasteboard = pasteboard
        self.now = now
        self.collapseHandler = collapse
        self.mainLanguage = mainLanguage
        self.foreignLanguage = foreignLanguage
        self.customPrompt = customPrompt
    }

    // MARK: 呼出 / 收起

    /// 呼出：新鲜剪贴板带入（文字）；否则 10 分钟内保留上轮内容。
    func panelWillShow() {
        // 固定状态不跨呼出记忆：呼出恢复非固定
        isPinned = false
        // 呼出即预热连接：配置可解析就先建连压首字延迟。
        // best-effort：配置未就绪时跳过，真正翻译时再给出配置提示
        do {
            ConnectionWarmer.warm(config: try settings.resolvedConfig())
        } catch {
            // 配置问题在翻译时提示，预热静默跳过
        }

        if let snapshot = clipboardMonitor.lastSnapshot,
           clipboardMonitor.isFreshContent(snapshot) {
            switch ClipboardParser.parse(pasteboard) {
            case .plainText(let text):
                clipboardMonitor.markConsumed(snapshot)
                startNewRound(withInput: text)   // 自动带入并翻译
                return
            case .imageFiles(let urls):
                clipboardMonitor.markConsumed(snapshot)
                startNewRound()
                handlePasteImageFiles(urls)
                return
            case .imageBitmap(let data):
                clipboardMonitor.markConsumed(snapshot)
                startNewRound()
                handlePasteImage(data: data)
                return
            case nil:
                break
            }
        }

        // 无新内容：保留期内的上一轮继续显示
        if let lastActivity = lastRoundActivityAt,
           now().timeIntervalSince(lastActivity) <= BehaviorConstants.contentRetentionInterval {
            return
        }
        resetToEmpty()
    }

    /// 收起：内容保留，锚定保留期；翻译请求继续、结果保留。
    /// 收起同时解除固定（呼出复位是第二道保险）。
    func panelDidCollapse() {
        isPinned = false
        lastRoundActivityAt = now()
    }

    // MARK: 输入与触发

    /// 粘贴文字：向空输入区（无文字无图片）粘贴立即翻译；已有内容只追加等待 ↩（图片也是内容）。
    /// 空区粘贴视为新一轮（手动目标复位，与 ⌘N / 呼出带入一致）。
    func handlePaste(_ text: String) {
        guard !text.isEmpty else { return }
        if inputText.isEmpty && images.isEmpty && !hasPendingImages {
            targetMode = .automatic
            inputText = text
            if !isInputOverLimit {
                startTranslation()
            }
        } else {
            inputText += text
        }
    }

    /// ↩：未发送→翻译；已完成且输入未改→复制并收起（
    /// 固定时只复制不收起）。
    func submit() {
        // 还有图片在处理：内容已经变了，不能复制上一轮的译文；等处理完按全部内容翻译
        if hasPendingImages {
            translateWhenImagesReady = true
            return
        }
        // 输入未改 = 文字与图片都与本轮发起时一致（删图也是改动，否则删图后 ↩ 会复制旧译文）
        if case .finished = phase, inputText == inputAtRoundStart,
           images.map(\.id) == imageIDsAtRoundStart, !resultText.isEmpty {
            copyResult(selection: nil, andCollapse: !isPinned)
            return
        }
        // 翻译中且输入与图片都未改：no-op，不重复发请求（浪费 token）
        if case .translating = phase, inputText == inputAtRoundStart,
           images.map(\.id) == imageIDsAtRoundStart {
            return
        }
        guard !inputText.isEmpty || !images.isEmpty else { return }
        guard !isInputOverLimit else { return }
        startTranslation()
    }

    /// ⌘R：相同输入重新翻译。
    func retranslate() {
        if hasPendingImages {
            translateWhenImagesReady = true
            return
        }
        guard !inputText.isEmpty || !images.isEmpty else { return }
        guard !isInputOverLimit else { return }
        startTranslation()
    }

    /// ⌘N：清空开始新一轮；翻译中则取消请求。
    func clearRound() {
        engine.cancel()
        resetToEmpty()
    }

    /// ⌘1–4 / ⌘0：切换目标语言；已有输入立即重译；手动只本轮有效。
    func setTargetMode(_ mode: TargetMode) {
        targetMode = mode
        // 图片也是输入：纯图片时同样立即重译。图片还在处理时记下意图，处理完按新语言翻译
        if hasPendingImages {
            translateWhenImagesReady = true
            return
        }
        if !inputText.isEmpty || !images.isEmpty, !isInputOverLimit {
            startTranslation()
        }
    }

    /// 图钉开关：进入/退出固定状态。
    /// 收起路径不受影响——⌥T 仍可收起固定中的浮窗（唯一手动收起入口）。
    func togglePinned() {
        isPinned.toggle()
    }

    // MARK: 复制

    /// 复制译文。selection 非空复制选区；andCollapse 时复制全文并收起（↩ 路径）。
    func copyResult(selection: String?, andCollapse: Bool) {
        let text = selection ?? resultText
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // 本 App 写入不算新内容
        clipboardMonitor.noteOwnWrite(changeCount: pasteboard.changeCount)
        flashCopyConfirmation()
        if andCollapse {
            endRound()
            collapseHandler()
        }
    }

    func copyButtonTapped() {
        copyResult(selection: nil, andCollapse: false)
    }

    var banner: PanelBanner? {
        switch marker {
        case .some(.same):
            return .sameAsSource(language: currentTargetLanguage)
        case .some(MarkerParser.Marker.none):
            return .noTextInImage
        default:
            return nil
        }
    }

    /// 语言栏当前应高亮的语言：finished 后高亮实际译入语言。
    var highlightedLanguage: TranslationLanguage? {
        if case .language(let language) = marker {
            return language
        }
        return nil
    }

    // MARK: 内部

    private var currentTargetLanguage: TranslationLanguage {
        switch targetMode {
        case .automatic: mainLanguage()
        case .manual(let language): language
        }
    }

    private func resolveTarget() -> TranslationTarget {
        switch targetMode {
        case .automatic:
            .automatic(main: mainLanguage(), foreign: foreignLanguage())
        case .manual(let language):
            .manual(language)
        }
    }

    #if DEBUG
    /// 测试钩子：直接置入完成终态（驱动派生状态断言，不发请求）。
    func forceFinishedForTesting(marker: MarkerParser.Marker, body: String) {
        self.marker = marker
        resultText = body
        phase = .finished
    }
    #endif

    /// 空译文提示（不留空白；完成但无正文时给提示可重试）。
    var showsEmptyResultHint: Bool {
        if case .finished = phase, resultText.isEmpty {
            return marker != MarkerParser.Marker.none   // [[none]] 有专门提示
        }
        return false
    }

    private func inputDidChange(from oldValue: String) {
        isInputOverLimit = inputText.count > BehaviorConstants.maxTextCharacters
        guard inputText != oldValue else { return }
        // 输入变化：上一轮的 same/none 提示与语言高亮随之失效
        marker = nil
        // 输入变化脱离"完成后"相位（结果保留显示，↩ 将按新内容重译）；
        // 有图片（含处理中的）时空文字仍是有内容状态
        let hasContent = hasInputContent
        if case .finished = phase {
            phase = hasContent ? .composing : .empty
        } else if phase != .translating {
            phase = hasContent ? .composing : .empty
        }
    }

    /// 新一轮：带入剪贴板内容（自动目标复位 新一轮回自动）。
    private func startNewRound(withInput text: String) {
        startNewRound()
        inputText = text
        if isInputOverLimit {
            phase = .composing   // 超限带入：不发包，显示字数等用户处理
            return
        }
        startTranslation()
    }

    private func startNewRound() {
        targetMode = .automatic
        discardPendingImages()
        images = []
        imageNotice = nil
        resultText = ""
        marker = nil
        inputText = ""
    }

    private func startTranslation() {
        let config: ResolvedServiceConfig
        do {
            config = try settings.resolvedConfig()
        } catch let error as ServiceConfigError {
            phase = .failed(.configuration(error))
            return
        } catch {
            phase = .failed(.requestBuildFailed)
            return
        }
        // 所选模型不支持图片：提示更换模型并附去设置
        if let failure = Self.imageSupportFailure(for: config, hasImages: !images.isEmpty) {
            phase = .failed(failure)
            return
        }

        inputAtRoundStart = inputText
        imageIDsAtRoundStart = images.map(\.id)
        imageNotice = nil
        resultText = ""
        marker = nil
        phase = .translating
        lastRoundActivityAt = now()

        engine.translate(
            text: inputText,
            images: images.map(\.processed),
            target: resolveTarget(),
            customPrompt: customPrompt(),
            config: config
        ) { [weak self] event in
            self?.handleEngineEvent(event)
        }
    }

    /// 模型不支持图片的失败（提示更换模型，附「去设置」）。
    static func imageSupportFailure(for config: ResolvedServiceConfig,
                                    hasImages: Bool) -> TranslationFailure? {
        guard hasImages, !config.supportsImages else { return nil }
        return .modelDoesNotSupportImages
    }

    // MARK: 图片输入

    /// 粘贴位图：解码→预处理→追加→立即按全部内容重译；超上限/失败给提示。
    func handlePasteImage(data: Data) {
        enqueueImages([.data(data)])
    }

    /// 单个图片文件（拖入）。
    func handlePasteImageFile(url: URL) {
        handlePasteImageFiles([url])
    }

    /// 图片文件（访达复制 / 拖入）：先查扩展名白名单与单文件 20MB，
    /// 通过的作为一批处理，全部处理完一次发包（不触发中间态翻译）。
    func handlePasteImageFiles(_ urls: [URL]) {
        var accepted: [ImageInput] = []
        for url in urls {
            guard ClipboardParser.imageFileExtensions.contains(url.pathExtension.lowercased()) else {
                continue   // 非白名单文件：无反应（与 ⌘V 剪贴板白名单口径一致）
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if size > BehaviorConstants.maxImageFileSize {
                imageNotice = AppText.panelImageFileTooLarge
                continue
            }
            accepted.append(.file(url))
        }
        enqueueImages(accepted)
    }

    /// 输入区是否已有内容（文字或图片）。
    var hasInputContent: Bool { !inputText.isEmpty || !images.isEmpty || pendingImageCount > 0 }

    /// 从粘贴板取内容分发给文字 / 图片处理（⌘V、拖入、呼出带入共用）。
    func handlePasteboardContent(_ pasteboard: NSPasteboard) {
        switch ClipboardParser.parse(pasteboard) {
        case .plainText(let text):
            handlePaste(text)
        case .imageFiles(let urls):
            handlePasteImageFiles(urls)
        case .imageBitmap(let data):
            handlePasteImage(data: data)
        case nil:
            break
        }
    }

    /// 输入框为空时 ⌫ 删除最后一张。
    func deleteLastImage() {
        // 处理中时最后一张是占位图，⌫ 删不到它，先不响应
        guard inputText.isEmpty, !images.isEmpty, !hasPendingImages else { return }
        images.removeLast()
        imageNotice = nil
        imagesDidChangeByUser()
    }

    func removeImage(_ id: UUID) {
        images.removeAll { $0.id == id }
        imageNotice = nil
        imagesDidChangeByUser()
    }

    /// 用户删图：与改文字同样处理——上一轮的标记失效，完成态回到待发送（↩ 将按剩下的内容重译）。
    private func imagesDidChangeByUser() {
        marker = nil
        let hasContent = hasInputContent
        if phase != .translating {
            phase = hasContent ? .composing : .empty
        }
    }

    /// 一次添加动作 = 一批图片：受 4 张上限约束（已处理的 + 处理中的），处理完按添加顺序追加，
    /// 只要追加了图片就立即按全部内容重译（粘贴图片立即翻译，取消当前请求）。
    /// 后台模式下处理在后台线程执行（4800 万像素 HEIC 单张约 100ms，多张会卡界面）。
    private func enqueueImages(_ inputs: [ImageInput]) {
        guard !inputs.isEmpty else { return }
        let room = BehaviorConstants.maxImageCount - images.count - pendingImageCount
        let batch = Array(inputs.prefix(max(room, 0)))
        if batch.count < inputs.count {
            imageNotice = AppText.panelTooManyImages   // 拒绝多出的并提示
        }
        guard !batch.isEmpty else { return }

        switch imageProcessingMode {
        case .synchronous:
            finishImageBatch(batch.map { $0.process() })
        case .background:
            pendingImageCount += batch.count
            translateWhenImagesReady = true   // 粘贴图片 = 要翻译
            imagesDidChangeByUser()           // 内容已变：完成态回到待发送，↩ 不会复制旧译文
            let generation = imageBatchGeneration
            let previous = imageBatchChain
            imageBatchChain = Task { [weak self] in
                await previous?.value
                let results = await Task.detached(priority: .userInitiated) {
                    batch.map { $0.process() }
                }.value
                guard let self, generation == self.imageBatchGeneration else { return }
                self.pendingImageCount -= batch.count
                self.finishImageBatch(results)
            }
        }
    }

    private func finishImageBatch(_ results: [ProcessedImage?]) {
        var appended = false
        var undecodable = false
        for result in results {
            guard let processed = result else {
                undecodable = true
                continue
            }
            guard images.count < BehaviorConstants.maxImageCount else {
                imageNotice = AppText.panelTooManyImages
                continue
            }
            images.append(PanelImage(thumbnail: NSImage(data: processed.data) ?? NSImage(),
                                     processed: processed))
            appended = true
        }
        if undecodable {
            imageNotice = AppText.panelImageUndecodable
        } else if appended, imageNotice != AppText.panelTooManyImages {
            imageNotice = nil
        }
        switch imageProcessingMode {
        case .synchronous:
            if appended, !isInputOverLimit {
                startTranslation()
            }
        case .background:
            // 全部批次处理完才发一次请求；中途的翻译意图（↩ / 切语言）在这里兑现
            guard !hasPendingImages, translateWhenImagesReady else { return }
            translateWhenImagesReady = false
            if hasInputContent, !isInputOverLimit {
                // 发起翻译会清掉图片提示；本批产生的提示（无法读取 / 超张数）要留给用户看到
                let batchNotice = imageNotice
                startTranslation()
                if batchNotice != nil { imageNotice = batchNotice }
            } else if phase != .translating {
                phase = hasInputContent ? .composing : .empty
            }
        }
    }

    /// 测试与界面用：等待所有处理中的图片批次完成。
    func waitForPendingImages() async {
        await imageBatchChain?.value
    }

    private func handleEngineEvent(_ event: TranslationEvent) {
        switch event {
        case .markerResolved(let resolved):
            marker = resolved
        case .delta(let text):
            resultText += text
        case .finished(let finishedMarker, let body):
            marker = finishedMarker
            resultText = body
            phase = .finished
            lastRoundActivityAt = now()
        case .failed(let failure):
            phase = .failed(failure)
            lastRoundActivityAt = now()
        }
    }

    /// 一轮结束（复制带走）：手动目标复位，输入保留至保留期。
    private func endRound() {
        targetMode = .automatic
        lastRoundActivityAt = now()
    }

    private func resetToEmpty() {
        inputText = ""
        resultText = ""
        marker = nil
        targetMode = .automatic
        inputAtRoundStart = ""
        imageIDsAtRoundStart = []
        phase = .empty
        isInputOverLimit = false
        discardPendingImages()
        images = []
        imageNotice = nil
    }

    /// 作废还在处理的图片批次（新一轮 / 清空后，迟到的结果不再追加）。
    private func discardPendingImages() {
        imageBatchGeneration += 1
        pendingImageCount = 0
        translateWhenImagesReady = false
        imageBatchChain = nil
    }

    private func flashCopyConfirmation() {
        copyConfirmed = true
        copyConfirmTask?.cancel()
        copyConfirmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.copyConfirmed = false
        }
    }
}
