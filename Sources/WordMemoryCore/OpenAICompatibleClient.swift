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
        return try MemoryHarness.parse(content, expectedWord: request.word, requiredMeaningKey: request.focusMeaningKey)
    }
}

private struct ChatCompletion: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
