#if DEBUG
import AppKit
import Foundation
import MaimemoAXCore
import WordMemoryCore

@MainActor
struct CompanionLifecycleChecks {
    struct Failure: Error { let message: String }
    static func equal<T: Equatable>(_ first: T, _ second: T) throws { if first != second { throw Failure(message: "值不匹配") } }
    static func yes(_ value: Bool) throws { if !value { throw Failure(message: "预期条件不成立") } }
    static func no(_ value: Bool) throws { try yes(!value) }
    static func isNil<T>(_ value: T?) throws { try yes(value == nil) }
    static func notNil<T>(_ value: T?) throws { try yes(value != nil) }
    static func run() async throws {
        let checks = Self()
        try await checks.testImagesSurviveWordSwitchSettingsAndCollapseWithoutRevealing()
        try await checks.testOldImageCannotOverwriteNewTextVersionAndHistoryIsLocal()
        try await checks.testCapturedTextRequestSavesToOriginalWordWhenPageChanges()
        try await checks.testFailedNewCardKeepsOriginalAndBranchPresetNeedsSelection()
        try await checks.testFailureReturnAndCachedAnchorNeverSubmit()
        print("companion-lifecycle-check: 切词、设置、收起、重复点击、旧图与新版本隔离、历史零请求、原词保存和失败保护通过")
    }
    static func previewModel() -> CompanionViewModel {
        let checks = Self()
        let directory = try! checks.temporaryDirectory()
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(checks.card("helpfulness"))) as! [String: Any]
        object["caveat"] = NSNull()
        object["coreConcept"] = "有帮助这一性质，名词"
        object["coreImage"] = "同事主动搭把手，让大家轻松完成工作；这是建议画面"
        object["anchor"] = ["kind": "morphology", "cue": "helpful（有帮助的）＋ -ness（性质）", "explanation": "先认出 helpful，再用 -ness 把性质变成名词。", "imagePrompt": NSNull()]
        object["branches"] = [["partOfSpeech": "noun", "meaningKey": "helpful-quality", "chineseMeaning": "乐于帮助的态度",
            "context": "Her helpfulness made the work easier.", "signal": "Her 后作主语，是名词", "explanation": "句中说的是她愿意帮忙这一性质。"]]
        object["transferCheck"] = ["sentence": "We appreciated his helpfulness.", "targetBranch": "helpful-quality", "answer": "我们感激他乐于帮忙。", "clue": "his 后接名词，表示一种性质"]
        object["analysis"] = ["surfaceWord": "helpfulness", "lemma": NSNull(), "relations": ["derivation"], "core": "helpful", "change": "形容词 helpful → 名词 helpfulness",
            "explanation": "只拆最有用的一层；不需要把整个词族再背一遍。", "parts": [
                ["text": "helpful", "start": 0, "end": 7, "kind": "base", "meaning": "有帮助的", "relation": "derivation", "evidence": "modelUnverified"],
                ["text": "ness", "start": 7, "end": 11, "kind": "suffix", "meaning": "性质，构成名词", "relation": "derivation", "evidence": "modelUnverified"]],
            "relatedWords": [["word": "helpful", "partOfSpeech": "adjective", "meaning": "有帮助的", "relation": "derivation", "evidence": "modelUnverified"]],
            "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: object)
        let card = try! JSONDecoder().decode(MemoryCard.self, from: data)
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json")); try! store.save(card)
        Fixture.configure(String(decoding: data, as: UTF8.self))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [Fixture.self]
        let model = CompanionViewModel(memoryStore: store, imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")),
            imageGenerator: DelayedImage(data: try! checks.png()), modelClient: OpenAICompatibleClient(session: URLSession(configuration: configuration)),
            modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "fixture", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(checks.snapshot("helpfulness")); model.revealMemoryHelp()
        return model
    }

    func testImagesSurviveWordSwitchSettingsAndCollapseWithoutRevealing() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json"))
        for word in ["help", "state", "involvement"] { try store.save(card(word)) }
        let generator = DelayedImage(data: try png())
        let model = CompanionViewModel(memoryStore: store, imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")), imageGenerator: generator, checkStoredKeys: false)
        model.applySnapshot(snapshot("help")); model.revealMemoryHelp()
        model.generateCurrentIllustration(); model.generateCurrentIllustration()
        model.learnerNote = "未提交文字"; model.reasonTags = [.complex]
        model.applySnapshot(snapshot("state")); model.revealMemoryHelp(); model.generateCurrentIllustration()
        model.applySnapshot(snapshot("involvement")); model.openSettings(); model.collapseMemoryHelp()
        try Self.equal(model.learnerNote, ""); try Self.yes(model.reasonTags.isEmpty)
        try Self.no(model.isMemoryRevealed)
        try await waitFor { model.imageTasks.records.allSatisfy { !$0.state.isActive } }
        let count = await generator.count
        try Self.equal(count, 2)
        try Self.isNil(model.memoryImageURL)
        model.applySnapshot(snapshot("help"))
        try Self.no(model.isMemoryRevealed)
        try Self.notNil(model.memoryImageURL) // Cache may be ready, but the hidden view never renders it.
        model.returnToLearning(); model.revealMemoryHelp()
        try Self.notNil(model.memoryImageURL)
        try Self.equal(model.imageTasks.records.count, 2)
    }

    func testOldImageCannotOverwriteNewTextVersionAndHistoryIsLocal() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = card("help")
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json")); try store.save(original)
        Fixture.configure(try resultJSON("help", cue: "新的简短场景"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Fixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let generator = DelayedImage(data: try png())
        let model = CompanionViewModel(memoryStore: store, imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")), imageGenerator: generator,
            modelClient: OpenAICompatibleClient(session: session), modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "fixture", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(snapshot("help")); model.revealMemoryHelp(); model.generateCurrentIllustration()
        model.regenerate(.concreteScene); model.regenerate(.concreteScene)
        try await waitFor { !model.isGenerating }
        try Self.equal(Fixture.count, 1)
        try Self.equal(model.memoryCard?.anchor?.cue, "新的简短场景")
        try await waitFor { model.imageTasks.records[0].state == .completed }
        try Self.isNil(model.memoryImageURL)
        model.moveHistory(by: -1)
        try Self.notNil(model.memoryImageURL)
        model.moveHistory(by: 1)
        try Self.isNil(model.memoryImageURL)
        try Self.equal(Fixture.count, 1)
        let imageCount = await generator.count
        try Self.equal(imageCount, 1)
    }

    func testCapturedTextRequestSavesToOriginalWordWhenPageChanges() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json")); try store.save(card("state"))
        Fixture.configure(try resultJSON("help", cue: "原词的新线索"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Fixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let model = CompanionViewModel(memoryStore: store, imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")), modelClient: OpenAICompatibleClient(session: session),
            modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "fixture", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(snapshot("help")); try Self.isNil(model.memoryCard)
        model.revealMemoryHelp(); model.applySnapshot(snapshot("state"))
        try await waitFor { store.card(for: "help") != nil }
        try Self.equal(model.memoryCard?.word, "state")
        try Self.no(model.isMemoryRevealed)
        try Self.equal(store.card(for: "help")?.anchor?.cue, "原词的新线索")
        try Self.equal(Fixture.count, 1)
        try Self.yes(model.imageTasks.records.isEmpty)
    }

    func testFailedNewCardKeepsOriginalAndBranchPresetNeedsSelection() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = card("state", multiple: true)
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json")); try store.save(original)
        Fixture.configure("{broken")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Fixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let model = CompanionViewModel(memoryStore: store, imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")), modelClient: OpenAICompatibleClient(session: session),
            modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "fixture", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(snapshot("state")); model.revealMemoryHelp(); model.regenerate(.focusBranch)
        try Self.yes(model.needsBranchSelection); try Self.equal(Fixture.count, 0)
        model.selectBranch(original.branches[1]); model.regenerate(.focusBranch)
        try await waitFor { !model.isGenerating }
        try Self.notNil(model.memoryError)
        try Self.equal(store.card(for: "state"), original)
        try Self.equal(model.cardHistory.cards.count, 1)
        try Self.yes(store.redoRecords(for: "state").isEmpty)
        try Self.equal(Fixture.count, 1)
    }

    func testFailureReturnAndCachedAnchorNeverSubmit() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json"))
        Fixture.configure("{broken")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Fixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let generator = DelayedImage(data: try png())
        let model = CompanionViewModel(memoryStore: store, imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")), imageGenerator: generator,
            modelClient: OpenAICompatibleClient(session: session), modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "fixture", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(snapshot("help")); model.revealMemoryHelp()
        try await waitFor { !model.isGenerating }
        model.openSettings(); model.returnToLearning(); model.collapseMemoryHelp(); model.revealMemoryHelp()
        try await Task.sleep(for: .milliseconds(100))
        try Self.equal(Fixture.count, 1)
        let saved = card("state").withAlternateAnchor(MemoryAnchor(kind: .letterIllustration, cue: "已准备构图", explanation: "尚无图片", imagePrompt: "Draw STATE"))
        try store.save(saved); model.applySnapshot(snapshot("state")); model.revealMemoryHelp()
        model.chooseAnchor(.letterIllustration, generateImage: false)
        try Self.yes(model.imageTasks.records.isEmpty)
        model.learnerNote = "不要谐音"; model.regenerate(.naturalSound)
        try Self.equal(Fixture.count, 1)
        try Self.notNil(model.memoryError)
    }

    func card(_ word: String, multiple: Bool = false) -> MemoryCard {
        let noun = MeaningBranch(partOfSpeech: "noun", meaningKey: "core", chineseMeaning: "核心用法", context: "They offered help.", signal: "名词位置", explanation: "示例")
        let verb = MeaningBranch(partOfSpeech: "verb", meaningKey: "verb", chineseMeaning: "说明", context: "They state a reason.", signal: "谓语位置", explanation: "动词用法")
        return MemoryCard(word: word, coreConcept: "抓住核心", coreImage: "建议画面", branches: multiple ? [noun, verb] : [noun],
            methods: [MemoryMethod(id: "m1", kind: .context, title: "主线索", cue: "简短场景", whyItHelps: "直观", isLanguageFact: false)],
            transferCheck: TransferCheck(sentence: "We need help.", targetBranch: "core", answer: "核心", clue: "搭配"), caveat: nil,
            anchor: MemoryAnchor(kind: .sound, cue: "原有线索", explanation: "仍然可用"))
    }
    func resultJSON(_ word: String, cue: String) throws -> String {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card(word))) as! [String: Any]
        object["caveat"] = NSNull()
        object["anchor"] = ["kind": "context", "cue": cue, "explanation": "建议生活画面", "imagePrompt": NSNull()]
        object["analysis"] = ["surfaceWord": word, "lemma": NSNull(), "relations": ["none"], "core": "核心", "change": NSNull(),
            "explanation": "不硬拆", "parts": [], "relatedWords": [], "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func snapshot(_ word: String) -> MaimemoAXSnapshot {
        MaimemoAXSnapshot(appFound: true, appName: "离线墨墨", isTrusted: true, word: word, windowFrame: nil, nodeCount: 20, candidates: [], scannedAt: Date(), diagnostic: "离线测试")
    }
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MaimemoLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func png() throws -> Data {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    }
    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "offline-timeout", code: 1)
    }
}

private actor DelayedImage: MemoryImageGenerator {
    let data: Data
    var count = 0
    init(data: Data) { self.data = data }
    func generateImage(prompt: String) async throws -> Data {
        count += 1
        try await Task.sleep(for: .milliseconds(350))
        return data
    }
}
private final class Fixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func configure(_ text: String) {
        lock.withLock {
            body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": "stop"]]])
            requests = 0
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { Self.requests += 1; return Self.body }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

#endif
