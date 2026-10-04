import AppKit
import Foundation
import WordMemoryCore

@main
@MainActor
struct WordMemoryCheck {
    static func main() throws {
        try validateCard()
        try validateLegacyCardDecoding()
        try validateStreamingHint()
        try validateSSEFraming()
        try verifyHistory()
        try preventOverwriteOfUnreadableHistory()
        try verifyImageStorage()
        print("word-memory-check: 通过 SSE 分帧、主联想、旧卡兼容、图片存储与历史检查")
    }

    private static func validateSSEFraming() throws {
        let chunks = [
            #"{"choices":[{"delta":{"content":"{"}}]}"#,
            #"{"choices":[{"delta":{"content":"\"word\":\"state\"}"}}]}"#
        ]
        let wire = ": keep-alive\r\n\r\ndata: \(chunks[0])\r\n\r\nevent: message\ndata: \(chunks[1])\n\ndata: [DONE]\r\n\r\n"
        var decoder = ServerSentEventDecoder()
        var events: [ServerSentEvent] = []
        for byte in wire.utf8 {
            if let event = decoder.append(byte) { events.append(event) }
        }
        if let event = decoder.finish() { events.append(event) }
        guard events.map(\.data) == chunks + ["[DONE]"],
              events.map(\.name) == [nil, "message", nil] else {
            throw CheckError.failed("SSE 的 CRLF/LF 空行、保活注释或 DONE 分帧不正确")
        }
        var splitDecoder = ServerSentEventDecoder()
        let multiline = "data: first\r\ndata: second\r\n\r\n"
        var result: ServerSentEvent?
        for byte in multiline.utf8 {
            if let event = splitDecoder.append(byte) { result = event }
        }
        guard result?.data == "first\nsecond" else {
            throw CheckError.failed("同一 SSE 事件的多行 data 未正确合并")
        }
    }

    private static func validateStreamingHint() throws {
        let prefix = #"{"word":"state","coreConcept":"把\"内容\"明确呈现","anchor":{"kind":"sound","cue":"说清楚","explanation":"把声音联想到明确表达","imagePrompt":null}"#
        for index in prefix.indices {
            guard MemoryHarness.quickHint(from: String(prefix[..<index]), expectedWord: "state") == nil else {
                throw CheckError.failed("主联想尚未完整时提前展示了线索")
            }
        }
        guard let hint = MemoryHarness.quickHint(from: prefix, expectedWord: "state"),
              hint.coreConcept == "把\"内容\"明确呈现",
              hint.anchor.kind == .sound,
              hint.branch == nil else {
            throw CheckError.failed("完整主联想未能提前提取")
        }
        guard MemoryHarness.quickHint(from: prefix, expectedWord: "claim") == nil else {
            throw CheckError.failed("其他单词的流式线索串到了当前词")
        }
        let complete = prefix + #", "branches":[{"partOfSpeech":"noun","meaningKey":"condition","chineseMeaning":"状态","context":"The machine is in a good state.","signal":"a ... state","explanation":"描述所处状态"}],"coreImage":"一幅画","methods":[{"id":"m1","kind":"context","title":"报告","cue":"state","whyItHelps":"搭配","isLanguageFact":true}],"transferCheck":{"sentence":"A sentence.","targetBranch":"condition","answer":"状态","clue":"a state"},"caveat":null}"#
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
            caveat: nil,
            anchor: card.anchor
        )
        let badJSON = String(decoding: try encoder.encode(misleading), as: UTF8.self)
        do {
            _ = try MemoryHarness.parse(badJSON, expectedWord: "state")
            throw CheckError.failed("把谐音误标为事实未被拒绝")
        } catch MemoryHarnessError.invalidResponse { }

        let invalidIllustration = MemoryCard(
            word: card.word, coreConcept: card.coreConcept, coreImage: card.coreImage,
            branches: card.branches, methods: card.methods, transferCheck: card.transferCheck,
            caveat: nil,
            anchor: MemoryAnchor(kind: .letterIllustration, cue: "字母画", explanation: "字母变成画面", imagePrompt: "Draw the word statement as a scene")
        )
        do {
            _ = try MemoryHarness.parse(String(decoding: try encoder.encode(invalidIllustration), as: UTF8.self), expectedWord: "state")
            throw CheckError.failed("插画提示词漏掉准确单词未被拒绝")
        } catch MemoryHarnessError.invalidResponse { }

        let validIllustration = MemoryCard(
            word: card.word, coreConcept: card.coreConcept, coreImage: card.coreImage,
            branches: card.branches, methods: card.methods, transferCheck: card.transferCheck,
            caveat: nil,
            anchor: MemoryAnchor(kind: .letterIllustration, cue: "字母画", explanation: "字母变成画面", imagePrompt: "Draw STATE as legible letter-shaped objects")
        )
        guard try MemoryHarness.parse(String(decoding: try encoder.encode(validIllustration), as: UTF8.self), expectedWord: "state").anchor?.kind == .letterIllustration else {
            throw CheckError.failed("有效字母插画提示词未通过校验")
        }
    }

    private static func validateLegacyCardDecoding() throws {
        let encoded = try JSONEncoder().encode(sampleCard())
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CheckError.failed("无法准备旧卡片测试数据")
        }
        object.removeValue(forKey: "anchor")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MemoryCard.self, from: oldData)
        guard decoded.word == "state", decoded.anchor == nil else {
            throw CheckError.failed("新版无法读取已有的旧记忆卡")
        }
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

    private static func verifyImageStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MaimemoImageCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckError.failed("无法准备图片存储测试素材")
        }
        let store = MemoryImageStore(directoryURL: directory)
        let prompt = "Draw state with its letters forming a scene"
        guard store.imageURL(for: "state", prompt: prompt) == nil else {
            throw CheckError.failed("未生成图片却出现了缓存")
        }
        let url = try store.save(png, for: "state", prompt: prompt)
        guard store.imageURL(for: "STATE", prompt: prompt) == url,
              store.imageURL(for: "state", prompt: "another prompt") == nil,
              FileManager.default.fileExists(atPath: url.path) else {
            throw CheckError.failed("图片缓存未按单词和提示词隔离")
        }
        do {
            try store.save(Data("not an image".utf8), for: "state", prompt: "bad")
            throw CheckError.failed("无效图片被写入缓存")
        } catch MemoryImageStore.ImageError.invalidImage { }
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
            caveat: nil,
            anchor: MemoryAnchor(kind: .sound, cue: "说清楚", explanation: "将声音联想到明确表达")
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
