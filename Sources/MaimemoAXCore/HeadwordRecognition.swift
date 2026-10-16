import Foundation

/// Pure candidate rules shared by the live AX scanner and offline regressions.
/// A phrase is accepted only in the prominent heading region, never from an example.
public enum MaimemoHeadwordRecognizer {
    private static let excluded: Set<String> = [
        "back", "cancel", "close", "confirm", "continue", "delete", "done", "edit",
        "enter", "exit", "finish", "forward", "history", "home", "more", "next",
        "no", "pause", "play", "previous", "reset", "review", "save", "search",
        "settings", "skip", "start", "stop", "submit", "today", "yes",
        "phraseannotationall", "morelines", "leftarrow", "moredots", "markwf", "unpin",
        "lookup dark", "bing dark", "collins dark", "cambridge dark", "cambridge eng dark"
    ]

    public static func candidate(text: String, role: String, sourceAttribute: String,
                                 frame: CGRect?, sequence: Int, windowFrame: CGRect?) -> AXTextCandidate? {
        guard ["AXStaticText", "AXHeading", "AXButton"].contains(role),
              ["AXTitle", "AXValue", "AXDescription"].contains(sourceAttribute),
              let normalized = normalized(text), !excluded.contains(normalized) else { return nil }
        let isHeading = headingFrame(frame, in: windowFrame)
        // Maimemo exposes its tappable headword as an AXButton description.
        // Other buttons are controls, even when their internal asset name is English.
        guard role != "AXButton" || isHeading else { return nil }
        if normalized.contains(" ") {
            guard isHeading, let frame, frame.width >= 80 else { return nil }
        }
        var score = 25.0
        if role == "AXStaticText" { score += 45 }
        if role == "AXHeading" { score += 30 }
        if sourceAttribute == "AXValue" { score += 8 }
        if isHeading { score += 60 }
        if let frame {
            score += min(frame.height, 80) * 1.6 + min(frame.width, 300) * 0.04
            if let windowFrame, frame.midY - windowFrame.minY < windowFrame.height * 0.42 { score += 35 }
        }
        score -= Double(sequence) * 0.012
        return AXTextCandidate(text: normalized, role: role, sourceAttribute: sourceAttribute,
                               score: score, frame: frame ?? .zero)
    }

    public static func ranked(_ candidates: [AXTextCandidate]) -> [AXTextCandidate] {
        // Keep the strongest occurrence instead of letting an earlier small label
        // suppress the actual heading with the same spelling.
        let best = candidates.reduce(into: [String: AXTextCandidate]()) { result, candidate in
            if candidate.score > (result[candidate.text]?.score ?? -.infinity) { result[candidate.text] = candidate }
        }
        return Array(best.values.sorted {
            $0.score == $1.score ? $0.text < $1.text : $0.score > $1.score
        }.prefix(8))
    }

    private static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isNewline }) else { return nil }
        let value = trimmed.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        guard (2...100).contains(value.count) else { return nil }
        let tokens = value.split(separator: " ")
        guard tokens.count <= 10,
              tokens.allSatisfy({ $0.range(of: "^[a-z]+(?:[-'][a-z]+)*(?:\\.)?$", options: .regularExpression) != nil }) else { return nil }
        if tokens.count == 1 {
            guard value.count <= 40, !value.hasSuffix(".") else { return nil }
        }
        return value
    }

    private static func headingFrame(_ frame: CGRect?, in window: CGRect?) -> Bool {
        guard let frame, let window, window.width > 0, window.height > 0,
              frame.width >= 20, frame.height >= 24, frame.height <= 120,
              frame.minY >= window.minY, frame.maxY <= window.maxY,
              frame.midY - window.minY < window.height * 0.34,
              abs(frame.midX - window.midX) < window.width * 0.3 else { return false }
        return true
    }
}
