import Foundation
import AppKit
import Combine
import CryptoKit

/// 一条翻译历史：成功完成的一轮翻译。
/// 每条单独存一个 JSON 文件，图片（发送给模型的压缩版）另存为文件。
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    struct Image: Codable, Equatable, Sendable {
        /// 图片文件名（与条目 JSON 同目录）
        let fileName: String
        let mimeType: String
    }

    let id: UUID
    let date: Date
    let inputText: String
    let images: [Image]
    let resultText: String
    /// 实际译入的语言（列表显示用）
    let targetLanguage: TranslationLanguage
    /// 手动指定的目标语言；nil = 自动
    let manualTarget: TranslationLanguage?
    /// 首行标记："same" / "passthrough" / 语言代码（载入时恢复横幅与高亮）
    let marker: String
    /// 内容指纹（文字 + 图片 + 目标设置）：同一内容再次翻译只保留最新一条
    let contentKey: String

    var targetMode: TargetMode { manualTarget.map(TargetMode.manual) ?? .automatic }

    var parsedMarker: MarkerParser.Marker {
        switch marker {
        case "same": .same
        case "passthrough": .passthrough
        default: TranslationLanguage(rawValue: marker).map(MarkerParser.Marker.language) ?? .passthrough
        }
    }

    static func markerString(_ marker: MarkerParser.Marker) -> String {
        switch marker {
        case .language(let language): language.rawValue
        case .same: "same"
        default: "passthrough"
        }
    }

    static func contentKey(text: String, images: [Data], manualTarget: TranslationLanguage?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(text.utf8))
        for image in images {
            hasher.update(data: Data([0x1F]))
            hasher.update(data: Data(SHA256.hash(data: image)))
        }
        hasher.update(data: Data(("|" + (manualTarget?.rawValue ?? "auto")).utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension TranslationLanguage: Codable {}

/// 一轮成功翻译交给历史保存的内容。
struct HistoryRecord: Sendable {
    let inputText: String
    let images: [ProcessedImage]
    let resultText: String
    let targetLanguage: TranslationLanguage
    let manualTarget: TranslationLanguage?
    let marker: MarkerParser.Marker
}

/// 翻译历史存储（只存本机，不发往任何地方）。
/// - 不限条数，按总占用（文字 + 图片）控制：超过上限从最旧整条删除，直到降到裁剪目标以下；
/// - 文件读写全部在后台串行队列执行，不拖慢呼出与翻译；界面读 `entries`（时间倒序）。
@MainActor
final class HistoryStore: ObservableObject {

    /// 总占用上限 500 MB。
    static let defaultLimitBytes: Int64 = 500 * 1024 * 1024
    /// 超限后裁剪到 400 MB 以下（一次腾出约 100 MB）。
    static let defaultPruneTargetBytes: Int64 = 400 * 1024 * 1024

    /// 时间倒序（最新在前）。
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var isLoaded = false

    let directory: URL
    private let disk: HistoryDisk
    private let queue = DispatchQueue(label: "babeltower.history", qos: .utility)
    private let now: () -> Date

    init(directory: URL = HistoryStore.defaultDirectory,
         limitBytes: Int64 = HistoryStore.defaultLimitBytes,
         pruneTargetBytes: Int64 = HistoryStore.defaultPruneTargetBytes,
         now: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        disk = HistoryDisk(directory: directory, limitBytes: limitBytes, pruneTargetBytes: pruneTargetBytes)
        load()
    }

    /// ~/Library/Application Support/<Bundle ID>/History
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BabelTower", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    private func load() {
        let disk = self.disk
        queue.async {
            let loaded = disk.loadAll()
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 加载期间新存的条目（尚未在磁盘列表里）保留
                let loadedIDs = Set(loaded.map(\.id))
                let merged = loaded + self.entries.filter { !loadedIDs.contains($0.id) }
                self.entries = merged.sorted { $0.date > $1.date }
                self.isLoaded = true
            }
        }
    }

    /// 保存一轮翻译。同一内容只保留最新一条；写入后按总占用裁剪最旧条目。
    func add(_ record: HistoryRecord) {
        let id = UUID()
        let imageNames = record.images.enumerated().map { index, image in
            HistoryEntry.Image(fileName: "\(id.uuidString)-\(index).\(Self.fileExtension(for: image.mimeType))",
                               mimeType: image.mimeType)
        }
        let entry = HistoryEntry(
            id: id,
            date: now(),
            inputText: record.inputText,
            images: imageNames,
            resultText: record.resultText,
            targetLanguage: record.targetLanguage,
            manualTarget: record.manualTarget,
            marker: HistoryEntry.markerString(record.marker),
            contentKey: HistoryEntry.contentKey(text: record.inputText,
                                                images: record.images.map(\.data),
                                                manualTarget: record.manualTarget)
        )
        let duplicates = entries.filter { $0.contentKey == entry.contentKey }
        entries.removeAll { $0.contentKey == entry.contentKey }
        entries.insert(entry, at: 0)

        let imageData = record.images.map(\.data)
        let disk = self.disk
        queue.async {
            for duplicate in duplicates {
                disk.remove(duplicate)
            }
            disk.write(entry, imageData: imageData)
            let pruned = disk.pruneIfNeeded()
            guard !pruned.isEmpty else { return }
            Task { @MainActor [weak self] in
                let prunedIDs = Set(pruned)
                self?.entries.removeAll { prunedIDs.contains($0.id) }
            }
        }
    }

    /// 清空全部历史（记录与图片文件）。
    func clearAll() {
        entries = []
        let disk = self.disk
        queue.async {
            disk.removeAll()
        }
    }

    /// 读取一条记录的图片（载入回浮窗用）。
    func loadImages(of entry: HistoryEntry) -> [ProcessedImage] {
        entry.images.compactMap { image in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(image.fileName)) else { return nil }
            return ProcessedImage(data: data, mimeType: image.mimeType)
        }
    }

    func imageURL(_ image: HistoryEntry.Image) -> URL {
        directory.appendingPathComponent(image.fileName)
    }

    /// 测试用：等后台队列上已提交的读写全部完成，并让主线程回调执行完。
    func waitForPendingWork() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        await Task.yield()
        await MainActor.run {}
    }

    /// 测试与诊断用：磁盘上的总占用。
    func diskUsageBytes() async -> Int64 {
        let disk = self.disk
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: disk.totalBytes) }
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        mimeType == "image/png" ? "png" : "jpg"
    }
}

/// 磁盘侧：只在 HistoryStore 的串行队列上使用。
private final class HistoryDisk: @unchecked Sendable {
    private let directory: URL
    private let limitBytes: Int64
    private let pruneTargetBytes: Int64
    private let fileManager = FileManager.default
    /// 条目 → 占用字节（JSON + 图片），裁剪按时间从旧到新
    private var index: [UUID: (date: Date, bytes: Int64, entry: HistoryEntry)] = [:]

    private(set) var totalBytes: Int64 = 0

    init(directory: URL, limitBytes: Int64, pruneTargetBytes: Int64) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.pruneTargetBytes = pruneTargetBytes
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func loadAll() -> [HistoryEntry] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var entries: [HistoryEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(HistoryEntry.self, from: data) else { continue }
            let bytes = Int64(data.count) + entry.images.reduce(0) { $0 + fileSize(of: $1.fileName) }
            index[entry.id] = (entry.date, bytes, entry)
            totalBytes += bytes
            entries.append(entry)
        }
        // 加载时也检查一次上限（例如上限调小后）
        let pruned = Set(pruneIfNeeded())
        return entries.filter { !pruned.contains($0.id) }
    }

    func write(_ entry: HistoryEntry, imageData: [Data]) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var bytes: Int64 = 0
            for (image, data) in zip(entry.images, imageData) {
                try data.write(to: directory.appendingPathComponent(image.fileName), options: .atomic)
                bytes += Int64(data.count)
            }
            let json = try encoder.encode(entry)
            try json.write(to: jsonURL(entry.id), options: .atomic)
            bytes += Int64(json.count)
            index[entry.id] = (entry.date, bytes, entry)
            totalBytes += bytes
        } catch {
            // 写失败（磁盘满等）：清掉半成品，不影响翻译本身
            deleteFiles(of: entry)
        }
    }

    func remove(_ entry: HistoryEntry) {
        if let existing = index.removeValue(forKey: entry.id) {
            totalBytes -= existing.bytes
        }
        deleteFiles(of: entry)
    }

    func removeAll() {
        index = [:]
        totalBytes = 0
        try? fileManager.removeItem(at: directory)
    }

    /// 超过上限：从最旧开始整条删除，直到降到裁剪目标以下。返回被删条目。
    func pruneIfNeeded() -> [UUID] {
        guard totalBytes > limitBytes else { return [] }
        var removed: [UUID] = []
        for (id, item) in index.sorted(by: { $0.value.date < $1.value.date }) {
            guard totalBytes > pruneTargetBytes else { break }
            remove(item.entry)
            removed.append(id)
        }
        return removed
    }

    private func jsonURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func deleteFiles(of entry: HistoryEntry) {
        try? fileManager.removeItem(at: jsonURL(entry.id))
        for image in entry.images {
            try? fileManager.removeItem(at: directory.appendingPathComponent(image.fileName))
        }
    }

    private func fileSize(of fileName: String) -> Int64 {
        let path = directory.appendingPathComponent(fileName).path
        return (try? fileManager.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }
}
