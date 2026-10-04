import Foundation

public enum MemoryHarnessError: LocalizedError {
    case invalidResponse(String)
    case notConfigured
    case unsafeEndpoint
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let reason): "模型结果不符合记忆卡结构：\(reason)"
        case .notConfigured: "请先配置模型地址、模型名称和 API Key"
        case .unsafeEndpoint: "模型地址需使用 HTTPS；本机 localhost 可以使用 HTTP"
        case .requestFailed(let status): "模型请求失败（HTTP \(status)）"
        }
    }
}

public struct MemoryRequest: Sendable {
    public let word: String
    public let learnerNote: String
    public let previousReason: ForgetReason?
    public let preferredMethod: MemoryMethodKind?
    public let previousMethod: String?
    public let existingCard: MemoryCard?
    public let focusMeaningKey: String?

    public init(word: String, learnerNote: String = "", previousReason: ForgetReason? = nil, preferredMethod: MemoryMethodKind? = nil, previousMethod: String? = nil, existingCard: MemoryCard? = nil, focusMeaningKey: String? = nil) {
        self.word = word
        self.learnerNote = learnerNote
        self.previousReason = previousReason
        self.preferredMethod = preferredMethod
        self.previousMethod = previousMethod
        self.existingCard = existingCard
        self.focusMeaningKey = focusMeaningKey
    }
}

public enum MemoryHarness {
    public static let systemInstructions = """
    你是面向中国考研英语二阅读的词汇记忆教练。目标是在新句中识别当句义项，不是背完词典。
    严格按以下顺序思考，但只输出 JSON：
    1. 找一个真实且可迁移的核心语义关系；如果不同义项确实不相连，明确在 caveat 说明，不编造统一故事。
    2. 只选当前常见、对阅读有用的 1 至 3 个词性／义项分支。每个分支给简短英文情境句、可观察的词性或搭配信号、中文当句意思，并说明如何从核心关系走到该意思。不要堆叠中文同义词。
    3. 给 2 至 5 个有差异的记忆方法，从情境、画面、对比、可靠词形／搭配、谐音、个人联想中择其适用者。先保证理解；谐音和拆字仅为个人辅助联想，不能冒充词源、构词事实或标准发音。若无法做出靠谱谐音，宁可不提供。
    4. 给一个自编、简短、纯英文的新句用于迁移检查。answer 和 clue 单独提供，界面会先隐藏它们。句子不能只是前面情境句换几个无关词。
    5. 只把用户明确提供的感受和困难当成用户事实；没有反馈时所有方法都只是待试用建议。不要声称用户已掌握或某方法有效。
    6. 不确定的词源或罕见义项宁可不写；若重要事实需要核查，在 caveat 标出待核验。
    输出字段按下面示例的顺序，不要在 JSON 前后添加说明；第一个 branches 对象优先写最有助于理解当前词的常见语境。
    返回一个 JSON object，字段精确为：
    {"word":"英文词","coreConcept":"中文核心关系","branches":[{"partOfSpeech":"词性","meaningKey":"简短稳定英文义项键","chineseMeaning":"当句中文意思","context":"自编英文短句","signal":"句中可观察信号","explanation":"核心关系如何在这里变义"}],"coreImage":"一句简短画面","methods":[{"id":"m1","kind":"context|image|contrast|morphology|sound|personal","title":"短标题","cue":"具体记忆钩子","whyItHelps":"为什么有助于回忆","isLanguageFact":false}],"transferCheck":{"sentence":"自编英文新句","targetBranch":"与某个 meaningKey 完全一致","answer":"当句意思","clue":"句中判断线索"},"caveat":null}
    """

    public static func userPrompt(_ request: MemoryRequest) -> String {
        let note = request.learnerNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousBranches = request.existingCard?.branches.map {
            "\($0.partOfSpeech):\($0.meaningKey)=\($0.chineseMeaning)"
        }.joined(separator: "; ") ?? "无"
        return """
        当前单词：\(request.word)
        用户原话／卡点：\(note.isEmpty ? "未提供" : note)
        上次遗忘原因：\(request.previousReason?.label ?? "未记录")
        想尝试的记法：\(request.preferredMethod?.label ?? "由你判断")
        旧记法（若无效请改对应部分）：\(request.previousMethod ?? "无")
        已有核心关系：\(request.existingCard?.coreConcept ?? "无")
        已有义项键：\(previousBranches)
        本次重点义项键：\(request.focusMeaningKey ?? "未指定")
        只处理这个词。若用户说名词会、动词忘，只优先重做动词分支；保留有效的核心关系。
        重做记法时必须保留本次重点义项的 meaningKey，未变化的义项也沿用原 meaningKey，避免丢失个人反馈历史。
        """
    }

    public static func parse(_ raw: String, expectedWord: String, requiredMeaningKey: String? = nil) throws -> MemoryCard {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8),
              let card = try? JSONDecoder().decode(MemoryCard.self, from: data) else {
            throw MemoryHarnessError.invalidResponse("无法解析 JSON")
        }
        guard card.word.caseInsensitiveCompare(expectedWord) == .orderedSame else {
            throw MemoryHarnessError.invalidResponse("单词与当前词不匹配")
        }
        guard !card.coreConcept.isEmpty, !card.branches.isEmpty, !card.methods.isEmpty else {
            throw MemoryHarnessError.invalidResponse("核心关系、语境或记法缺失")
        }
        let keys = Set(card.branches.map(\.meaningKey))
        guard keys.count == card.branches.count else {
            throw MemoryHarnessError.invalidResponse("义项键重复")
        }
        if let requiredMeaningKey, !keys.contains(requiredMeaningKey) {
            throw MemoryHarnessError.invalidResponse("本次重点义项键未保留")
        }
        guard keys.contains(card.transferCheck.targetBranch),
              !card.transferCheck.sentence.isEmpty,
              !card.transferCheck.answer.isEmpty else {
            throw MemoryHarnessError.invalidResponse("新句与义项无法对应")
        }
        let ids = card.methods.map(\.id)
        guard Set(ids).count == ids.count else {
            throw MemoryHarnessError.invalidResponse("记法 ID 重复")
        }
        guard card.methods.allSatisfy({ method in
            !(method.kind == .sound || method.kind == .personal || method.kind == .image) || !method.isLanguageFact
        }) else {
            throw MemoryHarnessError.invalidResponse("把个人联想误标为语言事实")
        }
        return card
    }

    /// Extracts only complete JSON values from a streaming prefix. A partial card is not trusted or saved.
    public static func quickHint(from prefix: String, expectedWord: String) -> QuickMemoryHint? {
        let bytes = Array(prefix.utf8)
        guard let wordStart = topLevelValueStart("word", in: bytes),
              let word = decodedString(at: wordStart, in: bytes),
              word.caseInsensitiveCompare(expectedWord) == .orderedSame,
              let conceptStart = topLevelValueStart("coreConcept", in: bytes),
              let concept = decodedString(at: conceptStart, in: bytes),
              !concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let branchesStart = topLevelValueStart("branches", in: bytes),
              branchesStart < bytes.count, bytes[branchesStart] == 91 else { return nil }

        var position = branchesStart + 1
        while position < bytes.count && isWhitespace(bytes[position]) { position += 1 }
        guard position < bytes.count, bytes[position] == 123,
              let end = completeObjectEnd(at: position, in: bytes),
              let branch = try? JSONDecoder().decode(MeaningBranch.self, from: Data(bytes[position...end])),
              !branch.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branch.chineseMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branch.meaningKey.isEmpty else { return nil }
        return QuickMemoryHint(word: word, coreConcept: concept, branch: branch)
    }

    private static func topLevelValueStart(_ name: String, in bytes: [UInt8]) -> Int? {
        var position = 0
        var depth = 0
        while position < bytes.count {
            switch bytes[position] {
            case 34:
                guard let end = completeStringEnd(at: position, in: bytes) else { return nil }
                if depth == 1,
                   let key = try? JSONDecoder().decode(String.self, from: Data(bytes[position...end])),
                   key == name {
                    var value = end + 1
                    while value < bytes.count && isWhitespace(bytes[value]) { value += 1 }
                    if value < bytes.count && bytes[value] == 58 {
                        value += 1
                        while value < bytes.count && isWhitespace(bytes[value]) { value += 1 }
                        return value < bytes.count ? value : nil
                    }
                }
                position = end + 1
                continue
            case 123, 91: depth += 1
            case 125, 93: depth -= 1
            default: break
            }
            position += 1
        }
        return nil
    }

    private static func decodedString(at start: Int, in bytes: [UInt8]) -> String? {
        guard start < bytes.count, bytes[start] == 34,
              let end = completeStringEnd(at: start, in: bytes) else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(bytes[start...end]))
    }

    private static func completeStringEnd(at start: Int, in bytes: [UInt8]) -> Int? {
        var position = start + 1
        var escaped = false
        while position < bytes.count {
            let byte = bytes[position]
            if escaped { escaped = false }
            else if byte == 92 { escaped = true }
            else if byte == 34 { return position }
            position += 1
        }
        return nil
    }

    private static func completeObjectEnd(at start: Int, in bytes: [UInt8]) -> Int? {
        var position = start
        var depth = 0
        while position < bytes.count {
            switch bytes[position] {
            case 34:
                guard let end = completeStringEnd(at: position, in: bytes) else { return nil }
                position = end + 1
                continue
            case 123: depth += 1
            case 125:
                depth -= 1
                if depth == 0 { return position }
            default: break
            }
            position += 1
        }
        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }
}
