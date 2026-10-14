import Foundation

/// Contains answer text and request context, never HTTP headers or API credentials.
public struct FailedMemoryResponse: Codable, Identifiable, Sendable {
    public var id: UUID { request.requestID }
    public let request: MemoryRequest
    public let content: String
    public let failureReason: String
    public let finishReason: String?
    public let model: String
    public let endpoint: String
    public let thinkingEnabled: Bool
    public let receivedAt: Date

    public init(request: MemoryRequest, content: String, failureReason: String, finishReason: String?, configuration: ModelConfiguration) {
        self.request = request; self.content = content; self.failureReason = failureReason; self.finishReason = finishReason
        model = configuration.model; thinkingEnabled = configuration.thinkingEnabled; receivedAt = Date()
        var url = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        url?.user = nil; url?.password = nil; url?.query = nil; url?.fragment = nil
        endpoint = url?.string ?? configuration.endpoint.host ?? ""
    }
    public var canReparse: Bool {
        !["length", "content_filter", "aborted", "insufficient_system_resource", "tool_calls"].contains(finishReason ?? "")
    }
    public func parseLocally() throws -> MemoryCard {
        guard canReparse else { throw MemoryHarnessError.invalidResponse("服务明确报告截断、拒绝或中断；不能作为完整卡片重新保存") }
        let card = try MemoryHarness.parse(content, expectedWord: request.word, requiredMeaningKey: request.focusMeaningKey, requiredAnchorKind: request.requiredAnchorKind)
        try MemoryResponseContract.validateStructure(content, for: request)
        try MemoryHarness.validate(card, for: request)
        return card
    }
}

@MainActor
public final class FailedMemoryResponseStore {
    private static let maximumBytes = 1_048_576
    private static let maximumEntries = 10
    public let fileURL: URL
    public private(set) var loadWarning: String?
    public private(set) var entries: [FailedMemoryResponse] = []

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base.appendingPathComponent("MaimemoCompanion").appendingPathComponent("failed-memory-responses.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do { entries = try JSONDecoder().decode([FailedMemoryResponse].self, from: Data(contentsOf: self.fileURL)) }
            catch { loadWarning = "暂存响应文件无法读取；保留原文件，停止覆盖" }
        }
    }
    public func latest(for word: String) -> FailedMemoryResponse? {
        entries.last { $0.request.word.caseInsensitiveCompare(word) == .orderedSame }
    }
    public func save(_ response: FailedMemoryResponse) throws {
        guard response.content.utf8.count <= Self.maximumBytes else { throw MemoryHarnessError.invalidResponse("响应超过本地暂存上限") }
        var next = entries.filter { $0.id != response.id }
        next.append(response)
        if next.count > Self.maximumEntries { next.removeFirst(next.count - Self.maximumEntries) }
        // Keep the received answer in RAM even when a disk write fails.
        entries = next; try persist(next)
    }
    public func remove(for word: String) throws {
        let next = entries.filter { $0.request.word.caseInsensitiveCompare(word) != .orderedSame }
        if next.count == entries.count { return }
        try persist(next); entries = next
    }
    private func persist(_ snapshot: [FailedMemoryResponse]) throws {
        guard loadWarning == nil else { throw MemoryHarnessError.invalidResponse(loadWarning!) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
