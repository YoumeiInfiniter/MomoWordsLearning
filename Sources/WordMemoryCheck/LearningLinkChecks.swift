import Foundation
import WordMemoryCore

/// Offline contract checks: observable spelling, explanation and cache boundaries,
/// not a claim that a mnemonic has been learned or that a model will always follow it.
enum LearningLinkChecks {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func raw(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
    static func fixture() -> [String: Any] {
        ["word": "measure", "coreConcept": "用标准确定多少或价值", "coreImage": "折叠尺量出具体长度与抽象价值的建议画面",
         "anchor": ["kind": "context", "cue": "measure the value：把 measure 放在价值前看它的动作", "explanation": "在 measure the value 中，measure 作用于价值，从用标准量长度延伸到衡量价值。", "imagePrompt": NSNull()],
         "wordLink": ["source": "measure", "cue": "measure the value：measure 对 value 做确定多少或价值的动作", "connection": "measure 在这个英文搭配中作用于 value；把确定长度的动作迁移到价值，就连到衡量。", "recall": "看到 measure → 想起 measure the value 的动作 → 用标准确定多少或价值。"],
         "illustration": ["scene": "保留准确的 measure 全词，以 m 的折线变成展开的折叠尺，横跨实体长度与价值刻度。", "mappings": [["source": "m", "visual": "m 的两道折线成为可辨认字母形状的折叠尺，向两端展开丈量", "meaning": "从具体测量延伸到衡量抽象价值"]], "explanation": "m 的字母折线承担折叠尺的丈量动作，从实体长度跨到价值刻度；这是视觉助记，不是词源。", "recall": "看到 measure → m 形折叠尺展开 → 想起测量与衡量共同的用标准确定。"],
         "branches": [["partOfSpeech": "verb", "meaningKey": "evaluate", "chineseMeaning": "衡量", "context": "It is hard to measure the value of friendship.", "signal": "measure 的宾语是 the value", "explanation": "用标准确定抽象价值。"]],
         "methods": [["id": "m1", "kind": "context", "title": "搭配动作", "cue": "measure the value", "whyItHelps": "让英文动作连接到衡量价值", "isLanguageFact": false]],
         "transferCheck": ["sentence": "We cannot measure success by money alone.", "targetBranch": "evaluate", "answer": "不能只用金钱衡量成功。", "clue": "measure 的宾语 success 是抽象名词"], "caveat": NSNull(),
         "analysis": ["surfaceWord": "measure", "lemma": NSNull(), "relations": ["none"], "core": "整词与实际搭配", "change": NSNull(), "explanation": "不强拆构词，用真实英文搭配作为入口。", "parts": [], "relatedWords": [], "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]]
    }
    static func parse(_ object: [String: Any], request: MemoryRequest) throws -> MemoryCard {
        let content = try raw(object)
        let card = try MemoryHarness.parse(content, expectedWord: request.word, requiredAnchorKind: request.requiredAnchorKind)
        try MemoryResponseContract.validateStructure(content, for: request)
        try MemoryHarness.validate(card, for: request)
        return card
    }
    static func reject(_ object: [String: Any], request: MemoryRequest) throws {
        do { _ = try parse(object, request: request); throw Failure(message: "缺失或错误的学习联系被接受") }
        catch MemoryHarnessError.invalidResponse { }
    }
    static func run() throws {
        let strict = MemoryRequest(word: "measure", strategy: .auto, requiresLearningLink: true)
        let card = try parse(fixture(), request: strict)
        try require(card.wordLink?.source == "measure" && card.illustration?.mappings.first?.source == "m", "新的记忆联系没有解码")
        try require(card.anchor?.wordLink == card.wordLink && card.anchor?.illustration == card.illustration, "新联系没有绑定到当前记法")
        let schema = MemoryResponseContract.schema(for: strict)
        let required = schema["required"] as! [String]
        try require(required.contains("wordLink") && required.contains("illustration"), "新请求未强制新契约")
        try require(MemoryResponseContract.instructions(for: strict).contains("measure 仅写") && MemoryHarness.systemInstructions.contains("原词中可识别的线索"), "请求未明确拒绝纯中文释义")
        for field in ["wordLink", "illustration"] {
            var invalid = fixture(); invalid.removeValue(forKey: field); try reject(invalid, request: strict)
        }
        for replacement in [
            ["source": "尺子", "cue": "拿尺子量东西", "connection": "量出的是衡量标准", "recall": "想起衡量"],
            ["source": "unrelated", "cue": "unrelated 是线索", "connection": "unrelated 指衡量", "recall": "看到 measure 想起衡量"],
            ["source": "measure", "cue": "measure=衡量", "connection": "measure 就是衡量。", "recall": "看到 measure → 想起衡量。"],
            ["source": "measure", "cue": "用标准确定多少或价值", "connection": "measure 指衡量", "recall": "看到 measure 想起衡量"],
            ["source": "measure", "cue": "measure the value", "connection": "量出结果就是一种衡量标准", "recall": "看到 measure 想起衡量"],
            ["source": "measure", "cue": "measure the value", "connection": "measure 对 value 做动作，延伸到衡量", "recall": "从尺子想到衡量"],
            ["source": "measure", "cue": "measure the value", "connection": "measure the value", "recall": "看到 measure 想起衡量"]
        ] {
            var invalid = fixture(); invalid["wordLink"] = replacement; try reject(invalid, request: strict)
        }
        for badMappings: [[String: String]] in [[], [["source": "ruler", "visual": "折叠尺", "meaning": "衡量"]], [["source": "m", "visual": "", "meaning": "衡量"]]] {
            var invalid = fixture(); var plan = invalid["illustration"] as! [String: Any]
            plan["mappings"] = badMappings; invalid["illustration"] = plan; try reject(invalid, request: strict)
        }
        for (field, value) in [("scene", "普通尺子丈量物品，没有原词"), ("explanation", "画面描绘了衡量，但未解释字母"), ("recall", "看到尺子想到衡量")] {
            var invalid = fixture(); var plan = invalid["illustration"] as! [String: Any]
            plan[field] = value; invalid["illustration"] = plan; try reject(invalid, request: strict)
        }
        let content = try raw(fixture())
        let repaired = try MemoryHarness.parse(String(content.dropLast()), expectedWord: strict.word)
        try require(repaired == card, "新字段导致完整响应仅缺尾括号时不能本地恢复")
        var missingContent = fixture(); var plan = missingContent["illustration"] as! [String: Any]
        plan.removeValue(forKey: "explanation"); missingContent["illustration"] = plan
        try reject(missingContent, request: strict)
        let renewed = strict.renewed()
        try require(renewed.requiresLearningLink == true && renewed.requestID != strict.requestID, "续请求丢失新契约或复用请求ID")
        let restored = try JSONDecoder().decode(MemoryRequest.self, from: JSONEncoder().encode(strict))
        try require(restored.requiresLearningLink == true, "请求存档丢失新契约")
        var legacyObject = fixture(); legacyObject.removeValue(forKey: "wordLink"); legacyObject.removeValue(forKey: "illustration")
        let legacyRequest = MemoryRequest(word: "measure", strategy: .auto)
        let legacy = try parse(legacyObject, request: legacyRequest)
        try require(legacy.wordLink == nil && legacy.illustration == nil, "旧卡被伪造学习内容")
        try MemoryHarness.validate(card, for: legacyRequest)
        try MemoryResponseContract.validateStructure(content, for: legacyRequest)
        var oneNewField = legacyObject; oneNewField["wordLink"] = fixture()["wordLink"]
        try reject(oneNewField, request: legacyRequest)
        var archivedRequest = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyRequest)) as! [String: Any]
        archivedRequest.removeValue(forKey: "requiresLearningLink")
        let decodedOldRequest = try JSONDecoder().decode(MemoryRequest.self, from: JSONSerialization.data(withJSONObject: archivedRequest))
        try require(decodedOldRequest.requiresLearningLink == nil && decodedOldRequest.renewed().requiresLearningLink == nil, "旧请求被隐式升级")
        try require(decodedOldRequest.renewed(requiresLearningLink: true).requiresLearningLink == true, "显式付费重试不能升级契约")
        try streamHints(card: card)
        try anchorsAndIdentity(card: card, legacy: legacy)
        print("Learning links: 原词入口、中文连接、图片映射、拒绝边界、尾括号恢复、旧存档、记法元数据与图片身份检查通过")
    }
    static func streamHints(card: MemoryCard) throws {
        let fields = fixture()
        func fragment(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
        }
        let prefix = "{\"word\":\"measure\",\"coreConcept\":" + (try fragment(fields["coreConcept"]!))
            + ",\"anchor\":" + (try fragment(fields["anchor"]!))
        try require(MemoryHarness.quickHint(from: prefix, expectedWord: "measure", requiresLearningLink: true) == nil, "新请求在原词联系到达前就显示纯中文临时线索")
        let legacy = MemoryHarness.quickHint(from: prefix, expectedWord: "measure")
        try require(legacy?.anchor.kind == .context && legacy?.wordLink == nil, "旧请求首条线索失去兼容")
        let linkJSON = try fragment(fields["wordLink"]!)
        let partial = prefix + ",\"wordLink\":" + String(linkJSON.dropLast(4))
        try require(MemoryHarness.quickHint(from: partial, expectedWord: "measure", requiresLearningLink: true) == nil, "半截wordLink被当作完整临时线索")
        var invalidLink = fields["wordLink"] as! [String: String]
        invalidLink["source"] = "ruler"
        let wrong = prefix + ",\"wordLink\":" + (try fragment(invalidLink))
        try require(MemoryHarness.quickHint(from: wrong, expectedWord: "measure", requiresLearningLink: true) == nil, "错误原词source抢先显示")
        invalidLink = fields["wordLink"] as! [String: String]
        invalidLink["connection"] = "拿尺子量出结果就是一种衡量标准"
        let chineseOnly = prefix + ",\"wordLink\":" + (try fragment(invalidLink))
        try require(MemoryHarness.quickHint(from: chineseOnly, expectedWord: "measure", requiresLearningLink: true) == nil, "临时线索绕过完整卡相同的wordLink校验")
        let ready = prefix + ",\"wordLink\":" + linkJSON + ",\"illustration\":{\"scene\":\""
        let hint = MemoryHarness.quickHint(from: ready, expectedWord: "measure", requiresLearningLink: true)
        try require(hint?.wordLink == card.wordLink && hint?.branch == nil, "已完整的原词链不能在图片计划/完整卡尚未返回时显示")
        try require(MemoryHarness.quickHint(from: ready, expectedWord: "temporary", requiresLearningLink: true) == nil, "临时线索串入其他单词")
    }
    static func anchorsAndIdentity(card: MemoryCard, legacy: MemoryCard) throws {
        let link = MemoryWordLink(source: "measure", cue: "measure 的声音助记（建议）", connection: "把 measure 的声音联想到丈量动作，仅作个人助记。", recall: "看到 measure → 想起建议声音 → 回到衡量。")
        let plan = MemoryIllustrationPlan(scene: "measure 字母作为天平两臂的另一建议画面", mappings: [.init(source: "m", visual: "m 的拱线支起天平", meaning: "衡量")], explanation: "m 的拱线承担衡量动作，仅作助记。", recall: "看到 measure → 天平 → 衡量。")
        let alternate = MemoryAnchor(kind: .sound, cue: "声音建议", explanation: "另一条个人联想", wordLink: link, illustration: plan)
        let prepared = card.withAlternateAnchor(alternate)
        let selected = prepared.selectingAnchor(.sound)!
        try require(selected.wordLink == link && selected.illustration == plan, "选择旧记法套用了当前记法的学习联系")
        try require(selected.versionKey == prepared.versionKey, "切换已备记法改变了文本版本身份")
        try require(selected.illustrationPrompt != prepared.illustrationPrompt && selected.illustrationPrompt.contains(plan.scene), "图提示没有跟随所选计划")
        let back = selected.selectingAnchor(.context)!
        try require(back.wordLink == card.wordLink && back.illustration == card.illustration && back.versionKey == prepared.versionKey, "切回当前记法丢失其学习联系或改变版本")
        let restored = try JSONDecoder().decode(MemoryCard.self, from: JSONEncoder().encode(selected))
        try require(restored.selectingAnchor(.context)?.wordLink == card.wordLink && restored.versionKey == prepared.versionKey, "存档后不能恢复对应记法联系")
        let oldAlternate = MemoryAnchor(kind: .sound, cue: "旧声音建议", explanation: "旧版没有独立学习联系")
        let mixed = card.withAlternateAnchor(oldAlternate)
        let oldSelected = mixed.selectingAnchor(.sound)!
        try require(oldSelected.wordLink == nil && oldSelected.illustration == nil && oldSelected.versionKey == mixed.versionKey, "旧记法误用新联系或改变版本")
        let oldRoundTrip = try JSONDecoder().decode(MemoryCard.self, from: JSONEncoder().encode(legacy))
        try require(oldRoundTrip.versionKey == legacy.versionKey && oldRoundTrip.illustrationPrompt == legacy.illustrationPrompt, "读写旧卡改变缓存身份")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let historicalData = try encoder.encode(LegacyVersion(card: legacy))
        try require(legacy.versionKey == MemoryIdentity.digest(String(decoding: historicalData, as: UTF8.self)), "新增nil字段改变旧版versionKey算法")
        let oldPrompt = "Create one clear, simple mnemonic illustration for the English word \(legacy.word). Meaning: \(legacy.coreConcept). Main cue: \(legacy.anchor?.cue ?? legacy.coreImage). Scene: \(legacy.coreImage). Depict only this useful relationship. Linguistic structure and personal mnemonic are distinct; do not invent etymology. No additional labels or text. If letters are shown, spell exactly \(legacy.word)."
        try require(legacy.illustrationPrompt == oldPrompt, "旧版图提示被改写，旧图缓存会失配")
        try require(card.versionKey != legacy.versionKey && card.illustrationPrompt.contains("exact, fully readable word \"measure\"") && card.illustrationPrompt.contains(card.illustration!.mappings[0].visual), "新图仍是普通配图或缺少具体映射")
    }
    /// Frozen v0.4.2 identity shape. It intentionally has no learning-link properties.
    struct LegacyAnchor: Encodable {
        let kind: MemoryAnchorKind
        let cue: String
        let explanation: String
        let imagePrompt: String?
        init(_ anchor: MemoryAnchor) {
            kind = anchor.kind; cue = anchor.cue; explanation = anchor.explanation; imagePrompt = anchor.imagePrompt
        }
    }
    struct LegacyVersion: Encodable {
        let card: MemoryCard
        func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(card.word.lowercased()); try values.encode(card.coreConcept)
            try values.encode(card.coreImage); try values.encode(card.branches); try values.encode(card.methods)
            try values.encode(card.transferCheck); try values.encode(card.analysis)
            var all = card.anchors ?? []
            for item in [card.anchor, card.alternateAnchor].compactMap({ $0 }) {
                if !all.contains(item) { all.append(item) }
            }
            try values.encode(all.sorted { $0.kind.rawValue < $1.kind.rawValue }.map(LegacyAnchor.init))
        }
    }
}
