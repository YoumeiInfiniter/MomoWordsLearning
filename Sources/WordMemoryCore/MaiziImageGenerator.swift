import Foundation
import Security

public enum MaiziImageError: LocalizedError {
    case notConfigured
    case requestFailed(Int)
    case downloadFailed(Int)
    case invalidResponse
    case unsafeImageURL
    case imageTooLarge
    case remoteFailed
    case unsupportedAsync(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "请先在设置中保存图片生成 API Key"
        case .requestFailed(let status): "图片生成请求失败（HTTP \(status)）"
        case .downloadFailed(let status): "生成图片下载失败（HTTP \(status)）"
        case .invalidResponse: "图片服务没有返回可用的 URL 或 base64 图片"
        case .unsafeImageURL: "图片服务返回了不安全的图片地址"
        case .imageTooLarge: "图片服务返回的数据超过 20 MB"
        case .remoteFailed: "图片服务报告生成失败；未自动重复提交"
        case .unsupportedAsync: "服务返回了异步任务 ID，但查询协议尚未核验；结果待确认，不会自动重新生成"
        }
    }

    public var taskFailure: ImageTaskFailure {
        let phase: String
        let kind: String
        switch self {
        case .notConfigured: phase = "submitting"; kind = "authentication"
        case .requestFailed(let status): phase = "submitting"; kind = status == 401 || status == 403 ? "authentication" : "rejected"
        case .downloadFailed: phase = "downloading"; kind = "download"
        case .invalidResponse, .unsafeImageURL, .imageTooLarge: phase = "response"; kind = "unsupported_format"
        case .remoteFailed: phase = "generating"; kind = "remote_failure"
        case .unsupportedAsync: phase = "response"; kind = "unsupported_async"
        }
        return ImageTaskFailure(phase: phase, kind: kind, message: localizedDescription)
    }
}

public enum MaiziImageResult: Equatable, Sendable {
    case url(URL)
    case imageData(Data)
}

/// The v2 endpoint is documented to return either a URL or base64 data.
public enum MaiziImageResponseParser {
    public static func parse(_ data: Data) throws -> MaiziImageResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaiziImageError.invalidResponse
        }
        let item = (root["data"] as? [[String: Any]])?.first ?? root
        if (root["error"] != nil && !(root["error"] is NSNull)) || root["success"] as? Bool == false || root["status"] as? String == "failed" {
            throw MaiziImageError.remoteFailed
        }
        if let encoded = item["b64_json"] as? String ?? item["base64"] as? String {
            let value = encoded.components(separatedBy: "base64,").last ?? encoded
            guard let image = Data(base64Encoded: value), !image.isEmpty else {
                throw MaiziImageError.invalidResponse
            }
            guard image.count <= 20 * 1_024 * 1_024 else { throw MaiziImageError.imageTooLarge }
            return .imageData(image)
        }
        if let urlString = item["url"] as? String,
           let url = URL(string: urlString) {
            guard url.scheme?.lowercased() == "https", url.host != nil else {
                throw MaiziImageError.unsafeImageURL
            }
            return .url(url)
        }
        if let taskID = item["task_id"] as? String ?? root["task_id"] as? String, !taskID.isEmpty { throw MaiziImageError.unsupportedAsync(String(taskID.prefix(256))) }
        throw MaiziImageError.invalidResponse
    }
}

public enum ImageSecretStore {
    private static let service = "local.maimemo.companion.image"
    private static let account = "api-key"

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

public struct MaiziImageGenerator: StagedMemoryImageGenerator {
    private static let endpoint = URL(string: "https://www.maizitech.ai/v2/images/generations")!
    private static let maximumImageBytes = 20 * 1_024 * 1_024
    private let session: URLSession
    private let apiKeyProvider: @Sendable () async -> String?

    public init(session: URLSession = .shared, apiKeyProvider: @escaping @Sendable () async -> String? = {
        await Task.detached(priority: .userInitiated) { ImageSecretStore.load() }.value
    }) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    public func generateImage(prompt: String) async throws -> Data {
        switch try await submitImage(prompt: prompt) {
        case .imageData(let data): return data
        case .url(let url): return try await downloadImage(from: url)
        }
    }

    public func submitImage(prompt: String) async throws -> MaiziImageResult {
        let key = await apiKeyProvider()
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaiziImageError.notConfigured
        }
        let body: [String: Any] = [
            "model": "gpt-image-2.5",
            "prompt": prompt,
            "size": "1:1",
            "resolution": "1K",
            "n": 1
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MaiziImageError.requestFailed(status) }
        guard data.count <= 28 * 1_024 * 1_024 else { throw MaiziImageError.imageTooLarge }
        return try MaiziImageResponseParser.parse(data)
    }

    public func downloadImage(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw MaiziImageError.unsafeImageURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MaiziImageError.downloadFailed(status) }
        guard response.url?.scheme?.lowercased() == "https" else { throw MaiziImageError.unsafeImageURL }
        var image = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard image.count < Self.maximumImageBytes else { throw MaiziImageError.imageTooLarge }
            image.append(byte)
        }
        guard !image.isEmpty else { throw MaiziImageError.invalidResponse }
        return image
    }
}
