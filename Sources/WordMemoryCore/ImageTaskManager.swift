import Combine
import Foundation

public enum ImageTaskState: String, Codable, Sendable {
    case queued, submitting, generating, downloading, saving, completed, failed, cancelled
    public var label: String {
        switch self {
        case .queued: "排队中"
        case .submitting: "准备提交"
        case .generating: "等待生成响应"
        case .downloading: "下载中"
        case .saving: "保存中"
        case .completed: "已完成"
        case .failed: "未完成"
        case .cancelled: "已取消"
        }
    }
    public var isActive: Bool { [.queued, .submitting, .generating, .downloading, .saving].contains(self) }
}

public struct ImageTaskIdentity: Codable, Hashable, Sendable {
    public let word: String
    public let versionID: String
    public let promptHash: String
    public let provider: String
    public let model: String
    public let size: String
    public let resolution: String
    public init(word: String, versionID: String, prompt: String, provider: String = "MaiziAI-v2", model: String = "gpt-image-2.5", size: String = "1:1", resolution: String = "1K") {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.versionID = versionID; promptHash = MemoryIdentity.digest(prompt)
        self.provider = provider; self.model = model; self.size = size; self.resolution = resolution
    }
    public var cacheKey: String {
        [word, versionID, promptHash, provider, model, size, resolution].joined(separator: "\n")
    }
}
public struct ImageTaskFailure: Error, Codable, LocalizedError, Sendable {
    public let phase: String
    public let kind: String
    public let message: String
    public var errorDescription: String? { message }
    public init(phase: String, kind: String, message: String) { self.phase = phase; self.kind = kind; self.message = message }
}
public struct ImageTaskRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let identity: ImageTaskIdentity
    public let prompt: String
    public var state: ImageTaskState
    public let createdAt: Date
    public var updatedAt: Date
    public var localPath: String?
    public var resultURL: URL?
    public var stagedDataPath: String?
    public var serverTaskID: String?
    public var failure: ImageTaskFailure?
}

/// Separates a paid generation submission from safe retries of the same result.
public protocol StagedMemoryImageGenerator: MemoryImageGenerator {
    func submitImage(prompt: String) async throws -> MaiziImageResult
    func downloadImage(from url: URL) async throws -> Data
}

/// Owned by the application, independent of the revealed card and window visibility.
@MainActor
public final class ImageTaskManager: ObservableObject {
    @Published public private(set) var records: [ImageTaskRecord] = []
    @Published public private(set) var storageWarning: String?
    public let fileURL: URL
    private let imageStore: MemoryImageStore
    private var providers: [UUID: any MemoryImageGenerator] = [:]
    private var worker: Task<Void, Never>?
    private var runningID: UUID?

    public init(imageStore: MemoryImageStore = MemoryImageStore(), fileURL: URL? = nil) {
        self.imageStore = imageStore
        self.fileURL = fileURL ?? imageStore.directoryURL.deletingLastPathComponent().appendingPathComponent("image-tasks.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                records = try JSONDecoder().decode([ImageTaskRecord].self, from: Data(contentsOf: self.fileURL))
                var changed = false
                for index in records.indices where records[index].state.isActive {
                    changed = true; records[index].state = .failed; records[index].updatedAt = Date()
                    records[index].failure = ImageTaskFailure(phase: "interrupted", kind: "result_unknown",
                        message: records[index].resultURL == nil && records[index].stagedDataPath == nil
                        ? "上次任务中断／结果待确认；同步接口没有任务查询 ID，不会自动重新生成"
                        : "上次任务中断；可继续保存或下载原结果，不重新生成")
                }
                if changed { try persist() }
            } catch {
                storageWarning = "图片任务记录无法读取或更新；已停止新提交，保留原文件"
            }
        }
    }

    public func task(for identity: ImageTaskIdentity) -> ImageTaskRecord? { records.last { $0.identity == identity } }
    public func imageURL(for identity: ImageTaskIdentity, prompt: String) -> URL? {
        if let cached = imageStore.imageURL(cacheKey: identity.cacheKey) { return cached }
        // Old releases used this provider/model/size with only word + prompt as the cache key.
        if identity.provider == "MaiziAI-v2", identity.model == "gpt-image-2.5", identity.size == "1:1", identity.resolution == "1K" {
            return imageStore.imageURL(for: identity.word, prompt: prompt)
        }
        return nil
    }

    @discardableResult
    public func enqueue(identity: ImageTaskIdentity, prompt: String, generator: any MemoryImageGenerator, newGeneration: Bool = false) throws -> UUID {
        guard storageWarning == nil else { throw ImageTaskFailure(phase: "saving", kind: "storage", message: storageWarning!) }
        if let existing = task(for: identity), existing.state.isActive { return existing.id }
        if !newGeneration, let existing = task(for: identity) { return existing.id }
        let cached = newGeneration ? nil : imageURL(for: identity, prompt: prompt)
        let record = ImageTaskRecord(id: UUID(), identity: identity, prompt: prompt,
                                    state: cached == nil ? .queued : .completed, createdAt: Date(), updatedAt: Date(), localPath: cached?.path)
        records.append(record)
        do { try persist() } catch { records.removeLast(); throw error }
        if record.state == .queued { providers[record.id] = generator }
        startWorker()
        return record.id
    }

    public func canResume(_ record: ImageTaskRecord) -> Bool {
        record.state == .failed && (record.resultURL != nil || record.stagedDataPath != nil)
    }
    public func resumeResult(id: UUID, generator: any MemoryImageGenerator) throws {
        guard let index = records.firstIndex(where: { $0.id == id }), canResume(records[index]), storageWarning == nil else { return }
        let prior = records[index]; records[index].state = .queued; records[index].failure = nil
        records[index].updatedAt = Date()
        do { try persist() } catch { records[index] = prior; throw error }
        providers[id] = generator; startWorker()
    }

    public func cancel(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state.isActive else { return }
        let prior = records[index]
        records[index].state = .cancelled; records[index].updatedAt = Date()
        records[index].failure = ImageTaskFailure(phase: "cancelled", kind: "cancelled", message: prior.state == .queued
            ? "已取消排队，未提交生成" : "已停止本地等待；不能保证远端已取消或未计费")
        do { try persist() } catch { records[index] = prior; throw error }
        if runningID == id { worker?.cancel() }
        else { providers.removeValue(forKey: id) }
    }

    private func startWorker() {
        guard worker == nil, storageWarning == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while storageWarning == nil, let record = records.first(where: { $0.state == .queued && providers[$0.id] != nil }) {
                if Task.isCancelled { break }
                runningID = record.id
                await run(record)
                providers.removeValue(forKey: record.id)
            }
            runningID = nil; worker = nil
            if records.contains(where: { $0.state == .queued && providers[$0.id] != nil }) { startWorker() }
        }
    }

    private func update(_ id: UUID, _ edit: (inout ImageTaskRecord) -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        edit(&records[index]); records[index].updatedAt = Date()
        try persist()
    }

    private func run(_ original: ImageTaskRecord) async {
        guard let generator = providers[original.id] else { return }
        var phase = "submitting"
        do {
            var image: Data
            if let path = original.stagedDataPath {
                phase = "saving"; image = try Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                let result: MaiziImageResult
                if let url = original.resultURL { result = .url(url) }
                else {
                    try update(original.id) { $0.state = .submitting }
                    // A synchronous interface provides no measurable remote percentage.
                    phase = "generating"; try update(original.id) { $0.state = .generating }
                    if let staged = generator as? any StagedMemoryImageGenerator {
                        result = try await staged.submitImage(prompt: original.prompt)
                    } else { result = .imageData(try await generator.generateImage(prompt: original.prompt)) }
                }
                switch result {
                case .imageData(let data): image = data
                case .url(let url):
                    phase = "downloading"
                    try update(original.id) { $0.resultURL = url; $0.state = .downloading }
                    guard let staged = generator as? any StagedMemoryImageGenerator else {
                        throw ImageTaskFailure(phase: phase, kind: "unsupported", message: "服务不支持原结果下载")
                    }
                    // Two download attempts, both against the same returned URL; zero new submissions.
                    do { image = try await staged.downloadImage(from: url) }
                    catch {
                        try Task.checkCancellation()
                        image = try await staged.downloadImage(from: url)
                    }
                }
            }
            try Task.checkCancellation()
            phase = "saving"
            let staging = fileURL.deletingLastPathComponent().appendingPathComponent("image-task-results", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let dataURL = staging.appendingPathComponent(original.id.uuidString + ".data")
            guard image.count <= 20 * 1_024 * 1_024 else { throw MemoryImageStore.ImageError.imageTooLarge }
            try image.write(to: dataURL, options: .atomic)
            try update(original.id) { $0.state = .saving; $0.stagedDataPath = dataURL.path }
            let store = imageStore
            let url = try await Task.detached(priority: .utility) {
                try store.save(image, for: original.identity.word, prompt: original.prompt, cacheKey: original.identity.cacheKey)
            }.value
            // A completed save belongs to this immutable identity even when the page moved on.
            try update(original.id) { $0.localPath = url.path; $0.state = .completed; $0.failure = nil; $0.stagedDataPath = nil }
            try? FileManager.default.removeItem(at: dataURL)
        } catch {
            if records.first(where: { $0.id == original.id })?.state == .cancelled { return }
            let failure: ImageTaskFailure
            if let controlled = error as? ImageTaskFailure { failure = controlled }
            else if let providerError = error as? MaiziImageError { failure = providerError.taskFailure }
            else if let network = error as? URLError {
                failure = ImageTaskFailure(phase: phase, kind: network.code == .timedOut ? "timeout" : "network",
                    message: phase == "downloading" ? "原图片下载未完成，可继续下载；不会重新生成" : "等待响应中断／结果未知；没有任务查询 ID，不会自动重新生成")
            } else {
                failure = ImageTaskFailure(phase: phase, kind: phase == "saving" ? "local_save" : "response", message: phase == "saving" ? "本地图片验证或保存失败，可继续保存原结果" : "图片响应未完成；未自动重试生成")
            }
            do { try update(original.id) {
                $0.state = .failed; $0.failure = failure
                if case MaiziImageError.unsupportedAsync(let taskID) = error { $0.serverTaskID = taskID }
            } }
            catch { storageWarning = "图片任务状态无法保存；已停止新提交" }
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
