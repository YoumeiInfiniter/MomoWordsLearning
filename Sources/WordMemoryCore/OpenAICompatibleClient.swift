import Foundation
import Security

public struct ModelConfiguration: Sendable {
    public let endpoint: URL
    public let model: String
    public let apiKey: String

    public init(endpoint: URL, model: String, apiKey: String) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
    }

    public func validate() throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryHarnessError.notConfigured
        }
        let host = endpoint.host?.lowercased() ?? ""
        guard !host.isEmpty,
              endpoint.scheme == "https" || (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw MemoryHarnessError.unsafeEndpoint
        }
    }
}

public enum ModelSecretStore {
    private static let service = "local.maimemo.companion.model"
    private static let account = "api-key"

    /// Read only item metadata; never decrypt the saved key just to draw settings UI.
    public static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public static func save(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct OpenAICompatibleClient: Sendable {
    public init() {}

    /// One model request streams the first usable clue, then validates the complete card.
    public func generateStreaming(
        _ request: MemoryRequest,
        configuration: ModelConfiguration,
        onQuickHint: @Sendable (QuickMemoryHint) async -> Void
    ) async throws -> MemoryCard {
        try configuration.validate()
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.35,
            "stream": true,
            "messages": [
                ["role": "system", "content": MemoryHarness.systemInstructions],
                ["role": "user", "content": MemoryHarness.userPrompt(request)]
            ]
        ]
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 90

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            bytes.task.cancel()
            throw MemoryHarnessError.requestFailed(status)
        }
        defer { bytes.task.cancel() }

        var content = ""
        var decoder = ServerSentEventDecoder()
        var rawResponse = Data()
        var didEmitHint = false
        var reachedDone = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if rawResponse.count < 1_048_576 { rawResponse.append(byte) }
            if let event = decoder.append(byte) {
                if event.data == "[DONE]" { reachedDone = true; break }
                if let delta = try Self.streamContent(from: event.data) {
                    content += delta
                    if !didEmitHint,
                       let hint = MemoryHarness.quickHint(from: content, expectedWord: request.word),
                       hint.anchor.kind == request.preferredAnchorKind {
                        didEmitHint = true
                        await onQuickHint(hint)
                    }
                }
            }
        }
        if !reachedDone, let event = decoder.finish(), event.data != "[DONE]" {
            if let delta = try Self.streamContent(from: event.data) {
                content += delta
            }
        }
        try Task.checkCancellation()
        if content.isEmpty,
           let completion = try? JSONDecoder().decode(ChatCompletion.self, from: rawResponse),
           let fallbackContent = completion.choices.first?.message.content {
            content = fallbackContent
        }
        guard !content.isEmpty else { throw MemoryHarnessError.invalidResponse("模型未返回流式文本") }
        return try MemoryHarness.parse(content, expectedWord: request.word, requiredMeaningKey: request.focusMeaningKey, requiredAnchorKind: request.preferredAnchorKind)
    }

    private static func streamContent(from payload: String) throws -> String? {
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
            throw MemoryHarnessError.invalidResponse("流式响应不是兼容的聊天补全格式")
        }
        return chunk.choices.first?.delta.content
    }

    public func generate(_ request: MemoryRequest, configuration: ModelConfiguration) async throws -> MemoryCard {
        try configuration.validate()
        let messages: [[String: String]] = [
            ["role": "system", "content": MemoryHarness.systemInstructions],
            ["role": "user", "content": MemoryHarness.userPrompt(request)]
        ]
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.35,
            "messages": messages
        ]
        var urlRequest = URLRequest(url: configuration.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MemoryHarnessError.requestFailed(status) }
        let completion = try JSONDecoder().decode(ChatCompletion.self, from: data)
        guard let content = completion.choices.first?.message.content else {
            throw MemoryHarnessError.invalidResponse("模型未返回文本")
        }
        return try MemoryHarness.parse(content, expectedWord: request.word, requiredMeaningKey: request.focusMeaningKey, requiredAnchorKind: request.preferredAnchorKind)
    }
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}

private struct ChatCompletion: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
