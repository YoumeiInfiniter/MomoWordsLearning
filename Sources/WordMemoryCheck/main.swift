import Foundation
import WordMemoryCore

@main
@MainActor
struct WordMemoryCheck {
    static func main() throws {
        try validateCard()
        try validateStreamingHint()
        try verifyHistory()
        try preventOverwriteOfUnreadableHistory()
        print("word-memory-check: 通过流式首条线索、结构校验、义项隔离与记法版本检查")
    }

    private static func validateStreamingHint() throws {
        let prefix = #"{"word":"state","coreConcept":"把\"内容\"明确呈现","branches":[{"partOfSpeech":"noun","meaningKey":"condition","chineseMeaning":"状态","context":"The machine is in a good state.","signal":"a ... state","explanation":"描述所处状态"}"#
        for index in prefix.indices {
            guard MemoryHarness.quickHint(from: String(prefix[..<index]), expectedWord: "state") == nil else {
                throw CheckError.failed("首个语境对象尚未完整时提前展示了线索")
            }
        }
        guard let hint = MemoryHarness.quickHint(from: prefix, expectedWord: "state"),
              hint.coreConcept == "把\"内容\"明确呈现",
              hint.branch.context == "The machine is in a good state.",
              hint.branch.chineseMeaning == "状态" else {
            throw CheckError.failed("完整首条线索未能提前提取")
        }
        guard MemoryHarness.quickHint(from: prefix, expectedWord: "claim") == nil else {
            throw CheckError.failed("其他单词的流式线索串到了当前词")
        }
        let complete = prefix + #"],"coreImage":"一幅画","methods":[{"id":"m1","kind":"context","title":"报告","cue":"state","whyItHelps":"搭配","isLanguageFact":true}],"transferCheck":{"sentence":"A sentence.","targetBranch":"condition","answer":"状态","clue":"a state"},"caveat":null}"#
        guard try MemoryHarness.parse(complete, expectedWord: "state").word == "state" else {
            throw CheckError.failed("流式拼接后的完整卡片未通过校验")
        }
    }

    private static func validateCard() throws {
        let card = sampleCard()
        let encoder = JSONEncoder()
        let json = String(decoding: try encoder.encode(card), as: UTF8.self)
        guard try MemoryHarness.parse(json, expectedWord: "state").word == "state" else {
            throw CheckError.failed("正确结果未通过解析")
        }
        do {
            _ = try MemoryHarness.parse(json, expectedWord: "claim")
            throw CheckError.failed("错误单词未被拒绝")
        } catch MemoryHarnessError.invalidResponse { }
        do {
            _ = try MemoryHarness.parse(json, expectedWord: "state", requiredMeaningKey: "another-branch")
            throw CheckError.failed("重点义项键丢失未被拒绝")
        } catch MemoryHarnessError.invalidResponse { }

        let misleading = MemoryCard(
            word: card.word,
            coreConcept: card.coreConcept,
            coreImage: card.coreImage,
            branches: card.branches,
            methods: [MemoryMethod(id: "m1", kind: .sound, title: "谐音", cue: "个人联想", whyItHelps: "提醒回忆", isLanguageFact: true)],
            transferCheck: card.transferCheck,
            caveat: nil
        )
        let badJSON = String(decoding: try encoder.encode(misleading), as: UTF8.self)
        do {
            _ = try MemoryHarness.parse(badJSON, expectedWord: "state")
            throw CheckError.failed("把谐音误标为事实未被拒绝")
        } catch MemoryHarnessError.invalidResponse { }
    }

    private static func verifyHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MaimemoMemoryCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.json")
        let store = MemoryStore(fileURL: file)
        let card = sampleCard()
        try store.save(card)
        let noun = card.branches[0]
        let verb = card.branches[1]
        try store.recordEncounter(word: "state")
        try store.recordFeedback(word: "state", branch: verb, result: .forgotten, condition: .newSentenceBeforeReveal, reason: .branch, note: "名词会，动词忘了")
        try store.selectMethod(word: "state", branch: verb, method: card.methods[0], reason: nil)
        let revised = MemoryMethod(id: "m1", kind: .image, title: "新画面", cue: "正式写明", whyItHelps: "更具体", isLanguageFact: false)
        try store.selectMethod(word: "state", branch: verb, method: revised, reason: "旧方法无效")

        let reloaded = MemoryStore(fileURL: file)
        let nounHistory = reloaded.branch(for: "state", partOfSpeech: noun.partOfSpeech, meaningKey: noun.meaningKey)
        let verbHistory = reloaded.branch(for: "state", partOfSpeech: verb.partOfSpeech, meaningKey: verb.meaningKey)
        guard nounHistory?.lastResult == nil,
              verbHistory?.lastResult == .forgotten,
              verbHistory?.lastCondition == .newSentenceBeforeReveal,
              verbHistory?.forgetReason == .branch,
              verbHistory?.encounterCount == 1,
              verbHistory?.methodVersions.map(\.version) == [1, 2],
              verbHistory?.methodVersions.last?.reasonForChange == "旧方法无效" else {
            throw CheckError.failed("义项历史或记法版本未正确保存")
        }
    }

    private static func preventOverwriteOfUnreadableHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MaimemoCorruptCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.json")
        let original = Data("not-json".utf8)
        try original.write(to: file)
        let store = MemoryStore(fileURL: file)
        guard store.loadWarning != nil else { throw CheckError.failed("损坏文件没有提示") }
        do {
            try store.save(sampleCard())
            throw CheckError.failed("损坏文件被覆盖")
        } catch MemoryStore.StoreError.unreadableExistingFile { }
        guard try Data(contentsOf: file) == original else { throw CheckError.failed("原文件内容发生变化") }
    }

    private static func sampleCard() -> MemoryCard {
        MemoryCard(
            word: "state",
            coreConcept: "把内容明确呈现出来",
            coreImage: "把事实放到台面上",
            branches: [
                MeaningBranch(partOfSpeech: "noun", meaningKey: "condition", chineseMeaning: "状态", context: "The machine is in a good state.", signal: "a ... state", explanation: "描述所处状态"),
                MeaningBranch(partOfSpeech: "verb", meaningKey: "say-clearly", chineseMeaning: "明确说明", context: "The report states the reason.", signal: "states + the reason", explanation: "把理由明确呈现")
            ],
            methods: [MemoryMethod(id: "m1", kind: .context, title: "报告写明", cue: "report states the reason", whyItHelps: "用搭配判断", isLanguageFact: true)],
            transferCheck: TransferCheck(sentence: "The rule states that entry is free.", targetBranch: "say-clearly", answer: "规则写明", clue: "states that"),
            caveat: nil
        )
    }
}

private enum CheckError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
