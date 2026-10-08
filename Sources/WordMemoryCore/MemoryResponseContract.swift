import Foundation

/// The model's wire contract. Local history-only fields never belong in a model response.
public enum MemoryResponseContract {
    public static func schema(for request: MemoryRequest) -> [String: Any] {
        let text: [String: Any] = ["type": "string", "minLength": 1]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties,
             "required": properties.keys.sorted(), "additionalProperties": false]
        }
        func array(_ item: [String: Any]) -> [String: Any] {
            ["type": "array", "items": item, "minItems": 1, "maxItems": 1]
        }
        let imagePrompt: [String: Any] = request.preferredAnchorKind == .sound
            ? ["type": "null"] : text
        return object([
            "word": ["type": "string", "enum": [request.word]],
            "coreConcept": text,
            "anchor": object([
                "kind": ["type": "string", "enum": [request.preferredAnchorKind.rawValue]],
                "cue": text, "explanation": text, "imagePrompt": imagePrompt
            ]),
            "branches": array(object([
                "partOfSpeech": text, "meaningKey": text, "chineseMeaning": text,
                "context": text, "signal": text, "explanation": text
            ])),
            "coreImage": text,
            "methods": array(object([
                "id": text,
                "kind": ["type": "string", "enum": MemoryMethodKind.allCases.map(\.rawValue)],
                "title": text, "cue": text, "whyItHelps": text,
                "isLanguageFact": ["type": "boolean"]
            ])),
            "transferCheck": object([
                "sentence": text, "targetBranch": text, "answer": text, "clue": text
            ]),
            "caveat": ["type": ["string", "null"]]
        ])
    }

    public static func instructions(for request: MemoryRequest) -> String {
        func quoted(_ value: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
        }
        let meaningKey = quoted(request.focusMeaningKey ?? "meaning-1")
        let imagePrompt = request.preferredAnchorKind == .sound
            ? "null" : quoted("Create a letter-shaped illustration of \(request.word), spelling exactly \(request.word). Describe the semantic scene here.")
        let schemaJSON = String(decoding: try! JSONSerialization.data(withJSONObject: schema(for: request), options: .sortedKeys), as: UTF8.self)
        return """
        输出契约：仅输出一个完整 JSON object，不能输出 Markdown、前后说明或第二个 object。
        字段名区分大小写，所有 required 字段都必须出现；不要输出 alternateAnchor。字符串中的双引号、反斜杠和换行必须按 JSON 转义，不能使用单引号或尾逗号。
        按 word、coreConcept、anchor、branches、coreImage、methods、transferCheck、caveat 的顺序输出。内容简短：一个主联想、一个重点情境、一个不同的新句；已有义项键按要求保留。transferCheck.targetBranch 必须等于 branches 中的一个 meaningKey。
        branches 与 methods 各只输出一个元素。cue 用一句短句，explanation 用一至两句；coreConcept 与 coreImage 各一句。methods 复用主联想，不扩写另一套记法；两个英文句子各不超过 20 个词，signal、answer、clue 各一句。不要重复解释、列词典义项或在末尾继续追加内容；必须写完所有字段并关闭 JSON。
        JSON Schema（描述字段约束，不要把 Schema 当作答案）：
        \(schemaJSON)
        本次合法 JSON 结构示例（示例文字需替换成实际学习内容，kind 与 word 保持本次指定值）：
        {"word":\(quoted(request.word)),"coreConcept":"简短核心关系","anchor":{"kind":\(quoted(request.preferredAnchorKind.rawValue)),"cue":"简短主联想","explanation":"词与核心意思的关联","imagePrompt":\(imagePrompt)},"branches":[{"partOfSpeech":"verb","meaningKey":\(meaningKey),"chineseMeaning":"当句意思","context":"A short English sentence.","signal":"句中判断线索","explanation":"核心关系如何落地"}],"coreImage":"简短联想画面","methods":[{"id":"m1","kind":\(quoted(request.preferredAnchorKind == .sound ? "sound" : "image")),"title":"主联想","cue":"具体记忆钩子","whyItHelps":"关联理由","isLanguageFact":false}],"transferCheck":{"sentence":"A different English sentence.","targetBranch":\(meaningKey),"answer":"当句意思","clue":"判断线索"},"caveat":null}
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
              let kind = MemoryAnchorKind(rawValue: rawKind),
              matchesStructure(object, schema: schema(for: MemoryRequest(word: word, preferredAnchorKind: kind))) else { return nil }
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
            guard let array = value as? [Any], !array.isEmpty else { return false }
            return array.allSatisfy { matchesStructure($0, schema: item) }
        }
        if schema["type"] as? String == "boolean" {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        guard let string = value as? String else { return false }
        if let values = schema["enum"] as? [String], !values.contains(string) { return false }
        return schema["minLength"] == nil || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
