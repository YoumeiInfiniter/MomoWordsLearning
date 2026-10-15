import AppKit
import Foundation
import WordMemoryCore

@MainActor
enum V3Checks {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func run(card: MemoryCard) async throws {
        try await imageQueue()
        try await resultRecovery()
        try await providerHTTP()
        try languageContract()
        try historyMigration(card: card)
        try await presets(card: card)
        print("V3: 图片队列去重、排队、取消、重启、原结果重试、版本隔离、拆词边界、九种预设与通用历史检查通过")
    }
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MaimemoV3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func imageData() throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }
    static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "等待离线任务状态超时")
    }
    static func imageQueue() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ImageTaskManager(imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")))
        let generator = SlowGenerator(data: try imageData())
        let a = ImageTaskIdentity(word: "A", versionID: "v1", prompt: "draw A")
        let b = ImageTaskIdentity(word: "B", versionID: "v1", prompt: "draw B")
        let c = ImageTaskIdentity(word: "C", versionID: "v1", prompt: "draw C")
        let a2 = ImageTaskIdentity(word: "A", versionID: "v2", prompt: "draw A differently")
        let first = try manager.enqueue(identity: a, prompt: "draw A", generator: generator)
        try require(try manager.enqueue(identity: a, prompt: "draw A", generator: generator) == first, "重复点击产生新任务")
        _ = try manager.enqueue(identity: b, prompt: "draw B", generator: generator)
        let cancelled = try manager.enqueue(identity: c, prompt: "draw C", generator: generator)
        try manager.cancel(id: cancelled)
        _ = try manager.enqueue(identity: a2, prompt: "draw A differently", generator: generator)
        try await waitFor { !manager.records.contains(where: { $0.state.isActive }) }
        let counts = await generator.counts()
        try require(counts.0 == 3 && counts.1 == 1, "队列并发或提交计数不正确")
        try require(manager.task(for: c)?.state == .cancelled, "排队取消未保存")
        try require(manager.imageURL(for: a, prompt: "draw A") != nil && manager.imageURL(for: a2, prompt: "draw A differently") != manager.imageURL(for: a, prompt: "draw A"), "旧图片串入新版本")
        _ = try manager.enqueue(identity: a, prompt: "draw A", generator: generator)
        try require(await generator.counts().0 == 3, "已完成任务重复提交")
        let reloaded = ImageTaskManager(imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")))
        try require(reloaded.records.count == 4 && reloaded.task(for: a)?.state == .completed, "重启丢失已保存图片")
        var records = reloaded.records
        records[0].state = .generating; records[0].localPath = nil
        try JSONEncoder().encode(records).write(to: manager.fileURL, options: .atomic)
        let interrupted = ImageTaskManager(imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")))
        try require(interrupted.records[0].state == .failed && interrupted.records[0].failure?.kind == "result_unknown", "同步接口中断被伪称可恢复")
        try require(await generator.counts().0 == 3, "重启偷偷重新付费提交")
        let malformed = directory.appendingPathComponent("unreadable.json")
        try Data("bad".utf8).write(to: malformed)
        let blocked = ImageTaskManager(fileURL: malformed)
        do { _ = try blocked.enqueue(identity: a, prompt: "draw A", generator: generator); throw Failure(message: "损坏任务记录仍允许提交") }
        catch is ImageTaskFailure { }
        try require(try Data(contentsOf: malformed) == Data("bad".utf8), "损坏任务文件被覆盖")
    }
    static func resultRecovery() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryImageStore(directoryURL: directory.appendingPathComponent("images"))
        let manager = ImageTaskManager(imageStore: store)
        let provider = DownloadGenerator(data: try imageData())
        let identity = ImageTaskIdentity(word: "help", versionID: "v1", prompt: "help scene")
        let id = try manager.enqueue(identity: identity, prompt: "help scene", generator: provider)
        try await waitFor { manager.records.first?.state == .failed }
        let failure = manager.records[0]
        try require(failure.failure?.phase == "downloading" && manager.canResume(failure), "下载失败不能继续原结果")
        try require(await provider.counts() == [1, 2], "下载失败触发了新生成")
        try manager.resumeResult(id: id, generator: provider)
        try await waitFor { manager.records[0].state == .completed }
        try require(await provider.counts() == [1, 3], "继续下载不是原结果")
        let badImages = directory.appendingPathComponent("blocked-images")
        try Data().write(to: badImages)
        let saving = ImageTaskManager(imageStore: MemoryImageStore(directoryURL: badImages), fileURL: directory.appendingPathComponent("saving-tasks.json"))
        let slow = SlowGenerator(data: try imageData())
        let savingID = try saving.enqueue(identity: identity, prompt: "help scene", generator: slow)
        try await waitFor { saving.records.first?.state == .failed }
        try require(saving.records[0].stagedDataPath != nil && saving.records[0].failure?.phase == "saving", "保存失败丢失原图片")
        try FileManager.default.removeItem(at: badImages)
        try saving.resumeResult(id: savingID, generator: slow)
        try await waitFor { saving.records[0].state == .completed }
        try require(await slow.counts().0 == 1, "保存重试重新提交生成")
    }
    static func providerHTTP() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageHTTPFixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let generator = MaiziImageGenerator(session: session, apiKeyProvider: { "fixture-only" })
        let png = try imageData()
        let response = try JSONSerialization.data(withJSONObject: ["data": [["url": "https://unit.test/result.png"]], "error": NSNull()])
        ImageHTTPFixture.configure([(200, response), (503, Data()), (200, png)])
        let manager = ImageTaskManager(imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")))
        let identity = ImageTaskIdentity(word: "help", versionID: "http", prompt: "help")
        _ = try manager.enqueue(identity: identity, prompt: "help", generator: generator)
        try await waitFor { manager.records.first?.state == .completed }
        try require(ImageHTTPFixture.methods == ["POST", "GET", "GET"], "HTTP 下载重试导致新生图提交")
        let body = ImageHTTPFixture.submissionBody
        try require(body["model"] as? String == "gpt-image-2.5" && body["n"] as? Int == 1 && body["size"] as? String == "1:1" && body["resolution"] as? String == "1K", "图片配置被改变")
        for (payload, expectedKind) in [(Data("{}".utf8), "authentication"), (Data("{\"error\":{\"message\":\"fixture\"}}".utf8), "remote_failure"), (Data("{\"task_id\":\"original-task\"}".utf8), "unsupported_async")] {
            ImageHTTPFixture.configure([(expectedKind == "authentication" ? 401 : 200, payload)])
            let taskManager = ImageTaskManager(imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("images")))
            _ = try taskManager.enqueue(identity: identity, prompt: "help", generator: generator)
            try await waitFor { taskManager.records.first?.state == .failed }
            try require(taskManager.records[0].failure?.kind == expectedKind && ImageHTTPFixture.methods == ["POST"], "HTTP 错误被混淆或自动重复提交")
            if expectedKind == "unsupported_async" { try require(taskManager.records[0].serverTaskID == "original-task", "已返回任务 ID 未保存") }
        }
        let paymentFixtures: [(String, String)] = [
            ("", "尚未识别具体原因"),
            ("<html>fixture-private-response</html>", "尚未识别具体原因"),
            (#"{"error":{"code":"insufficient_balance","message":"fixture-private-response"}}"#, "余额不足提示"),
            (#"{"error":{"type":"insufficient_quota","message":"fixture-private-response"}}"#, "额度不足提示"),
            (#"{"message":"账户余额不足 fixture-private-response"}"#, "余额不足提示"),
            (#"{"error":"Insufficient credits fixture-private-response"}"#, "额度不足提示"),
            (#"{"error":{"code":"unknown_code","message":"fixture-private-response"}}"#, "尚未识别具体原因"),
            (#"{"error":{"code":"insufficient_balance","message":""# + String(repeating: "x", count: 65_537) + #""}}"#, "尚未识别具体原因")
        ]
        for (payload, expectedMessage) in paymentFixtures {
            ImageHTTPFixture.configure([(402, Data(payload.utf8))])
            let store = MemoryImageStore(directoryURL: directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("images"))
            let taskManager = ImageTaskManager(imageStore: store)
            let id = try taskManager.enqueue(identity: identity, prompt: "help", generator: generator)
            try await waitFor { taskManager.records.first?.state == .failed }
            let record = taskManager.records[0]
            try require(record.failure?.isPaymentRequired == true && record.failure?.httpStatus == 402 && record.failure?.phase == "submitting", "402 未保留提交阶段及付款分类")
            try require(record.failure?.userMessage.contains(expectedMessage) == true && !taskManager.canResume(record), "402 原因提示不准确或错误允许下载")
            let saved = try String(contentsOf: taskManager.fileURL, encoding: .utf8)
            try require(!saved.contains("fixture-private-response") && !saved.contains("fixture-only"), "错误响应原文或密钥进入任务存储")
            let reloaded = ImageTaskManager(imageStore: store)
            let sameID = try reloaded.enqueue(identity: identity, prompt: "help", generator: generator)
            try require(sameID == id && reloaded.records[0].failure?.isPaymentRequired == true && ImageHTTPFixture.methods == ["POST"], "402 重启或重复点击再次提交")
            // Once the account issue is resolved, only an explicit new generation may submit again.
            ImageHTTPFixture.configure([(200, try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]]))])
            let retryID = try reloaded.enqueue(identity: identity, prompt: "help", generator: generator, newGeneration: true)
            try await waitFor { reloaded.records.last?.state == .completed }
            try require(retryID != id && ImageHTTPFixture.methods == ["POST"], "402 后主动提交未恢复为单次请求")
        }
        let legacyFailure = try JSONDecoder().decode(ImageTaskFailure.self, from: Data(#"{"phase":"submitting","kind":"rejected","message":"图片生成请求失败（HTTP 402）"}"#.utf8))
        try require(legacyFailure.isPaymentRequired && legacyFailure.userMessage.contains("核对 MaiziAI"), "旧版 402 任务未兼容显示")
        try require(!MaiziImageError.downloadFailed(402).taskFailure.isPaymentRequired, "图片下载 402 被误判为生成付款限制")
        try require(MemoryPreset.naturalSound.conflict(with: "不要谐音") != nil && MemoryPreset.hybrid.conflict(with: "不要整词谐音，只补局部") == nil, "补充冲突判断过宽或漏掉直接冲突")
    }

    static func analysisCard(word: String, kind: MemoryAnchorKind, relation: String, pieces: [(String, String, String?)], explanation: String = "只拆最有用的一层") throws -> MemoryCard {
        var offset = 0
        let parts: [[String: Any]] = pieces.map { text, partKind, meaning in
            let start = offset; offset += text.count
            return ["text": text, "start": start, "end": offset, "kind": partKind,
                    "meaning": meaning as Any? ?? NSNull(), "relation": relation,
                    "evidence": relation == "mnemonicSplit" ? "mnemonic" : "modelUnverified"]
        }
        let examples: [String: (String, String, String, String)] = [
            "help": ("帮助", "noun", "They offered help.", "We need help."),
            "helped": ("帮助过／过去分词用法依语境", "verb", "She helped her friend yesterday.", "He helped us finish the work."),
            "helps": ("帮助；这句是第三人称单数", "verb", "He helps his friends.", "She helps people find jobs."),
            "helpful": ("有帮助的", "adjective", "Your advice was helpful.", "We found her explanation helpful."),
            "helpless": ("无助的", "adjective", "He felt helpless in the storm.", "The child looked helpless."),
            "helpfulness": ("有帮助这一性质／乐于帮忙", "noun", "Her helpfulness made the work easier.", "We appreciated his helpfulness."),
            "raincoat": ("雨衣", "noun", "She wore a raincoat.", "He left his raincoat by the door."),
            "state": ("明确说明", "verb", "Please state your reason.", "The notice states the new rule."),
            "unbelievable": ("难以置信的", "adjective", "His story was unbelievable.", "The team made an unbelievable recovery."),
            "involvement": ("参与／卷入，英文是名词", "noun", "Her involvement improved the project.", "They denied any involvement in the incident."),
            "axes": ("这句是轴；屏幕原词也可能是 axe 的复数，不能唯一还原", "noun", "The graph has two axes.", "Label both axes on the chart.")
        ]
        let example = examples[word] ?? ("离线结构样例", "noun", "A sample sentence.", "A different sample sentence.")
        let object: [String: Any] = ["word": word, "coreConcept": example.0, "coreImage": "连接当前意思的建议画面（离线样例）",
            "anchor": ["kind": kind.rawValue, "cue": "一条简短线索", "explanation": explanation, "imagePrompt": NSNull()],
            "branches": [["partOfSpeech": example.1, "meaningKey": "help", "chineseMeaning": example.0,
                          "context": example.2, "signal": "看句法位置和搭配", "explanation": "词性由英文用法判断，不由中文译词判断"]],
            "methods": [["id": "m1", "kind": "context", "title": "主线索", "cue": "帮助", "whyItHelps": "简单", "isLanguageFact": false]],
            "transferCheck": ["sentence": example.3, "targetBranch": "help", "answer": example.0, "clue": "结合句法位置和搭配"],
            "caveat": NSNull(),
            "analysis": ["surfaceWord": word, "lemma": NSNull(), "relations": [relation], "core": "核心",
                         "change": NSNull(), "explanation": explanation, "parts": parts, "relatedWords": [],
                         "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]]
        return try JSONDecoder().decode(MemoryCard.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func languageContract() throws {
        let cases: [(String, MemoryAnchorKind, String, [(String, String, String?)])] = [
            ("help", .context, "none", []),
            ("helped", .wordForm, "inflection", [("help", "base", "帮助"), ("ed", "suffix", "过去式／过去分词；依语境")]),
            ("helpful", .morphology, "derivation", [("help", "base", "帮助"), ("ful", "suffix", "有…的")]),
            ("helpless", .morphology, "derivation", [("help", "base", "帮助"), ("less", "suffix", "没有…的")]),
            ("helpfulness", .morphology, "derivation", [("helpful", "base", "有帮助的"), ("ness", "suffix", "性质，名词")]),
            ("raincoat", .morphology, "compound", [("rain", "base", "雨"), ("coat", "base", "外套")]),
            ("state", .familiarChunks, "mnemonicSplit", [("st", "letters", nil), ("ate", "familiarWord", "吃过，仅助记")]),
            ("state", .hybrid, "mnemonicSplit", [("st", "letters", nil), ("ate", "familiarWord", "局部声音联想")]),
            ("helps", .wordForm, "inflection", [("help", "base", "帮助"), ("s", "suffix", "当前示例句的第三人称单数")]),
            ("unbelievable", .morphology, "derivation", [("un", "prefix", "否定"), ("believable", "base", "可以相信的")]),
            ("involvement", .morphology, "derivation", [("involve", "base", "涉及／使参与"), ("ment", "suffix", "构成名词")]),
            ("axes", .wordForm, "inflection", [])
        ]
        for (word, kind, relation, parts) in cases {
            let card = try analysisCard(word: word, kind: kind, relation: relation, pieces: parts)
            let raw = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
            _ = try MemoryHarness.parse(raw, expectedWord: word)
            try MemoryHarness.validate(card, for: MemoryRequest(word: word, strategy: .auto))
            try require(MemoryHarness.quickHint(from: raw, expectedWord: word)?.anchor.kind == kind, "新记法快速线索失效")
        }
        let bad = try analysisCard(word: "state", kind: .familiarChunks, relation: "mnemonicSplit", pieces: [("st", "letters", nil), ("at", "familiarWord", nil)])
        do { _ = try MemoryHarness.parse(String(decoding: JSONEncoder().encode(bad), as: UTF8.self), expectedWord: "state"); throw Failure(message: "拆词漏字通过校验") }
        catch MemoryHarnessError.invalidResponse { }
        let wrongFact = try analysisCard(word: "state", kind: .familiarChunks, relation: "derivation", pieces: [("st", "letters", nil), ("ate", "base", nil)])
        do { _ = try MemoryHarness.parse(String(decoding: JSONEncoder().encode(wrongFact), as: UTF8.self), expectedWord: "state"); throw Failure(message: "任意字母当语言事实通过") }
        catch MemoryHarnessError.invalidResponse { }
    }
    static func historyMigration(card: MemoryCard) throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.json")
        let old = MemoryStore(fileURL: file)
        try old.save(card)
        let newer = card.replacingAnchor(MemoryAnchor(kind: .sound, cue: "新的谐音", explanation: "新解释"))
        try old.save(newer, replacing: card)
        _ = try old.moveSoundHistory(for: card.word, by: -1)
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        legacy.removeValue(forKey: "histories")
        let priorBytes = try JSONSerialization.data(withJSONObject: legacy); try priorBytes.write(to: file, options: .atomic)
        let migrated = MemoryStore(fileURL: file)
        try require(migrated.history(for: card.word).selectedIndex == 0, "旧历史选择位置丢失")
        let branch = card.branches[1]
        try migrated.recordFeedback(word: card.word, branch: branch, result: .forgotten, condition: .selfReport, reason: .branch, note: "动词用法忘了")
        let revised = card.replacingAnchor(MemoryAnchor(kind: .hybrid, cue: "结构加声音", explanation: "一种混合线索"))
        let request = MemoryRequest(word: card.word, learnerNote: "额外补充", existingCard: card, focusMeaningKey: branch.meaningKey,
            strategy: .hybrid, preset: .hybrid, reasonTags: [.complex], focusBranchID: branch.id)
        let record = MemoryRedoRecord(request: request, card: revised, model: "mock", endpoint: "https://unit.test", thinkingEnabled: false)
        try migrated.save(revised, replacing: card, redoRecord: record)
        let reloaded = MemoryStore(fileURL: file)
        try require(reloaded.history(for: card.word).cards == [card, newer, revised], "旧版重做截断后续或新记法历史")
        try require(reloaded.branch(for: card.word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)?.lastResult == .forgotten, "换记法覆盖回忆成绩")
        try require(reloaded.redoRecords(for: card.word).first?.reasonTags == [.complex] && reloaded.redoRecords(for: card.word).first?.userSupplement == "额外补充", "请求字段无法追溯")
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("memory-before-v3-") }
        try require(backups.count == 1 && Data(contentsOf: backups[0]) == priorBytes, "旧数据迁移没有可恢复备份")
    }
    static func presets(card: MemoryCard) async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [V3Protocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let client = OpenAICompatibleClient(session: session)
        let model = ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "mock", apiKey: "fixture-only")
        for preset in MemoryPreset.allCases {
            let focus = card.branches[1]
            let request = MemoryRequest(word: "state", learnerNote: "我的补充", existingCard: card,
                focusMeaningKey: preset == .focusBranch ? focus.meaningKey : "help", strategy: preset.strategy, preset: preset,
                reasonTags: [.forced], focusBranchID: preset == .focusBranch ? focus.id : nil)
            var fixture = try analysisCard(word: "state", kind: preset.strategy.anchorKind ?? .context, relation: "none", pieces: [])
            if preset == .focusBranch {
                fixture = MemoryCard(word: card.word, coreConcept: card.coreConcept, coreImage: card.coreImage, branches: card.branches,
                    methods: card.methods, transferCheck: card.transferCheck, caveat: nil, anchor: fixture.anchor, analysis: fixture.analysis)
            }
            var wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as! [String: Any]
            wire["caveat"] = NSNull()
            var anchor = wire["anchor"] as! [String: Any]; anchor["imagePrompt"] = NSNull(); wire["anchor"] = anchor
            var analysis = wire["analysis"] as! [String: Any]
            for key in ["lemma", "change", "notSuitableReason", "alternativeSuggestion"] { analysis[key] = NSNull() }
            if [.morphology, .wordFamily, .familiarChunks, .hybrid, .wordForm].contains(preset.strategy) {
                analysis["notSuitableReason"] = "当前离线样例不提供这个分析，明确拒绝伪造"
                analysis["alternativeSuggestion"] = "可由用户另选场景"
            }
            wire["analysis"] = analysis
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
            V3Protocol.configure(raw)
            _ = try await client.generate(request, configuration: model)
            try require(V3Protocol.count == 1, "预设追加模型请求")
            let prompt = MemoryHarness.userPrompt(request)
            try require(prompt.contains(preset.rawValue) && prompt.contains(card.versionKey) && prompt.contains("我的补充") && prompt.contains("太牵强"), "预设丢失上下文")
        }
    }
}

private actor SlowGenerator: MemoryImageGenerator {
    let data: Data
    var submissions = 0
    var active = 0
    var maxActive = 0
    init(data: Data) { self.data = data }
    func generateImage(prompt: String) async throws -> Data {
        submissions += 1; active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(80))
        return data
    }
    func counts() -> (Int, Int) { (submissions, maxActive) }
}
private actor DownloadGenerator: StagedMemoryImageGenerator {
    let data: Data
    var submitted = 0
    var downloaded = 0
    init(data: Data) { self.data = data }
    func generateImage(prompt: String) async throws -> Data { throw V3Checks.Failure(message: "不应调用兼容生成入口") }
    func submitImage(prompt: String) async throws -> MaiziImageResult { submitted += 1; return .url(URL(string: "https://unit.test/result.png")!) }
    func downloadImage(from url: URL) async throws -> Data {
        downloaded += 1
        if downloaded <= 2 { throw URLError(.networkConnectionLost) }
        return data
    }
    func counts() -> [Int] { [submitted, downloaded] }
}
private final class V3Protocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests = 0
    static var count: Int { lock.withLock { requests } }
    static func configure(_ content: String) {
        lock.withLock { body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]]); requests = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { Self.requests += 1; return Self.body }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ImageHTTPFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var seenMethods: [String] = []
    nonisolated(unsafe) static var body: [String: Any] = [:]
    static var methods: [String] { lock.withLock { seenMethods } }
    static var submissionBody: [String: Any] { lock.withLock { body } }
    static func configure(_ items: [(Int, Data)]) { lock.withLock { responses = items; seenMethods = []; body = [:] } }
    override class func canInit(with request: URLRequest) -> Bool { true } // All requests stay inside this ephemeral mock session.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable && data.count < 1_048_576 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            requestBody = data
        }
        let response = Self.lock.withLock {
            Self.seenMethods.append(request.httpMethod ?? "GET")
            if let data = requestBody { Self.body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
            return Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
