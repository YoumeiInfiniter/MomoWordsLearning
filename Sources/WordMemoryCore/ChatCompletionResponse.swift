import Foundation

/// Collects only answer text, ignoring reasoning, role and usage-only stream chunks.
public struct ChatCompletionStreamAccumulator: Sendable {
    public private(set) var content = ""
    public private(set) var isDone = false
    private var finishReason: String?
    private var wasRefused = false

    public init() {}

    public mutating func append(_ payload: String) throws {
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { isDone = true; return }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data), chunk.error == nil, chunk.choices != nil else {
            throw MemoryHarnessError.invalidResponse("接口返回了无效的流式消息或服务错误")
        }
        guard let choice = chunk.choices?.first(where: { $0.index == 0 }) ?? chunk.choices?.first else { return }
        if let text = choice.delta?.content { content += text }
        guard content.utf8.count <= 1_048_576 else {
            throw MemoryHarnessError.invalidResponse("模型响应异常过长")
        }
        if choice.delta?.refusal != nil { wasRefused = true }
        if let reason = choice.finish_reason { finishReason = reason }
    }

    public func completedContent() throws -> String {
        try ChatCompletionResponse.validateFinish(finishReason, refused: wasRefused)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryHarnessError.invalidResponse("模型没有返回学习内容")
        }
        return content
    }
}

public enum ChatCompletionResponse {
    public static func content(from data: Data) throws -> String {
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let choice = completion.choices.first(where: { $0.index == 0 }) ?? completion.choices.first else {
            throw MemoryHarnessError.invalidResponse("接口没有返回兼容的聊天补全结果")
        }
        try validateFinish(choice.finish_reason, refused: choice.message.refusal != nil)
        guard let content = choice.message.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryHarnessError.invalidResponse("模型没有返回学习内容")
        }
        return content
    }

    fileprivate static func validateFinish(_ reason: String?, refused: Bool) throws {
        if refused || reason == "content_filter" {
            throw MemoryHarnessError.invalidResponse("模型未提供可用的学习内容")
        }
        switch reason {
        case "length": throw MemoryHarnessError.invalidResponse("模型输出达到长度上限，内容被截断；未自动重试")
        case "aborted", "insufficient_system_resource":
            throw MemoryHarnessError.invalidResponse("模型服务中断了生成；未自动重试")
        case "tool_calls": throw MemoryHarnessError.invalidResponse("模型返回了工具调用，预期是 JSON 记忆卡")
        default: break
        }
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String?; let refusal: String? }
        let index: Int?
        let delta: Delta?
        let finish_reason: String?
    }
    struct ServiceError: Decodable { let message: String? }
    let choices: [Choice]?
    let error: ServiceError?
}

private struct Completion: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String?; let refusal: String? }
        let index: Int?
        let finish_reason: String?
        let message: Message
    }
    let choices: [Choice]
}
