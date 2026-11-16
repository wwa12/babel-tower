import SwiftUI
import UniformTypeIdentifiers
import ImageIO

/// 浮窗正式内容：顶部把手栏、语言栏、输入区、结果区（或历史列表）、提示栏。
/// 高度随内容在 120–640 伸缩；字号输入与译文 14pt、提示栏 11pt。
struct PanelContentView: View {
    @ObservedObject var viewModel: PanelViewModel
    @EnvironmentObject private var appState: AppState

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            Divider()
            if viewModel.isShowingHistory, let history = viewModel.history {
                HistoryListView(store: history, viewModel: viewModel)
            } else {
                inputArea
                if showsResultArea {
                    Divider()
                    resultArea
                }
            }
            Divider()
            hintBar
        }
        .frame(width: BehaviorConstants.panelWidth)
        // 按理想高度定窗口高度（宿主视图用固有尺寸驱动面板伸缩）；
        // 各区域自带上限，总高不超过 640
        .fixedSize(horizontal: false, vertical: true)
        // 万一超出 640 也只从底部裁切，语言栏始终可见
        .frame(minHeight: BehaviorConstants.panelMinHeight,
               maxHeight: BehaviorConstants.panelMaxHeight, alignment: .top)
        .background(VisualEffectBackground())
        // 把手栏画在系统标题栏的位置（内容区上方、窗口白色底上）。
        // 用上移的叠加层而不是让内容忽略安全区：后者会让窗口高度把标题栏算两遍，底部多出空白
        .overlay(alignment: .top) {
            titleBar.offset(y: -Self.titleBarHeight)
        }
        .onChange(of: viewModel.isShowingHistory) { _, showing in
            // 历史列表关闭（返回 / 载入）后输入框重新出现：焦点放回输入区
            guard !showing else { return }
            DispatchQueue.main.async {
                appState.panelController.focusInputArea()
            }
        }
    }

    // MARK: 顶部把手栏（系统关闭按钮 + 居中的图标、名称、版本；底色为窗口白色，可拖动）

    /// 系统标题栏高度（随系统版本不同，按窗口样式实算）
    static let titleBarHeight: CGFloat = {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
    }()

    private var titleBar: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 16, height: 16)
            Text(AppText.panelTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        // 图标、名称、版本在把手栏居中（左侧是系统关闭按钮）
        .frame(height: Self.titleBarHeight)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)   // 点击与拖动交给窗口标题栏
    }

    // MARK: 语言栏（自动/简/繁/日/EN，译入语言高亮）

    private var languageBar: some View {
        HStack(spacing: 4) {
            languageButton(title: AppText.panelLanguageAutomatic, language: nil)
            languageButton(title: AppText.panelLanguageShort(.zhHans), language: .zhHans)
            languageButton(title: AppText.panelLanguageShort(.zhHant), language: .zhHant)
            languageButton(title: AppText.panelLanguageShort(.ja), language: .ja)
            languageButton(title: AppText.panelLanguageShort(.en), language: .en)
            Spacer(minLength: 8)
            if viewModel.history != nil {
                historyButton
            }
            pinButton
            Button {
                appState.panelController.showSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(AppText.settingsWindowTitle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 时钟：打开 / 关闭翻译历史（同 ⌘Y）。
    private var historyButton: some View {
        Button {
            viewModel.toggleHistory()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.isShowingHistory ? Color.accentColor : Color.secondary)
        .help(AppText.panelHistoryTooltip)
    }

    /// 图钉：固定浮窗——固定时点击外部/Esc 不收起、↩ 复制不收起。
    private var pinButton: some View {
        Button {
            viewModel.togglePinned()
        } label: {
            Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.isPinned ? Color.accentColor : Color.secondary)
        .help(viewModel.isPinned ? AppText.panelUnpinTooltip : AppText.panelPinTooltip)
    }

    private func languageButton(title: String, language: TranslationLanguage?) -> some View {
        let isSelected: Bool = {
            switch language {
            case nil: return viewModel.targetMode == .automatic && viewModel.highlightedLanguage == nil
            case .some(let lang): return viewModel.targetMode == .manual(lang) || viewModel.highlightedLanguage == lang
            }
        }()
        return Button(title) {
            viewModel.setTargetMode(language.map(TargetMode.manual) ?? .automatic)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    }

    // MARK: 输入区

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !viewModel.images.isEmpty || viewModel.pendingImageCount > 0 {
                thumbnailRow
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.inputText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    .frame(height: inputEditorHeight)
                    .padding(.horizontal, 8)
                if viewModel.inputText.isEmpty {
                    Text(AppText.panelInputPlaceholder)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            if let notice = viewModel.imageNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }
            if viewModel.isInputOverLimit {
                Text(AppText.panelCharCount(viewModel.inputText.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    /// 输入框高度随文字行数在 40 到上限之间伸缩（TextEditor 不报告内容高度，按文字排版估算）。
    /// 结果区显示时上限收到 120，保证各区相加不超过 640。
    private var inputEditorHeight: CGFloat {
        let text = viewModel.inputText.isEmpty ? " " : viewModel.inputText
        // 宽度扣掉两侧留白与 TextEditor 内边距（按偏窄估算，宁可多一行留白也不少一行）
        let width = BehaviorConstants.panelWidth - 16 - 30
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let maxHeight: CGFloat = showsResultArea ? 120 : 180
        return min(max(ceil(rect.height) + 12, 40), maxHeight)
    }

    /// 缩略图行：悬停出现删除按钮。
    private var thumbnailRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.images) { image in
                    ImageThumbnail(image: image) {
                        viewModel.removeImage(image.id)
                    }
                }
                // 后台处理中的图片：占位缩略图
                ForEach(0..<viewModel.pendingImageCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(ProgressView().controlSize(.small))
                        .accessibilityLabel(AppText.panelImageProcessing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap {
                        URL(dataRepresentation: $0, relativeTo: nil)
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        viewModel.handlePasteImageFile(url: url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(for: UTType.image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        viewModel.handlePasteImage(data: data)
                    }
                }
            }
        }
    }

    // MARK: 结果区

    private var showsResultArea: Bool {
        switch viewModel.phase {
        // 空 / 已输入未发送 → 结果区隐藏
        case .empty, .composing: return false
        default: return true
        }
    }

    /// 结果区：译文用只读 NSTextView 显示——可选中，⌘C 复制选区靠它成为第一响应者；
    /// 高度按译文排版自适应，超过上限在区内滚动。
    @ViewBuilder
    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner = viewModel.banner {
                bannerView(banner)
            }
            switch viewModel.phase {
            // 翻译中与完成共用同一个视图分支：译文视图不随完成被重建，
            // 用户流式期间的选区、滚动位置和焦点得以保留
            case .translating, .finished:
                if viewModel.showsEmptyResultHint {
                    // 空译文：给提示不留空白（精神），可 ⌘R 重试
                    Text(AppText.panelEmptyResultHint)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if viewModel.resultText.isEmpty {
                    if viewModel.phase == .translating {
                        BlinkingCursor()
                    }
                } else {
                    HStack(alignment: .top) {
                        ResultTextView(text: viewModel.resultText)
                        if viewModel.phase == .finished {
                            copyButton
                        }
                    }
                }
            case .failed(let failure):
                failureView(failure)
            case .empty, .composing:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bannerView(_ banner: PanelBanner) -> some View {
        let text: String = {
            switch banner {
            case .sameAsSource(let language):
                return AppText.panelSameAsSource(language.promptName)
            case .noTextInImage:
                return AppText.panelNoTextInImage
            }
        }()
        return Label(text, systemImage: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private var copyButton: some View {
        Button {
            viewModel.copyButtonTapped()
        } label: {
            Label(viewModel.copyConfirmed ? AppText.panelCopyDone : AppText.panelCopy,
                  systemImage: viewModel.copyConfirmed ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .disabled(viewModel.resultText.isEmpty)
    }

    private func failureView(_ failure: TranslationFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 流式中断：保留已收到的译文，下方提示"未完成"并附重试
            if case .streamInterrupted = failure, !viewModel.resultText.isEmpty {
                ResultTextView(text: viewModel.resultText)
            }
            Text(failure.userMessage)
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if failure.suggestsRetry {
                    Button(AppText.panelRetry) { viewModel.retranslate() }
                        .controlSize(.small)
                }
                if failure.suggestsSettings {
                    Button(AppText.panelGoSettings) {
                        appState.panelController.showSettingsWindow()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: 提示栏（11pt）

    private var hintBar: some View {
        Text(hintText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private var hintText: String {
        if viewModel.isShowingHistory {
            return AppText.panelHintHistory
        }
        return AppText.panelHint(for: viewModel.phase, isPinned: viewModel.isPinned)
    }
}

/// 翻译历史列表（浮窗内替换输入区与结果区）：时间倒序，↑↓ 选择、↩ 或单击载入。
private struct HistoryListView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var viewModel: PanelViewModel

    static let rowHeight: CGFloat = 58
    /// 列表高度上限：与把手栏、语言栏、提示栏相加不超过 640
    static let maxListHeight: CGFloat = 480

    var body: some View {
        if store.entries.isEmpty {
            Text(AppText.panelHistoryEmpty)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            HistoryRow(entry: entry,
                                       store: store,
                                       isSelected: entry.id == viewModel.historySelectionID)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                // 选中只跟键盘走：悬停改选中会在 ↑↓ 自动滚动时把选中项抢到鼠标下那行
                                .onTapGesture { viewModel.loadHistoryEntry(entry) }
                        }
                    }
                }
                // 固有高度驱动窗口：滚动视图没有理想高度，按条数给定
                .frame(height: min(CGFloat(store.entries.count) * Self.rowHeight, Self.maxListHeight))
                .onChange(of: viewModel.historySelectionID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
                .accessibilityLabel(AppText.panelHistoryAccessibilityLabel)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let store: HistoryStore
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let first = entry.images.first {
                HistoryThumbnail(url: store.imageURL(first))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.timeText(entry.date))
                    Text("→ " + AppText.panelLanguageShort(entry.targetLanguage))
                    if entry.images.count > 0 {
                        Text(AppText.panelHistoryImageCount(entry.images.count))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Text(Self.firstLine(entry.inputText).isEmpty ? AppText.panelHistoryImageOnly : Self.firstLine(entry.inputText))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(Self.firstLine(entry.resultText))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: HistoryListView.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    static func timeText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dateTimeFormatter.string(from: date)
    }
}

/// 历史条目的图片缩略图：后台按缩略尺寸解码（不解整张 2000px 原图）并缓存，滚动不卡、内存不涨。
private struct HistoryThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: url) {
            image = await HistoryThumbnailCache.thumbnail(for: url)
        }
    }
}

/// 历史缩略图缓存（只存 80px 小图，条数有上限）。
@MainActor
enum HistoryThumbnailCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 80,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// 图片缩略图：悬停时出现删除按钮。
private struct ImageThumbnail: View {
    let image: PanelImage
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// 译文显示（只读、可选中的 NSTextView）。
/// 不用 SwiftUI Text：可选中的 Text 在 AppKit 侧不是 NSTextView，面板按键路由判不出"焦点在结果区"，
/// ⌘C 只能复制全文。高度按排版结果自适应，超过上限在区内滚动。
struct ResultTextView: NSViewRepresentable {
    let text: String

    /// 结果区高度上限：与标题栏留白、语言栏、输入区（结果显示时 ≤120）、缩略图行、提示与横幅、
    /// 提示栏相加不超过 640
    static let maxHeight: CGFloat = 260
    static let font = NSFont.systemFont(ofSize: 14)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = Self.font
            textView.textColor = .labelColor
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.setAccessibilityLabel(AppText.panelResultAccessibilityLabel)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        if let storage = textView.textStorage, !textView.string.isEmpty, text.hasPrefix(textView.string) {
            // 流式增量只追加：不重置整段文本，用户已选中的部分不丢
            let addition = String(text.dropFirst(textView.string.count))
            storage.append(NSAttributedString(string: addition, attributes: attributes))
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView,
              let container = textView.textContainer else { return nil }
        var width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480
        // "始终显示滚动条"时滚动条占宽，排版宽度相应变窄
        if NSScroller.preferredScrollerStyle == .legacy {
            width -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        // 用独立排版测量，不改动显示中的文本容器
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: Self.font])
        let measureLayout = NSLayoutManager()
        let measureContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        measureContainer.lineFragmentPadding = container.lineFragmentPadding
        measureLayout.addTextContainer(measureContainer)
        storage.addLayoutManager(measureLayout)
        measureLayout.ensureLayout(for: measureContainer)
        let height = ceil(measureLayout.usedRect(for: measureContainer).height)
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480
        return CGSize(width: proposedWidth, height: min(max(height, 18), Self.maxHeight))
    }
}

/// 系统窗口材质背景（跟随系统深浅色、系统窗口材质）。
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 翻译中的闪动光标（首字到达前显示闪动的光标）。
private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Text("▍")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
