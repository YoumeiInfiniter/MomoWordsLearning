import CryptoKit
import Foundation

public enum MemoryStrategy: String, Codable, CaseIterable, Sendable {
    case auto, morphology, familiarChunks, hybrid, sound, wordForm, wordFamily, context
    public var anchorKind: MemoryAnchorKind? {
        switch self {
        case .auto: nil
        case .morphology, .wordFamily: .morphology
        case .familiarChunks: .familiarChunks
        case .hybrid: .hybrid
        case .sound: .sound
        case .wordForm: .wordForm
        case .context: .context
        }
    }
}

public enum MemoryPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case morphology, familiarChunks = "familiar_chunks", hybrid, naturalSound = "natural_sound"
    case wordForm = "word_form", wordFamily = "word_family", simplifyBase = "simplify_base"
    case focusBranch = "focus_branch", concreteScene = "concrete_scene"
    public var id: String { rawValue }
    public static let common: [Self] = [.morphology, .familiarChunks, .hybrid, .naturalSound]
    public var label: String {
        switch self {
        case .morphology: "词根词缀"
        case .familiarChunks: "熟词拆分"
        case .hybrid: "拆词＋谐音"
        case .naturalSound: "换自然谐音"
        case .wordForm: "识别词形"
        case .wordFamily: "核心＋词族"
        case .simplifyBase: "核心我不认识"
        case .focusBranch: "只补这个用法"
        case .concreteScene: "换真实场景"
        }
    }
    public var strategy: MemoryStrategy {
        switch self {
        case .morphology: .morphology
        case .familiarChunks: .familiarChunks
        case .hybrid: .hybrid
        case .naturalSound: .sound
        case .wordForm: .wordForm
        case .wordFamily: .wordFamily
        case .concreteScene: .context
        case .simplifyBase, .focusBranch: .auto
        }
    }
    public var query: String {
        switch self {
        case .morphology: "请优先检查真实词根、词基、前后缀；说明部件作用、整体实际意思与词性。只用可靠且容易理解的分析；不适合就明确说明，不编造词源。"
        case .familiarChunks: "按准确拼写拆成常见简单词和必要的剩余字母。剩余字母可以无含义；用短联想连到整体意思。切块标为个人助记，不冒充真实构词；不声称我已经认识。"
        case .hybrid: "先用可靠结构或简单熟词降低负担，仅对难记部分补局部谐音，连到实际核心意思。区分语言结构与个人助记，避免整词硬编长谐音。"
        case .naturalSound: "重新给自然、简短、连到核心意思的声音联想，与当前版本不同。不为押音编不通的句子；不适合就说明，不冒充标准发音。"
        case .wordForm: "判断屏幕词是否是复数、第三人称、时态、分词等形式。标明原形、变化和语境作用；有歧义就保留歧义，不是词形变化就如实说明。保留准确屏幕词形。"
        case .wordFamily: "解释最有用的核心结构与当前词的关系，再给最多三个常用相关词、词性与实际意思。区分屈折与派生，不推定整个词族掌握。"
        case .simplifyBase: "当前核心词或部件我也不认识。先用简单中文和短例子解释最关键的一个，必要时换熟悉联想，不继续堆陌生词根。"
        case .focusBranch: "保留仍有用的部分，只重做选中的词性和义项，严格保留 meaningKey 与词性，不重复讲解其他分支。"
        case .concreteScene: "换成容易想象且连到实际意思的简短生活或工作场景，减少硬拆字和硬谐音。未由用户提供的场景标为建议。"
        }
    }

    public func conflict(with supplement: String) -> String? {
        if [.naturalSound, .hybrid].contains(self), ["不要谐音", "别用谐音", "不用谐音", "不要声音联想"].contains(where: supplement.contains) {
            return "补充要求不使用谐音，与“\(label)”冲突；请改选其他按钮或调整补充"
        }
        if [.morphology, .familiarChunks, .wordForm, .wordFamily].contains(self), supplement.contains("只用谐音") {
            return "补充要求只用谐音，与“\(label)”冲突；请改选“换自然谐音”或调整补充"
        }
        return nil
    }
}

public enum RevisionReasonTag: String, Codable, CaseIterable, Sendable {
    case forced, complex, disconnected
    public var label: String {
        switch self { case .forced: "太牵强"; case .complex: "太复杂"; case .disconnected: "没连到意思" }
    }
}
public enum WordRelation: String, Codable, CaseIterable, Sendable {
    case inflection, derivation, compound, mnemonicSplit, none
    public var label: String {
        switch self {
        case .inflection: "词形变化"
        case .derivation: "派生构词"
        case .compound: "复合构词"
        case .mnemonicSplit: "个人拆分助记"
        case .none: "不拆词"
        }
    }
}
public enum WordPartKind: String, Codable, CaseIterable, Sendable {
    case root, base, stem, prefix, suffix, familiarWord, letters
}
public enum AnalysisEvidence: String, Codable, Sendable { case modelUnverified, mnemonic }
public struct WordPart: Codable, Hashable, Sendable {
    public let text: String
    /// Offsets count characters in the exact surface spelling, starting at zero.
    public let start: Int
    public let end: Int
    public let kind: WordPartKind
    public let meaning: String?
    public let relation: WordRelation
    public let evidence: AnalysisEvidence
}
public struct RelatedWord: Codable, Hashable, Sendable {
    public let word: String
    public let partOfSpeech: String
    public let meaning: String
    public let relation: WordRelation
    public let evidence: AnalysisEvidence
}
public struct WordAnalysis: Codable, Hashable, Sendable {
    public let surfaceWord: String
    public let lemma: String?
    public let relations: [WordRelation]
    public let core: String
    public let change: String?
    public let explanation: String
    public let parts: [WordPart]
    public let relatedWords: [RelatedWord]
    public let notSuitableReason: String?
    public let alternativeSuggestion: String?
}
public struct MemoryRedoRecord: Codable, Sendable {
    public let requestID: UUID
    public let presetID: MemoryPreset?
    public let reasonTags: [RevisionReasonTag]
    public let userSupplement: String
    public let baseVersionID: String?
    public let newVersionID: String
    public let focusBranchID: String?
    public let visibleContext: String?
    public let model: String
    public let endpoint: String
    public let thinkingEnabled: Bool
    public let previousUserNote: String?
    public let createdAt: Date

    public init(request: MemoryRequest, card: MemoryCard, model: String, endpoint: String, thinkingEnabled: Bool) {
        requestID = request.requestID; presetID = request.preset; reasonTags = request.reasonTags
        userSupplement = request.learnerNote; baseVersionID = request.existingCard?.versionKey
        newVersionID = card.versionKey; focusBranchID = request.focusBranchID
        visibleContext = request.visibleContext; self.model = model; self.endpoint = endpoint
        self.thinkingEnabled = thinkingEnabled; previousUserNote = request.previousUserNote; createdAt = Date()
    }
}

public enum MemoryIdentity {
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
