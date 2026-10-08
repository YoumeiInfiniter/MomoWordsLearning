import Foundation
import WordMemoryCore

@MainActor
enum JSONContractChecks {
    static func run(card: MemoryCard) async throws {
        try verifyThinkingToggle()
        let json = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        let configuration = ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!,
                                               model: "mock-model", apiKey: "test-only-not-a-credential")
        for kind in MemoryAnchorKind.allCases {
            let request = MemoryRequest(word: "state", preferredAnchorKind: kind)
            for streaming in [true, false] {
                let http = try OpenAICompatibleClient.makeRequest(request, configuration: configuration, streaming: streaming)
                let body = try JSONSerialization.jsonObject(with: http.httpBody!) as! [String: Any]
                try require((body["response_format"] as? [String: String])?["type"] == "json_object", "请求未启用 JSON 模式")
                try require(body["stream"] as? Bool == streaming, "同步与流式请求配置不一致")
                try require((body["max_tokens"] as? Int ?? 0) >= 4096, "没有给完整 JSON 留足输出空间")
            }
            let properties = MemoryResponseContract.schema(for: request)["properties"] as! [String: Any]
            for name in ["branches", "methods"] {
                try require((properties[name] as? [String: Any])?["maxItems"] as? Int == 1, "输出契约仍允许冗余语境或记法")
            }
            let anchor = properties["anchor"] as! [String: Any]
            let anchorFields = anchor["properties"] as! [String: Any]
            try require((anchorFields["kind"] as? [String: Any])?["enum"] as? [String] == [kind.rawValue], "契约没有锁定用户选择")
            let example = MemoryResponseContract.instructions(for: request).components(separatedBy: "\n").last!
            try require((try JSONSerialization.jsonObject(with: Data(example.utf8))) is [String: Any], "契约示例不是合法 JSON")
        }
        let escaped = MemoryResponseContract.instructions(for: MemoryRequest(word: "a\"b\\c", focusMeaningKey: "x\"y"))
        _ = try JSONSerialization.jsonObject(with: Data(escaped.components(separatedBy: "\n").last!.utf8))

        for wrapped in [json, "```json\n\(json)\n```", "本次联想如下：\n\(json)\n以上是辅助联想。", String(json.dropLast()) + ",}"] {
            try require(try MemoryHarness.parse(wrapped, expectedWord: "state", requiredAnchorKind: .sound) == card,
                        "本地格式恢复改变了内容或解析失败")
        }
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        var anchor = object["anchor"] as! [String: Any]
        anchor["cue"] = #"引号 \" 和逗号 ,} ,] 与花括号 {x}、反斜杠 \\"#
        object["anchor"] = anchor
        let quotedContent = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let trailingCommas = quotedContent.replacingOccurrences(of: "}],", with: "},],")
        let restored = try MemoryHarness.parse(trailingCommas, expectedWord: "state")
        try require(restored.anchor?.cue == anchor["cue"] as? String, "格式恢复改写了字符串里的引号或标点")

        try reject(String(json.dropLast()), word: "state", contains: "未完整返回")
        try reject("[\(json)]", word: "state", contains: "数组")
        try reject(json + "\n" + json, word: "state", contains: "多个")
        object.removeValue(forKey: "coreConcept")
        try reject(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), word: "state", contains: "coreConcept")
        object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        object["branches"] = ["context": "wrong shape"]
        try reject(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), word: "state", contains: "branches")
        object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        anchor = object["anchor"] as! [String: Any]
        anchor["kind"] = "sound|letterIllustration"
        object["anchor"] = anchor
        try reject(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), word: "state", contains: "anchor.kind")
        try reject(json, word: "claim", contains: "单词")
        try verifyCompleteFieldClosure(json: json, card: card)

        var stream = ChatCompletionStreamAccumulator()
        try stream.append(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}"#)
        try stream.append(#"{"choices":[{"index":0,"delta":{"reasoning_content":"{非答案}"}}]}"#)
        var framing = ServerSentEventDecoder()
        let pieces = [String(json.prefix(json.count / 2)), String(json.suffix(json.count - json.count / 2))]
        for piece in pieces {
            let payload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": piece]]]])
            let wire = "data: \(String(decoding: payload, as: UTF8.self))\r\n\r\n"
            for byte in wire.utf8 {
                if let event = framing.append(byte) { try stream.append(event.data) }
            }
        }
        try stream.append(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
        try stream.append(#"{"choices":[],"usage":{"completion_tokens":100}}"#)
        try require(try stream.completedContent() == json, "角色、思考或用量消息破坏了答案")
        try stream.append("[DONE]")
        try require(stream.isDone, "未识别流式结束")
        var truncated = ChatCompletionStreamAccumulator()
        try truncated.append(#"{"choices":[{"delta":{"content":"{"},"finish_reason":"length"}]}"#)
        do {
            _ = try truncated.completedContent()
            throw Failure(message: "截断响应被当成完整答案")
        } catch MemoryHarnessError.invalidResponse(let reason) {
            try require(reason.contains("截断"), "截断响应仍只报告 JSON 错误")
        }

        // Mock the complete HTTP path: no external connection or real key is used.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = OpenAICompatibleClient(session: session)
        let request = MemoryRequest(word: "state")
        FixtureProtocol.configure(body: try envelope(json), status: 200)
        try require(try await client.generate(request, configuration: configuration) == card, "HTTP 模拟响应未还原记忆卡")
        try require(FixtureProtocol.requestCount == 1, "生成发起了多次请求")
        for reason in ["", "太牵强"] {
            FixtureProtocol.configure(body: try envelope(json), status: 200)
            let revised = try await client.generate(MemoryRequest.revisingSound(card, reason: reason), configuration: configuration)
            try require(revised == card && FixtureProtocol.requestCount == 1, "可选原因导致重做被阻止或发起多次请求")
        }
        let streamedPayload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": json], "finish_reason": "stop"]]])
        let wire = Data("data: \(String(decoding: streamedPayload, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
        let hints = HintRecorder()
        FixtureProtocol.configure(body: wire, status: 200, mime: "text/event-stream")
        let streamed = try await client.generateStreaming(request, configuration: configuration) { hint in
            await hints.record(hint)
        }
        try require(streamed == card && FixtureProtocol.requestCount == 1, "流式生成没有使用单次请求还原卡片")
        try require(await hints.count == 1, "JSON 模式破坏了首条线索展示")
        var completeObject = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        completeObject["caveat"] = NSNull()
        var completeAnchor = completeObject["anchor"] as! [String: Any]
        completeAnchor["imagePrompt"] = NSNull()
        completeObject["anchor"] = completeAnchor
        let completeJSON = String(decoding: try JSONSerialization.data(withJSONObject: completeObject, options: .sortedKeys), as: UTF8.self)
        FixtureProtocol.configure(body: try streamWire(String(completeJSON.dropLast()), finish: "stop", done: true), status: 200, mime: "text/event-stream")
        try require(try await client.generateStreaming(request, configuration: configuration) { _ in } == card,
                    "全部内容已收到但缺结尾括号时未本地恢复")
        try require(FixtureProtocol.requestCount == 1, "本地括号恢复产生了追加请求")
        // Missing content still fails, and the UI now distinguishes service stop from EOF.
        for finish in [nil, "stop", "length"] as [String?] {
            FixtureProtocol.configure(body: try streamWire("{\"word\":\"state\"", finish: finish, done: finish != nil), status: 200, mime: "text/event-stream")
            do {
                _ = try await client.generateStreaming(request, configuration: configuration) { _ in }
                throw Failure(message: "真正缺少字段的响应被保存")
            } catch MemoryHarnessError.invalidResponse(let reason) {
                let expected = finish == nil ? "响应流提前结束" : (finish == "length" ? "长度上限" : "服务结束原因：stop")
                try require(reason.contains(expected), "不完整响应未区分流中断、服务结束和长度截断")
            }
            try require(FixtureProtocol.requestCount == 1, "不完整响应触发了自动付费重试")
        }
        FixtureProtocol.configure(body: try streamWire(String(completeJSON.dropLast()), finish: "length", done: true), status: 200, mime: "text/event-stream")
        do {
            _ = try await client.generateStreaming(request, configuration: configuration) { _ in }
            throw Failure(message: "明确长度截断的响应仍被恢复")
        } catch MemoryHarnessError.invalidResponse(let reason) {
            try require(reason.contains("长度上限"), "长度结束标志被忽略")
        }
        FixtureProtocol.configure(body: try envelope(json), status: 200)
        let nonStreamingFallback = try await client.generateStreaming(request, configuration: configuration) { _ in }
        try require(nonStreamingFallback == card && FixtureProtocol.requestCount == 1, "同步返回的兼容处理再次发起了请求")
        FixtureProtocol.configure(body: try envelope("{broken"), status: 200)
        do {
            _ = try await client.generate(request, configuration: configuration)
            throw Failure(message: "无效响应没有报错")
        } catch MemoryHarnessError.invalidResponse { }
        try require(FixtureProtocol.requestCount == 1, "格式错误触发了自动付费重试")
        FixtureProtocol.configure(body: Data("{}".utf8), status: 400)
        do {
            _ = try await client.generate(request, configuration: configuration)
            throw Failure(message: "HTTP 400 没有报错")
        } catch MemoryHarnessError.requestFailed(400) { }
        try require(FixtureProtocol.requestCount == 1, "接口拒绝参数后自动重发了请求")
    }

    private static func verifyThinkingToggle() throws {
        let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
        let request = MemoryRequest(word: "state")
        let defaultConfiguration = ModelConfiguration(endpoint: endpoint, model: "deepseek-flash", apiKey: "test-only")
        try require(defaultConfiguration.thinkingEnabled, "升级后默认思考模式应保持开启")
        try require(ModelConfiguration.supportsThinkingToggle(at: endpoint), "DeepSeek 官方接口未识别")
        try require(!ModelConfiguration.supportsThinkingToggle(at: URL(string: "https://api.deepseek.com.unit.test/chat/completions")!),
                    "非官方接口错误地获得了 DeepSeek 专有参数")
        for streaming in [true, false] {
            var requestBodies: [[String: Any]] = []
            for enabled in [true, false] {
                let configuration = ModelConfiguration(endpoint: endpoint, model: "deepseek-flash", apiKey: "test-only",
                                                       thinkingEnabled: enabled)
                let http = try OpenAICompatibleClient.makeRequest(request, configuration: configuration, streaming: streaming)
                var body = try JSONSerialization.jsonObject(with: http.httpBody!) as! [String: Any]
                try require((body["thinking"] as? [String: String])?["type"] == (enabled ? "enabled" : "disabled"),
                            "思考开关没有正确映射到同步/流式请求")
                try require((body["response_format"] as? [String: String])?["type"] == "json_object", "切换思考关闭了 JSON 模式")
                try require(body["reasoning_effort"] == nil, "开关引入了冲突的思考强度参数")
                body.removeValue(forKey: "thinking")
                requestBodies.append(body)
                let compatible = ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!,
                                                    model: "mock", apiKey: "test-only", thinkingEnabled: enabled)
                let compatibleHTTP = try OpenAICompatibleClient.makeRequest(request, configuration: compatible, streaming: streaming)
                let compatibleBody = try JSONSerialization.jsonObject(with: compatibleHTTP.httpBody!) as! [String: Any]
                try require(compatibleBody["thinking"] == nil, "向其他兼容接口发送了 DeepSeek 专有参数")
            }
            let enabledBody = try JSONSerialization.data(withJSONObject: requestBodies[0], options: .sortedKeys)
            let disabledBody = try JSONSerialization.data(withJSONObject: requestBodies[1], options: .sortedKeys)
            try require(enabledBody == disabledBody, "切换思考模式改变了模型、提示词或生成约束")
        }
    }

    private static func verifyCompleteFieldClosure(json: String, card: MemoryCard) throws {
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        object["caveat"] = NSNull()
        var anchor = object["anchor"] as! [String: Any]
        anchor["imagePrompt"] = NSNull()
        object["anchor"] = anchor
        let complete = String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        try require(try MemoryHarness.parse(String(complete.dropLast()), expectedWord: "state", requiredAnchorKind: .sound) == card,
                    "只缺根括号时恢复失败或改变了内容")
        var head = object
        let transfer = head.removeValue(forKey: "transferCheck")!
        let headJSON = String(decoding: try JSONSerialization.data(withJSONObject: head, options: .sortedKeys), as: UTF8.self)
        let transferJSON = String(decoding: try JSONSerialization.data(withJSONObject: transfer, options: .sortedKeys), as: UTF8.self)
        let nested = String(headJSON.dropLast()) + ",\"transferCheck\":" + String(transferJSON.dropLast())
        try require(try MemoryHarness.parse(nested, expectedWord: "state") == card, "仅缺多层结尾括号未安全恢复")
        try reject(nested + ",", word: "state", contains: "未完整返回")
        try reject(String(complete.dropLast(2)), word: "state", contains: "未完整返回")
        try reject("[" + String(complete.dropLast()), word: "state", contains: "数组")
        for key in ["coreConcept", "caveat", "transferCheck"] {
            var missing = object
            missing.removeValue(forKey: key)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: missing, options: .sortedKeys), as: UTF8.self)
            try reject(String(text.dropLast()), word: "state", contains: "未完整返回")
        }
        var wrongTarget = object
        var transferFields = wrongTarget["transferCheck"] as! [String: Any]
        transferFields["targetBranch"] = "does-not-exist"
        wrongTarget["transferCheck"] = transferFields
        let wrongTargetJSON = String(decoding: try JSONSerialization.data(withJSONObject: wrongTarget), as: UTF8.self)
        try reject(String(wrongTargetJSON.dropLast()), word: "state", contains: "新句与义项")
        var partialBranch = object
        var branchFields = (partialBranch["branches"] as! [[String: Any]])[0]
        branchFields.removeValue(forKey: "explanation")
        partialBranch["branches"] = [branchFields]
        let partialBranchJSON = String(decoding: try JSONSerialization.data(withJSONObject: partialBranch), as: UTF8.self)
        try reject(String(partialBranchJSON.dropLast()), word: "state", contains: "未完整返回")
        var escapedObject = object
        var escapedAnchor = escapedObject["anchor"] as! [String: Any]
        let escapedCue = "引号\"、括号 {x} ]、反斜杠\\"
        escapedAnchor["cue"] = escapedCue
        escapedObject["anchor"] = escapedAnchor
        let escapedJSON = String(decoding: try JSONSerialization.data(withJSONObject: escapedObject), as: UTF8.self)
        try require(try MemoryHarness.parse(String(escapedJSON.dropLast()), expectedWord: "state").anchor?.cue == escapedCue,
                    "结尾恢复改变了字符串内容")
        anchor.removeValue(forKey: "imagePrompt")
        object["anchor"] = anchor
        let missingNullable = String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        try reject(String(missingNullable.dropLast()), word: "state", contains: "未完整返回")
    }

    private static func streamWire(_ text: String, finish: String?, done: Bool) throws -> Data {
        let split = text.count / 2
        var wire = ""
        for piece in [String(text.prefix(split)), String(text.dropFirst(split))] {
            let payload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": piece]]]])
            wire += "data: \(String(decoding: payload, as: UTF8.self))\r\n\r\n"
        }
        if let finish {
            let payload = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": [:], "finish_reason": finish]]])
            wire += "data: \(String(decoding: payload, as: UTF8.self))\n\n"
        }
        if done { wire += "data: [DONE]\n\n" }
        return Data(wire.utf8)
    }

    private static func envelope(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "finish_reason": "stop", "message": ["content": text]]]])
    }
    private static func reject(_ json: String, word: String, contains: String) throws {
        do {
            _ = try MemoryHarness.parse(json, expectedWord: word)
            throw Failure(message: "无效结果未被拒绝：\(contains)")
        } catch MemoryHarnessError.invalidResponse(let reason) {
            try require(reason.contains(contains), "错误没有标明原因：\(reason)")
        }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

private actor HintRecorder {
    private(set) var count = 0
    func record(_ hint: QuickMemoryHint) { count += 1 }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responseMime = "application/json"
    nonisolated(unsafe) private static var count = 0

    static func configure(body: Data, status: Int, mime: String = "application/json") {
        lock.lock(); defer { lock.unlock() }
        responseBody = body; responseStatus = status; responseMime = mime; count = 0
    }
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let body = Self.responseBody
        let status = Self.responseStatus
        let mime = Self.responseMime
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
