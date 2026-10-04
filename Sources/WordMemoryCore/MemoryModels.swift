import Foundation

public enum MemoryMethodKind: String, Codable, CaseIterable, Sendable {
    case context
    case image
    case contrast
    case morphology
    case sound
    case personal

    public var label: String {
        switch self {
        case .context: "情境"
        case .image: "画面"
        case .contrast: "对比"
        case .morphology: "词形／搭配"
        case .sound: "谐音"
        case .personal: "个人联想"
        }
    }
}

public struct MeaningBranch: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(partOfSpeech.lowercased())|\(meaningKey.lowercased())" }
    public let partOfSpeech: String
    public let meaningKey: String
    public let chineseMeaning: String
    public let context: String
    public let signal: String
    public let explanation: String

    public init(partOfSpeech: String, meaningKey: String, chineseMeaning: String, context: String, signal: String, explanation: String) {
        self.partOfSpeech = partOfSpeech
        self.meaningKey = meaningKey
        self.chineseMeaning = chineseMeaning
        self.context = context
        self.signal = signal
        self.explanation = explanation
    }
}

public struct MemoryMethod: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: MemoryMethodKind
    public let title: String
    public let cue: String
    public let whyItHelps: String
    public let isLanguageFact: Bool

    public init(id: String, kind: MemoryMethodKind, title: String, cue: String, whyItHelps: String, isLanguageFact: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cue = cue
        self.whyItHelps = whyItHelps
        self.isLanguageFact = isLanguageFact
    }
}

public struct TransferCheck: Codable, Hashable, Sendable {
    public let sentence: String
    public let targetBranch: String
    public let answer: String
    public let clue: String

    public init(sentence: String, targetBranch: String, answer: String, clue: String) {
        self.sentence = sentence
        self.targetBranch = targetBranch
        self.answer = answer
        self.clue = clue
    }
}

public struct MemoryCard: Codable, Hashable, Sendable {
    public let word: String
    public let coreConcept: String
    public let coreImage: String
    public let branches: [MeaningBranch]
    public let methods: [MemoryMethod]
    public let transferCheck: TransferCheck
    public let caveat: String?

    public init(word: String, coreConcept: String, coreImage: String, branches: [MeaningBranch], methods: [MemoryMethod], transferCheck: TransferCheck, caveat: String?) {
        self.word = word
        self.coreConcept = coreConcept
        self.coreImage = coreImage
        self.branches = branches
        self.methods = methods
        self.transferCheck = transferCheck
        self.caveat = caveat
    }
}

/// A provisional first clue. It is never persisted; only a fully validated card is saved.
public struct QuickMemoryHint: Equatable, Sendable {
    public let word: String
    public let coreConcept: String
    public let branch: MeaningBranch

    public init(word: String, coreConcept: String, branch: MeaningBranch) {
        self.word = word
        self.coreConcept = coreConcept
        self.branch = branch
    }
}

public enum RecallResult: String, Codable, CaseIterable, Sendable {
    case recognized
    case uncertain
    case forgotten

    public var label: String {
        switch self {
        case .recognized: "这次认出来了"
        case .uncertain: "有点模糊"
        case .forgotten: "又忘了"
        }
    }
}

public enum ForgetReason: String, Codable, CaseIterable, Sendable {
    case core
    case branch
    case context
    case confused
    case methodFailed

    public var label: String {
        switch self {
        case .core: "核心关系没想起"
        case .branch: "词性／义项没分清"
        case .context: "句中不会判断"
        case .confused: "与别的词混淆"
        case .methodFailed: "上次记法没帮上忙"
        }
    }
}

public enum RecallCondition: String, Codable, Sendable {
    case selfReport
    case newSentenceBeforeReveal
    case newSentenceAfterReveal

    public var label: String {
        switch self {
        case .selfReport: "用户自述，未做当前义项新句检查"
        case .newSentenceBeforeReveal: "新句未揭示答案时自述"
        case .newSentenceAfterReveal: "看过答案后自述"
        }
    }
}

public struct MethodVersion: Codable, Identifiable, Sendable {
    public let id: UUID
    public let version: Int
    public let method: MemoryMethod
    public let reasonForChange: String?
    public let createdAt: Date

    public init(id: UUID = UUID(), version: Int, method: MemoryMethod, reasonForChange: String?, createdAt: Date = Date()) {
        self.id = id
        self.version = version
        self.method = method
        self.reasonForChange = reasonForChange
        self.createdAt = createdAt
    }
}

public struct BranchMemory: Codable, Sendable {
    public let word: String
    public let partOfSpeech: String
    public let meaningKey: String
    public var encounterCount: Int
    public var lastResult: RecallResult?
    public var lastCondition: RecallCondition?
    public var forgetReason: ForgetReason?
    public var userNote: String
    public var methodVersions: [MethodVersion]
    public var selectedMethodID: String?
    public var updatedAt: Date

    public init(word: String, partOfSpeech: String, meaningKey: String) {
        self.word = word
        self.partOfSpeech = partOfSpeech
        self.meaningKey = meaningKey
        self.encounterCount = 0
        self.lastResult = nil
        self.lastCondition = nil
        self.forgetReason = nil
        self.userNote = ""
        self.methodVersions = []
        self.selectedMethodID = nil
        self.updatedAt = Date()
    }

    public var key: String { Self.key(word: word, partOfSpeech: partOfSpeech, meaningKey: meaningKey) }

    public static func key(word: String, partOfSpeech: String, meaningKey: String) -> String {
        "\(word.lowercased())|\(partOfSpeech.lowercased())|\(meaningKey.lowercased())"
    }
}
