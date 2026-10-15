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

public enum MemoryAnchorKind: String, Codable, CaseIterable, Sendable {
    case sound
    case letterIllustration
    case morphology, familiarChunks, hybrid, wordForm, context

    public var label: String {
        switch self {
        case .sound: "谐音联想"
        case .letterIllustration: "字母插画"
        case .morphology: "核心结构"
        case .familiarChunks: "熟词拆分"
        case .hybrid: "拆词＋谐音"
        case .wordForm: "词形变化"
        case .context: "场景联想"
        }
    }
}

/// One primary link from the English word to its reusable meaning.
public struct MemoryAnchor: Codable, Hashable, Sendable {
    public let kind: MemoryAnchorKind
    public let cue: String
    public let explanation: String
    public let imagePrompt: String?
    /// Local prepared-anchor metadata. The model sends these at card level only.
    public let wordLink: MemoryWordLink?
    public let illustration: MemoryIllustrationPlan?

    public init(kind: MemoryAnchorKind, cue: String, explanation: String, imagePrompt: String? = nil, wordLink: MemoryWordLink? = nil, illustration: MemoryIllustrationPlan? = nil) {
        self.kind = kind
        self.cue = cue
        self.explanation = explanation
        self.imagePrompt = imagePrompt
        self.wordLink = wordLink; self.illustration = illustration
    }
}

/// The recoverable path from an exact part of the English spelling to its meaning.
/// It describes a suggested memory aid; it does not certify an etymology or learning outcome.
public struct MemoryWordLink: Codable, Hashable, Sendable {
    public let source: String
    public let cue: String
    public let connection: String
    public let recall: String

    public init(source: String, cue: String, connection: String, recall: String) {
        self.source = source; self.cue = cue; self.connection = connection; self.recall = recall
    }
}

public struct MemoryVisualMapping: Codable, Hashable, Sendable {
    /// A literal, ordered substring of the word, not an invented root.
    public let source: String
    public let visual: String
    public let meaning: String

    public init(source: String, visual: String, meaning: String) {
        self.source = source; self.visual = visual; self.meaning = meaning
    }
}

/// One shared plan drives both the image request and its visible explanation.
public struct MemoryIllustrationPlan: Codable, Hashable, Sendable {
    public let scene: String
    public let mappings: [MemoryVisualMapping]
    public let explanation: String
    public let recall: String

    public init(scene: String, mappings: [MemoryVisualMapping], explanation: String, recall: String) {
        self.scene = scene; self.mappings = mappings; self.explanation = explanation; self.recall = recall
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
    /// Optional so memory.json files written by v1 remain readable.
    public let anchor: MemoryAnchor?
    /// The other user-requested approach, if it has already been prepared.
    public let alternateAnchor: MemoryAnchor?
    public let anchors: [MemoryAnchor]?
    public let analysis: WordAnalysis?
    public let wordLink: MemoryWordLink?
    public let illustration: MemoryIllustrationPlan?

    public init(word: String, coreConcept: String, coreImage: String, branches: [MeaningBranch], methods: [MemoryMethod], transferCheck: TransferCheck, caveat: String?, anchor: MemoryAnchor? = nil, alternateAnchor: MemoryAnchor? = nil, anchors: [MemoryAnchor]? = nil, analysis: WordAnalysis? = nil, wordLink: MemoryWordLink? = nil, illustration: MemoryIllustrationPlan? = nil) {
        self.word = word
        self.coreConcept = coreConcept
        self.coreImage = coreImage
        self.branches = branches
        self.methods = methods
        self.transferCheck = transferCheck
        self.caveat = caveat
        if let anchor, wordLink != nil || illustration != nil {
            self.anchor = MemoryAnchor(kind: anchor.kind, cue: anchor.cue, explanation: anchor.explanation,
                imagePrompt: anchor.imagePrompt, wordLink: wordLink, illustration: illustration)
        } else { self.anchor = anchor }
        self.alternateAnchor = alternateAnchor
        self.anchors = anchors
        self.analysis = analysis
        self.wordLink = wordLink; self.illustration = illustration
    }

    public func anchor(for kind: MemoryAnchorKind) -> MemoryAnchor? {
        if let anchor, anchor.kind == kind { return prepared(anchor) }
        if alternateAnchor?.kind == kind { return alternateAnchor }
        if let saved = anchors?.first(where: { $0.kind == kind }) { return saved }
        return nil
    }

    public func selectingAnchor(_ kind: MemoryAnchorKind) -> MemoryCard? {
        guard let selected = anchor(for: kind) else { return nil }
        let other = anchor?.kind == kind ? alternateAnchor : anchor.map(prepared)
        return replacingAnchors(selected: selected, alternate: other)
    }

    public func replacingAnchor(_ selected: MemoryAnchor) -> MemoryCard {
        let other = anchor?.kind == selected.kind ? alternateAnchor : anchor.map(prepared)
        return replacingAnchors(selected: selected, alternate: other)
    }

    public func withAlternateAnchor(_ alternate: MemoryAnchor?) -> MemoryCard {
        guard let anchor else { return self }
        return replacingAnchors(selected: prepared(anchor), alternate: alternate)
    }

    private func replacingAnchors(selected: MemoryAnchor, alternate: MemoryAnchor?) -> MemoryCard {
        MemoryCard(word: word, coreConcept: coreConcept, coreImage: coreImage,
                   branches: branches, methods: methods, transferCheck: transferCheck,
                   caveat: caveat, anchor: selected, alternateAnchor: alternate,
                   anchors: anchors, analysis: analysis, wordLink: selected.wordLink, illustration: selected.illustration)
    }

    private func prepared(_ value: MemoryAnchor) -> MemoryAnchor {
        guard value == anchor, wordLink != nil || illustration != nil else { return value }
        return MemoryAnchor(kind: value.kind, cue: value.cue, explanation: value.explanation,
            imagePrompt: value.imagePrompt, wordLink: wordLink, illustration: illustration)
    }

    public func preservingAnchors(from previous: MemoryCard) -> MemoryCard {
        var saved = previous.anchors ?? []
        for item in [previous.anchor.map(previous.prepared), previous.alternateAnchor].compactMap({ $0 }) {
            if !saved.contains(where: { $0.kind == item.kind }) { saved.append(item) }
        }
        saved.removeAll { $0.kind == anchor?.kind }
        return MemoryCard(word: word, coreConcept: coreConcept, coreImage: coreImage, branches: branches,
                          methods: methods, transferCheck: transferCheck, caveat: caveat, anchor: anchor,
                          alternateAnchor: anchor?.kind == .letterIllustration ? nil : previous.anchor(for: .letterIllustration), anchors: saved, analysis: analysis, wordLink: wordLink, illustration: illustration)
    }

    public var versionKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Selection of a prepared anchor doesn't change the text version's identity.
        let data = (try? encoder.encode(VersionContent(card: self))) ?? Data(word.utf8)
        return MemoryIdentity.digest(String(decoding: data, as: UTF8.self))
    }
    private struct VersionContent: Encodable {
        let card: MemoryCard
        func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(card.word.lowercased()); try values.encode(card.coreConcept)
            try values.encode(card.coreImage); try values.encode(card.branches); try values.encode(card.methods)
            try values.encode(card.transferCheck); try values.encode(card.analysis)
            var all = card.anchors ?? []
            for item in [card.anchor.map(card.prepared), card.alternateAnchor].compactMap({ $0 }) {
                if !all.contains(item) { all.append(item) }
            }
            try values.encode(all.sorted { $0.kind.rawValue < $1.kind.rawValue })
        }
    }

    public var illustrationPrompt: String {
        if let plan = illustration {
            let mappings = plan.mappings.map { mapping in
                "Exact letters \(mapping.source): visual treatment \(mapping.visual); semantic role \(mapping.meaning)."
            }.joined(separator: "\n")
            return """
            Create one clear visual mnemonic for the English word \(word).
            The exact, fully readable word "\(word)" must be the main visual subject. Keep every letter once, in its correct order; do not replace the word with an ordinary illustration, add letters, or omit letters. Transform selected letter shapes into meaningful objects while preserving legibility. This is a personal visual mnemonic, not an etymological claim.
            Shared core meaning: \(coreConcept).
            Scene: \(plan.scene)
            Required letter-to-image-to-meaning mappings:
            \(mappings)
            Intended explanation: \(plan.explanation)
            Recall path: \(plan.recall)
            Use one focused composition and at most three visual mappings. Let the letter shapes and their interaction carry the meaning, including abstract meaning. No unrelated objects, captions, Chinese labels, logos, or decorative lettering. The only text is the exact word "\(word)".
            """
        }
        if anchor?.kind == .letterIllustration, let prompt = anchor?.imagePrompt { return prompt }
        return "Create one clear, simple mnemonic illustration for the English word \(word). Meaning: \(coreConcept). Main cue: \(anchor?.cue ?? coreImage). Scene: \(coreImage). Depict only this useful relationship. Linguistic structure and personal mnemonic are distinct; do not invent etymology. No additional labels or text. If letters are shown, spell exactly \(word)."
    }
}

/// Archives the complete prior card and the optional reason when a user replaces an anchor.
public struct MemoryCardRevision: Codable, Sendable {
    public let previousCard: MemoryCard
    public let reason: String?
    public let createdAt: Date

    public init(previousCard: MemoryCard, reason: String?, createdAt: Date = Date()) {
        self.previousCard = previousCard
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reason = trimmed.isEmpty ? nil : trimmed
        self.createdAt = createdAt
    }
}

/// Ordered sound-card snapshots and the user's persisted local selection.
public struct SoundAnchorHistory: Codable, Sendable {
    public var cards: [MemoryCard]
    public var selectedIndex: Int

    public init(cards: [MemoryCard], selectedIndex: Int) {
        self.cards = cards
        self.selectedIndex = selectedIndex
    }

    public func canMove(by offset: Int) -> Bool {
        guard offset == -1 || offset == 1, cards.indices.contains(selectedIndex) else { return false }
        return cards.indices.contains(selectedIndex + offset)
    }

    public func moving(by offset: Int) -> SoundAnchorHistory? {
        guard canMove(by: offset) else { return nil }
        var history = self
        history.selectedIndex += offset
        return history
    }
}

/// A provisional first clue. It is never persisted; only a fully validated card is saved.
public struct QuickMemoryHint: Equatable, Sendable {
    public let word: String
    public let coreConcept: String
    public let anchor: MemoryAnchor
    public let branch: MeaningBranch?
    public let wordLink: MemoryWordLink?

    public init(word: String, coreConcept: String, anchor: MemoryAnchor, branch: MeaningBranch? = nil, wordLink: MemoryWordLink? = nil) {
        self.word = word
        self.coreConcept = coreConcept
        self.anchor = anchor
        self.branch = branch
        self.wordLink = wordLink
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
