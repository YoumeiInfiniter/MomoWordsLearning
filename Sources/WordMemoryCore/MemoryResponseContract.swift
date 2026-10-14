import Foundation

/// The model's wire contract. Local history-only fields never belong in a model response.
public enum MemoryResponseContract {
    public static func validateStructure(_ raw: String, for request: MemoryRequest) throws {
        guard request.strategy != nil else { return }
        let data = try MemoryResponseNormalizer.normalize(normalizedData(from: raw))
        let value = try MemoryResponseNormalizer.wireObject(data)
        guard matchesStructure(value, schema: schema(for: request)) else {
            throw MemoryHarnessError.invalidResponse("必需内容字段、类型或数量不符合约定；未补写学习内容")
        }
    }
    public static func schema(for request: MemoryRequest) -> [String: Any] {
        let text: [String: Any] = ["type": "string", "minLength": 1]
        let nullable: [String: Any] = ["type": ["string", "null"]]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties,
             "required": properties.keys.sorted(), "additionalProperties": false]
        }
        func array(_ item: [String: Any], min: Int = 1, max: Int = 1) -> [String: Any] {
            ["type": "array", "items": item, "minItems": min, "maxItems": max]
        }
        let imagePrompt: [String: Any] = request.requiredAnchorKind == .letterIllustration ? text : ["type": "null"]
        var fields: [String: Any] = [
            "word": ["type": "string", "enum": [request.word]], "coreConcept": text,
            "anchor": object(["kind": ["type": "string", "enum": request.allowedAnchorKinds.map(\.rawValue)],
                              "cue": text, "explanation": text, "imagePrompt": imagePrompt]),
            "branches": array(object(["partOfSpeech": text, "meaningKey": text, "chineseMeaning": text,
                                      "context": text, "signal": text, "explanation": text]),
                              max: request.focusBranchID == nil ? 1 : max(1, request.existingCard?.branches.count ?? 1)),
            "coreImage": text,
            "methods": array(object(["id": text,
                "kind": ["type": "string", "enum": MemoryMethodKind.allCases.map(\.rawValue)],
                "title": text, "cue": text, "whyItHelps": text, "isLanguageFact": ["type": "boolean"]])),
            "transferCheck": object(["sentence": text, "targetBranch": text, "answer": text, "clue": text]),
            "caveat": nullable
        ]
        if request.strategy != nil {
            let relation: [String: Any] = ["type": "string", "enum": WordRelation.allCases.map(\.rawValue)]
            let evidence: [String: Any] = ["type": "string", "enum": ["modelUnverified", "mnemonic"]]
            fields["analysis"] = object([
                "surfaceWord": ["type": "string", "enum": [request.word]], "lemma": nullable,
                "relations": array(relation, max: 4), "core": text, "change": nullable, "explanation": text,
                "parts": array(object(["text": text,
                    "kind": ["type": "string", "enum": WordPartKind.allCases.map(\.rawValue)],
                    "meaning": nullable, "relation": relation, "evidence": evidence]), min: 0, max: 6),
                "relatedWords": array(object(["word": text, "partOfSpeech": text, "meaning": text,
                    "relation": relation, "evidence": ["type": "string", "enum": ["modelUnverified"]]]), min: 0, max: 3),
                "notSuitableReason": nullable, "alternativeSuggestion": nullable
            ])
        }
        return object(fields)
    }

    public static func instructions(for request: MemoryRequest) -> String {
        let kind = request.requiredAnchorKind ?? .context
        let meaningKey = request.focusMeaningKey ?? "meaning-1"
        var example: [String: Any] = [
            "word": request.word, "coreConcept": "简短核心关系",
            "anchor": ["kind": kind.rawValue, "cue": "简短主线索", "explanation": "线索如何连接意思",
                       "imagePrompt": kind == .letterIllustration ? "Create a letter-shaped illustration spelling exactly \(request.word)." as Any : NSNull()],
            "branches": [["partOfSpeech": request.existingCard?.branches.first(where: { $0.id == request.focusBranchID })?.partOfSpeech ?? "verb",
                          "meaningKey": meaningKey, "chineseMeaning": "当句意思", "context": "A short English sentence.",
                          "signal": "句法或搭配线索", "explanation": "解释当句用法"]],
            "coreImage": "简短建议画面",
            "methods": [["id": "m1", "kind": kind == .sound ? "sound" : "context", "title": "主线索",
                         "cue": "主线索", "whyItHelps": "关联理由", "isLanguageFact": false]],
            "transferCheck": ["sentence": "A different English sentence.", "targetBranch": meaningKey,
                              "answer": "当句意思", "clue": "判断线索"], "caveat": NSNull()
        ]
        if request.strategy != nil {
            example["analysis"] = ["surfaceWord": request.word, "lemma": NSNull(), "relations": ["none"],
                "core": "最有帮助的核心", "change": NSNull(), "explanation": "为什么采用本次方式；语言分析尚未经词典核验",
                "parts": [], "relatedWords": [], "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]
        }
        if request.strategy != nil, [.morphology, .familiarChunks, .hybrid, .wordForm].contains(kind) {
            var analysis = example["analysis"] as! [String: Any]
            analysis["notSuitableReason"] = "格式示例尚未分析这个词的可靠拆分；实际回答应分析后填写或如实说明不适合"
            analysis["alternativeSuggestion"] = "不适合时由用户另选方法"
            example["analysis"] = analysis
        }
        let schemaJSON = String(decoding: try! JSONSerialization.data(withJSONObject: schema(for: request), options: .sortedKeys), as: UTF8.self)
        let order = ["word", "coreConcept", "anchor", "branches", "coreImage", "methods", "transferCheck", "caveat", "analysis"]
        func json(_ value: Any) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
        }
        let exampleJSON = "{" + order.compactMap { name in example[name].map { json(name) + ":" + json($0) } }.joined(separator: ",") + "}"
        return """
        仅输出一个完整 JSON object，不输出 Markdown 或第二个 object。required 字段必须出现（包括值为 null 的字段），不输出 alternateAnchor、anchors 或本地历史字段。
        按 word、coreConcept、anchor、branches、coreImage、methods、transferCheck、caveat、analysis 的顺序输出，先完成首条线索。
        内容简短：一个主线索、一个重点语境、一个不同的新句；branches 与 methods 通常各一个元素。仅 focus_branch 保留其他旧分支原字段不变。严格保留重点词性和 meaningKey。
        cue、coreConcept、coreImage 各一句，explanation 一至两句，两个英文句子各不超过 20 词；methods 复用主线索。完整结束全部字段和括号。
        部件格式示例（仅示范格式，不声明本次词的词源）：neighbor + hood 时 parts=[{"text":"neighbor","kind":"base","meaning":"邻居","relation":"derivation","evidence":"modelUnverified"},{"text":"hood","kind":"suffix","meaning":"状态或范围","relation":"derivation","evidence":"modelUnverified"}]。个人拆分用 relation=mnemonicSplit 与 evidence=mnemonic；无含义字母 meaning=null。
        拆分最多六块，text 必须是原词连续片段，按原拼写顺序覆盖全词；不要输出 start/end，位置由本机计算。text 不写词缀记号连字符，例如 neighborhood 写 neighbor 和 hood，不写 -hood；unbelievable 写 un 和 believable，不写 un-。无需拆分时 parts=[]。只展示一层，相关词最多三个。真实分析 evidence=modelUnverified，个人拆分 evidence=mnemonic；不冒充已核验词源。
        JSON Schema：
        \(schemaJSON)
        合法结构示例（替换内容，保持本次允许类型；不适合指定方法时写明具体原因和替代建议，保持指定类型）：
        \(exampleJSON)
        """
    }

    /// Restores unambiguous syntax only. Closing delimiters can be recovered only after
    /// every required field and value is present; missing or partial content is never invented.
    public static func normalizedData(from raw: String) throws -> Data {
        let bytes = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard let start = bytes.firstIndex(of: 123) else {
            throw MemoryHarnessError.invalidResponse("没有返回 JSON 对象")
        }
        if bytes[..<start].last(where: { ![9, 10, 13, 32].contains($0) }) == 91 {
            throw MemoryHarnessError.invalidResponse("返回了数组，预期是单个 JSON 对象")
        }
        var depth = 0
        var inString = false
        var escaped = false
        var end: Int?
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        guard let end else {
            if let recovered = closingCompleteFields(bytes: Array(bytes[start...])) { return recovered }
            throw MemoryHarnessError.invalidResponse("JSON 对象未完整返回，无法安全补齐")
        }
        // Markdown or explanation is recoverable; a second answer is ambiguous.
        if bytes.dropFirst(end + 1).contains(123) {
            throw MemoryHarnessError.invalidResponse("返回了多个 JSON 对象")
        }
        var result: [UInt8] = []
        inString = false
        escaped = false
        for index in start...end {
            let byte = bytes[index]
            if !inString && byte == 44 {
                var next = index + 1
                while next <= end && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next <= end && (bytes[next] == 125 || bytes[next] == 93) { continue }
            }
            result.append(byte)
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
        }
        return Data(result)
    }

    private static func closingCompleteFields(bytes: [UInt8]) -> Data? {
        var closers: [UInt8] = []
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else {
                switch byte {
                case 34: inString = true
                case 123: closers.append(125)
                case 91: closers.append(93)
                case 125, 93:
                    guard closers.last == byte else { return nil }
                    closers.removeLast()
                default: break
                }
            }
        }
        guard !inString, !escaped, !closers.isEmpty,
              let last = bytes.last(where: { ![9, 10, 13, 32].contains($0) }),
              ![44, 58, 123, 91].contains(last) else { return nil }
        let data = Data(bytes + closers.reversed())
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let word = object["word"] as? String,
              let anchor = object["anchor"] as? [String: Any],
              let rawKind = anchor["kind"] as? String,
              let kind = MemoryAnchorKind(rawValue: rawKind) else { return nil }
        // Required learning content must already be complete. Only nullable omissions
        // and locally derivable positions may be normalized before closure recovery.
        guard let normalized = try? MemoryResponseNormalizer.normalize(data),
              let wire = try? MemoryResponseNormalizer.wireObject(normalized) else { return nil }
        let request = MemoryRequest(word: word, preferredAnchorKind: kind, strategy: object["analysis"] == nil ? nil : .auto)
        var recoveredSchema = schema(for: request)
        if object["analysis"] != nil, var properties = recoveredSchema["properties"] as? [String: Any],
           var branches = properties["branches"] as? [String: Any], let count = (object["branches"] as? [Any])?.count {
            // The actual request validates focus-branch count after recovery.
            branches["maxItems"] = max(1, count); properties["branches"] = branches; recoveredSchema["properties"] = properties
        }
        guard matchesStructure(wire, schema: recoveredSchema) else { return nil }
        return data
    }

    /// Required nullable fields must also be present. Codable's backwards-compatible
    /// optional defaults alone are not sufficient evidence of a complete wire response.
    private static func matchesStructure(_ value: Any, schema: [String: Any]) -> Bool {
        if value is NSNull {
            return schema["type"] as? String == "null" || (schema["type"] as? [String])?.contains("null") == true
        }
        if let fields = schema["properties"] as? [String: [String: Any]] {
            guard let object = value as? [String: Any],
                  Set(object.keys) == Set(fields.keys) else { return false }
            return fields.allSatisfy { key, field in
                guard let child = object[key] else { return false }
                return matchesStructure(child, schema: field)
            }
        }
        if let item = schema["items"] as? [String: Any] {
            guard let array = value as? [Any], array.count >= (schema["minItems"] as? Int ?? 0),
                  array.count <= (schema["maxItems"] as? Int ?? Int.max) else { return false }
            return array.allSatisfy { matchesStructure($0, schema: item) }
        }
        if schema["type"] as? String == "boolean" {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        if schema["type"] as? String == "integer" {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue else { return false }
            return number.intValue >= (schema["minimum"] as? Int ?? Int.min)
        }
        guard let string = value as? String else { return false }
        if let values = schema["enum"] as? [String], !values.contains(string) { return false }
        return schema["minLength"] == nil || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
