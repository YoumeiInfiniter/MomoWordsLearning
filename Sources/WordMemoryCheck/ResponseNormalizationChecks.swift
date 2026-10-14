import Foundation
import WordMemoryCore

@MainActor
enum ResponseNormalizationChecks {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    static func fixture() -> [String: Any] {
        ["word": "neighborhood", "coreConcept": "邻居关系覆盖的一片地方或人群", "coreImage": "邻居一起照看街区的建议画面",
         "anchor": ["kind": "morphology", "cue": "neighbor + -hood：邻居关系铺开成一片", "explanation": "neighbor 是邻居，-hood 表示状态或范围。"],
         "branches": [["partOfSpeech": "noun", "meaningKey": "area", "chineseMeaning": "街区",
                       "context": "Our neighborhood is quiet.", "signal": "作名词主语", "explanation": "指邻里所在区域。"]],
         "methods": [["id": "m1", "kind": "morphology", "title": "核心结构", "cue": "neighbor + hood", "whyItHelps": "把核心词连到区域", "isLanguageFact": true]],
         "transferCheck": ["sentence": "She moved to a new neighborhood.", "targetBranch": "area", "answer": "她搬到一个新街区。", "clue": "a new 后的名词表示地区"],
         "analysis": ["surfaceWord": "neighborhood", "relations": ["derivation"], "core": "neighbor", "explanation": "只拆一层；模型分析尚未词典核验",
                      "parts": [["text": "neighbor", "start": 1, "end": 8, "kind": "base", "meaning": "邻居", "relation": "derivation", "evidence": "modelUnverified"],
                                ["text": "-hood", "start": 9, "end": 13, "kind": "suffix", "meaning": "状态或范围", "relation": "derivation", "evidence": "modelUnverified"]],
                      "relatedWords": []]]
    }
    static func raw(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
    static func reject(_ object: [String: Any]) throws {
        do { _ = try MemoryHarness.parse(raw(object), expectedWord: "neighborhood"); throw Failure(message: "不可安全修复的数据被接受") }
        catch MemoryHarnessError.invalidResponse { }
    }
    static func run() async throws {
        let request = MemoryRequest(word: "neighborhood", strategy: .auto)
        let received = try raw(fixture())
        let card = try MemoryHarness.parse(received, expectedWord: request.word)
        try MemoryResponseContract.validateStructure(received, for: request)
        try MemoryHarness.validate(card, for: request)
        try require(card.analysis?.parts.map(\.text) == ["neighbor", "hood"] && card.analysis?.parts.map(\.start) == [0, 8] && card.analysis?.parts.map(\.end) == [8, 12], "词缀记号／位置未正确本地化")
        try require(card.anchor?.cue == "neighbor + -hood：邻居关系铺开成一片", "表示规范化改写了教学正文")
        var withoutPositions = fixture()
        var analysis = withoutPositions["analysis"] as! [String: Any]
        var parts = analysis["parts"] as! [[String: Any]]
        for index in parts.indices { parts[index].removeValue(forKey: "start"); parts[index].removeValue(forKey: "end") }
        analysis["parts"] = parts; withoutPositions["analysis"] = analysis
        try require(try MemoryHarness.parse(raw(withoutPositions), expectedWord: request.word) == card, "精简 wire 与旧 wire 产生不同结果")
        var legacyType = fixture()
        analysis = legacyType["analysis"] as! [String: Any]; parts = analysis["parts"] as! [[String: Any]]
        parts[1]["start"] = "wrong index"; parts[1]["end"] = -50; analysis["parts"] = parts; legacyType["analysis"] = analysis
        try require(try MemoryHarness.parse(raw(legacyType), expectedWord: request.word) == card, "旧位置值仍影响已确认的拼写覆盖")
        for suffix in ["−hood", " – hood "] {
            var variant = fixture(); var fields = variant["analysis"] as! [String: Any]
            var tokens = fields["parts"] as! [[String: Any]]; tokens[1]["text"] = suffix
            fields["parts"] = tokens; variant["analysis"] = fields
            try require(try MemoryHarness.parse(raw(variant), expectedWord: request.word) == card, "词缀符号变体未局部规范化")
        }
        var literal = fixture(); literal["word"] = "neighbor-hood"
        var literalFields = literal["analysis"] as! [String: Any]; literalFields["surfaceWord"] = "neighbor-hood"; literal["analysis"] = literalFields
        let literalCard = try MemoryHarness.parse(raw(literal), expectedWord: "neighbor-hood")
        try require(literalCard.analysis?.parts.last?.text == "-hood", "原词真正的连字符被删除")
        var prefix = fixture(); prefix["word"] = "unbelievable"
        var prefixFields = prefix["analysis"] as! [String: Any]; prefixFields["surfaceWord"] = "unbelievable"
        prefixFields["parts"] = [["text": "un-", "kind": "prefix", "meaning": "否定", "relation": "derivation", "evidence": "modelUnverified"],
                                  ["text": "believable", "kind": "base", "meaning": "可相信的", "relation": "derivation", "evidence": "modelUnverified"]]
        prefix["analysis"] = prefixFields
        try require(try MemoryHarness.parse(raw(prefix), expectedWord: "unbelievable").analysis?.parts.map(\.text) == ["un", "believable"], "前缀记号未规范化")
        var bad = fixture(); analysis = bad["analysis"] as! [String: Any]; parts = analysis["parts"] as! [[String: Any]]
        parts[1]["text"] = "-hod"; analysis["parts"] = parts; bad["analysis"] = analysis; try reject(bad)
        bad = fixture(); analysis = bad["analysis"] as! [String: Any]; parts = analysis["parts"] as! [[String: Any]]
        parts.reverse(); analysis["parts"] = parts; bad["analysis"] = analysis; try reject(bad)
        bad = fixture(); analysis = bad["analysis"] as! [String: Any]; parts = analysis["parts"] as! [[String: Any]]
        parts[1]["kind"] = "letters"; analysis["parts"] = parts; bad["analysis"] = analysis; try reject(bad)
        bad = fixture(); analysis = bad["analysis"] as! [String: Any]; analysis.removeValue(forKey: "explanation"); bad["analysis"] = analysis; try reject(bad)
        try require(try MemoryHarness.parse(String(received.dropLast()), expectedWord: request.word) == card, "完整内容缺结尾且可空字段省略时未恢复")
        let schema = MemoryResponseContract.schema(for: request)
        let fields = schema["properties"] as! [String: Any]
        let analysisFields = (fields["analysis"] as! [String: Any])["properties"] as! [String: Any]
        let partFields = ((analysisFields["parts"] as! [String: Any])["items"] as! [String: Any])["properties"] as! [String: Any]
        try require(partFields["start"] == nil && partFields["end"] == nil, "仍让模型计算字符位置")
        try await httpRecovery(received: received, request: request, expectedCard: card)
        print("JSON recovery: neighborhood 词缀记号、错位、精简 wire、可空字段、正文保护、拒绝边界、失败暂存与本地零请求恢复通过")
    }
    static func httpRecovery(received: String, request: MemoryRequest, expectedCard: MemoryCard) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MaimemoResponse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions?token=fixture-query")!, model: "fixture",
                                       apiKey: "fixture-secret-must-not-persist")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FormatFixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = OpenAICompatibleClient(session: session)
        FormatFixture.configure(received, streaming: false, finish: "stop")
        let generated = try await client.generate(request, configuration: model)
        try require(generated == expectedCard && FormatFixture.count == 1, "表示修复产生了第二次 HTTP 请求")
        let store = FailedMemoryResponseStore(fileURL: directory.appendingPathComponent("received.json"))
        let record = FailedMemoryResponse(request: request, content: received, failureReason: "旧版本拒绝字符范围", finishReason: "stop", configuration: model)
        try store.save(record)
        let restored = FailedMemoryResponseStore(fileURL: store.fileURL)
        try require(try restored.latest(for: request.word)?.parseLocally() == expectedCard && FormatFixture.count == 1, "本地恢复丢内容或调用了模型")
        let bytes = try Data(contentsOf: store.fileURL)
        let saved = String(decoding: bytes, as: UTF8.self)
        try require(!saved.contains("fixture-secret-must-not-persist") && !saved.contains("fixture-query"), "凭据或 URL 查询参数进入了暂存文件")
        let recorder = FailureRecorder()
        var invalid = fixture(); var analysis = invalid["analysis"] as! [String: Any]
        var parts = analysis["parts"] as! [[String: Any]]; parts[1]["evidence"] = "mnemonic"
        analysis["parts"] = parts; invalid["analysis"] = analysis
        FormatFixture.configure(try raw(invalid), streaming: true, finish: "stop")
        do {
            _ = try await client.generateStreaming(request, configuration: model, onFailure: { response in await recorder.append(response) }) { _ in }
            throw Failure(message: "语义标签冲突被静默纠正")
        } catch MemoryHarnessError.invalidResponse { }
        let recorded = await recorder.records
        try require(recorded.count == 1 && recorded[0].content == (try raw(invalid)) && FormatFixture.count == 1, "失败返回未保留或自动重发")
        FormatFixture.configure(received, streaming: false, finish: "length")
        do {
            _ = try await client.generate(request, configuration: model, onFailure: { response in await recorder.append(response) })
            throw Failure(message: "length 被当作完整结果")
        } catch MemoryHarnessError.invalidResponse { }
        let truncated = await recorder.records.last!
        try require(!truncated.canReparse && FormatFixture.count == 1, "明确截断仍可本地保存或自动重发")
        do { _ = try truncated.parseLocally(); throw Failure(message: "本地解析忽略 length") }
        catch MemoryHarnessError.invalidResponse { }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptFile = directory.appendingPathComponent("corrupt.json"); try Data("bad".utf8).write(to: corruptFile)
        let blocked = FailedMemoryResponseStore(fileURL: corruptFile)
        do { try blocked.save(record); throw Failure(message: "损坏暂存文件被覆盖") }
        catch MemoryHarnessError.invalidResponse { }
        try require(try Data(contentsOf: corruptFile) == Data("bad".utf8), "原文件未保留")
    }
}
private actor FailureRecorder {
    var records: [FailedMemoryResponse] = []
    func append(_ record: FailedMemoryResponse) { records.append(record) }
}
private final class FormatFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var calls = 0
    static var count: Int { lock.withLock { calls } }
    static func configure(_ text: String, streaming: Bool, finish: String) {
        lock.withLock {
            if streaming {
                let chunk = try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": text], "finish_reason": finish]]])
                body = Data("data: \(String(decoding: chunk, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
            } else { body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": finish]]]) }
            calls = 0
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { Self.calls += 1; return Self.body }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
