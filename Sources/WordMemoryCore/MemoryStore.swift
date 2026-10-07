import Foundation

@MainActor
public final class MemoryStore {
    public enum StoreError: LocalizedError {
        case unreadableExistingFile
        case staleRevision
        public var errorDescription: String? {
            switch self {
            case .unreadableExistingFile: "原有记忆文件无法读取；已停止写入，避免覆盖你的历史"
            case .staleRevision: "原联想已变化；已停止替换，避免覆盖其他修改"
            }
        }
    }

    private struct State: Codable {
        var cards: [String: MemoryCard] = [:]
        var branches: [String: BranchMemory] = [:]
        // Optional for memory.json files written before revision history existed.
        var revisions: [String: [MemoryCardRevision]]?
    }

    public let fileURL: URL
    public let loadWarning: String?
    private var state: State

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? base.appendingPathComponent("MaimemoCompanion", isDirectory: true).appendingPathComponent("memory.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            if let data = try? Data(contentsOf: self.fileURL),
               let saved = try? JSONDecoder().decode(State.self, from: data) {
                self.state = saved
                self.loadWarning = nil
            } else {
                self.state = State()
                self.loadWarning = StoreError.unreadableExistingFile.localizedDescription
            }
        } else {
            self.state = State()
            self.loadWarning = nil
        }
    }

    public func card(for word: String) -> MemoryCard? {
        state.cards[word.lowercased()]
    }

    public func branch(for word: String, partOfSpeech: String, meaningKey: String) -> BranchMemory? {
        state.branches[BranchMemory.key(word: word, partOfSpeech: partOfSpeech, meaningKey: meaningKey)]
    }

    public func revisions(for word: String) -> [MemoryCardRevision] {
        state.revisions?[word.lowercased()] ?? []
    }

    public func save(_ card: MemoryCard, replacing previousCard: MemoryCard? = nil, reason: String? = nil) throws {
        var next = state
        let wordKey = card.word.lowercased()
        if let previousCard {
            guard previousCard.word.lowercased() == wordKey, state.cards[wordKey] == previousCard else {
                throw StoreError.staleRevision
            }
            var revisions = next.revisions ?? [:]
            revisions[wordKey, default: []].append(MemoryCardRevision(previousCard: previousCard, reason: reason))
            next.revisions = revisions
        }
        next.cards[wordKey] = card
        for branch in card.branches {
            let key = BranchMemory.key(word: card.word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
            if next.branches[key] == nil {
                next.branches[key] = BranchMemory(word: card.word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
            }
        }
        try persist(next)
        state = next
    }

    public func recordEncounter(word: String) throws {
        let keys = state.branches.keys.filter { $0.hasPrefix(word.lowercased() + "|") }
        for key in keys {
            state.branches[key]?.encounterCount += 1
            state.branches[key]?.updatedAt = Date()
        }
        if !keys.isEmpty { try persist() }
    }

    public func recordFeedback(word: String, branch: MeaningBranch, result: RecallResult, condition: RecallCondition, reason: ForgetReason?, note: String) throws {
        let key = BranchMemory.key(word: word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
        var memory = state.branches[key] ?? BranchMemory(word: word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
        memory.lastResult = result
        memory.lastCondition = condition
        memory.forgetReason = reason
        memory.userNote = note
        memory.updatedAt = Date()
        state.branches[key] = memory
        try persist()
    }

    public func selectMethod(word: String, branch: MeaningBranch, method: MemoryMethod, reason: String?) throws {
        let key = BranchMemory.key(word: word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
        var memory = state.branches[key] ?? BranchMemory(word: word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
        if memory.methodVersions.last?.method != method {
            let version = MethodVersion(version: memory.methodVersions.count + 1, method: method, reasonForChange: reason)
            memory.methodVersions.append(version)
            memory.selectedMethodID = method.id
            memory.updatedAt = Date()
            state.branches[key] = memory
            try persist()
        }
    }

    private func persist(_ snapshot: State? = nil) throws {
        guard loadWarning == nil else { throw StoreError.unreadableExistingFile }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot ?? state)
        try data.write(to: fileURL, options: .atomic)
    }
}
