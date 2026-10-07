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
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public static func makeRequest(_ request: MemoryRequest, configuration: ModelConfiguration, streaming: Bool) throws -> URLRequest {
        try configuration.validate()
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0.35,
            "stream": streaming,
            "response_format": ["type": "json_object"],
            "max_tokens": configuration.endpoint.host?.lowercased() == "api.deepseek.com" ? 16_384 : 8_192,
            "messages": [
                ["role": "system", "content": MemoryHarness.systemInstructions],
                ["role": "user", "content": MemoryHarness.userPrompt(request) + "\n\n" + MemoryResponseContract.instructions(for: request)]
            ]
        ]
        var result = URLRequest(url: configuration.endpoint)
        result.httpMethod = "POST"
        result.setValue("application/json", forHTTPHeaderField: "Content-Type")
        result.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        result.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        result.httpBody = try JSONSerialization.data(withJSONObject: body)
        result.timeoutInterval = 90
        return result
    }

    /// One model request streams the first usable clue, then validates the complete card.
    public func generateStreaming(
        _ request: MemoryRequest,
        configuration: ModelConfiguration,
        onQuickHint: @Sendable (QuickMemoryHint) async -> Void
    ) async throws -> MemoryCard {
        let urlRequest = try Self.makeRequest(request, configuration: configuration, streaming: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            bytes.task.cancel()
            throw MemoryHarnessError.requestFailed(status)
        }
        defer { bytes.task.cancel() }

        var accumulator = ChatCompletionStreamAccumulator()
        var decoder = ServerSentEventDecoder()
        var rawResponse = Data()
        var didEmitHint = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if rawResponse.count < 1_048_576 { rawResponse.append(byte) }
            if let event = decoder.append(byte) {
                try accumulator.append(event.data)
                if accumulator.isDone { break }
                if !didEmitHint,
                       let hint = MemoryHarness.quickHint(from: accumulator.content, expectedWord: request.word),
                       hint.anchor.kind == request.preferredAnchorKind {
                    didEmitHint = true
                    await onQuickHint(hint)
                }
            }
        }
        if !accumulator.isDone, let event = decoder.finish() {
            try accumulator.append(event.data)
        }
        try Task.checkCancellation()
        let isJSONEnvelope = rawResponse.first(where: { ![9, 10, 13, 32].contains($0) }) == 123
        let content = accumulator.content.isEmpty && isJSONEnvelope
            ? try ChatCompletionResponse.content(from: rawResponse)
            : try accumulator.completedContent()
        return try MemoryHarness.parse(content, expectedWord: request.word, requiredMeaningKey: request.focusMeaningKey, requiredAnchorKind: request.preferredAnchorKind)
    }

    public func generate(_ request: MemoryRequest, configuration: ModelConfiguration) async throws -> MemoryCard {
        let urlRequest = try Self.makeRequest(request, configuration: configuration, streaming: false)
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MemoryHarnessError.requestFailed(status) }
        let content = try ChatCompletionResponse.content(from: data)
        return try MemoryHarness.parse(content, expectedWord: request.word, requiredMeaningKey: request.focusMeaningKey, requiredAnchorKind: request.preferredAnchorKind)
    }
}
