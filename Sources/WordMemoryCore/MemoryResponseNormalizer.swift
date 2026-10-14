import Foundation

/// Repairs representation-only differences. Never completes learning text or changes evidence labels.
public enum MemoryResponseNormalizer {
    private static let affixMarkers: Set<Character> = ["-", "‐", "‑", "–", "—", "−"]
    public static func normalize(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MemoryHarnessError.invalidResponse("预期是单个 JSON 对象")
        }
        // Omitted nullable fields have exactly the same meaning as explicit null.
        for name in ["caveat"] where object[name] == nil { object[name] = NSNull() }
        if var anchor = object["anchor"] as? [String: Any], anchor["imagePrompt"] == nil,
           anchor["kind"] as? String != MemoryAnchorKind.letterIllustration.rawValue {
            anchor["imagePrompt"] = NSNull(); object["anchor"] = anchor
        }
        if var analysis = object["analysis"] as? [String: Any] {
            for name in ["lemma", "change", "notSuitableReason", "alternativeSuggestion"] where analysis[name] == nil {
                analysis[name] = NSNull()
            }
            if let word = object["word"] as? String, let parts = analysis["parts"] as? [[String: Any]] {
                let characters = Array(word)
                var offset = 0
                var normalized: [[String: Any]] = []
                for (index, var part) in parts.enumerated() {
                    guard let rawText = part["text"] as? String, !rawText.isEmpty else {
                        throw MemoryHarnessError.invalidResponse("analysis.parts[\(index)].text 缺失或为空")
                    }
                    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    var candidates = [rawText, trimmed]
                    // First prefer literal spelling, so real hyphens in words stay intact.
                    if part["kind"] as? String == WordPartKind.suffix.rawValue, let first = trimmed.first, affixMarkers.contains(first) {
                        candidates.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    if part["kind"] as? String == WordPartKind.prefix.rawValue, let last = trimmed.last, affixMarkers.contains(last) {
                        candidates.append(String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    guard let matched = candidates.first(where: { candidate in
                        let end = offset + candidate.count
                        return !candidate.isEmpty && end <= characters.count && String(characters[offset..<end]) == candidate
                    }) else {
                        throw MemoryHarnessError.invalidResponse("analysis.parts[\(index)].text 无法按顺序匹配原词拼写；未修改、补写或猜测字母")
                    }
                    part["text"] = matched
                    part["start"] = offset; offset += matched.count; part["end"] = offset
                    if part["meaning"] == nil { part["meaning"] = NSNull() }
                    normalized.append(part)
                }
                guard parts.isEmpty || offset == characters.count else {
                    throw MemoryHarnessError.invalidResponse("analysis.parts 拼接后没有覆盖完整原词；未补写缺失字母")
                }
                analysis["parts"] = normalized
            }
            object["analysis"] = analysis
        }
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// The wire no longer asks the model to count positions. Legacy integer offsets
    /// are ignored after exact ordered spelling coverage is verified locally.
    public static func wireObject(_ data: Data) throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MemoryHarnessError.invalidResponse("预期是单个 JSON 对象")
        }
        if var analysis = object["analysis"] as? [String: Any], var parts = analysis["parts"] as? [[String: Any]] {
            for index in parts.indices { parts[index].removeValue(forKey: "start"); parts[index].removeValue(forKey: "end") }
            analysis["parts"] = parts; object["analysis"] = analysis
        }
        return object
    }
}
