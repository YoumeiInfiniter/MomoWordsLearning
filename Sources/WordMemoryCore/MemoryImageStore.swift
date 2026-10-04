import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol MemoryImageGenerator: Sendable {
    /// Provider-specific adapters return image bytes; credentials stay outside prompts and saved cards.
    func generateImage(prompt: String) async throws -> Data
}

public struct MemoryImageStore: Sendable {
    public enum ImageError: LocalizedError {
        case invalidImage
        case imageTooLarge

        public var errorDescription: String? {
            switch self {
            case .invalidImage: "图片服务没有返回可读取的图片"
            case .imageTooLarge: "图片超过本地保存上限（20 MB）"
            }
        }
    }

    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directoryURL = directoryURL ?? base
            .appendingPathComponent("MaimemoCompanion", isDirectory: true)
            .appendingPathComponent("memory-images", isDirectory: true)
    }

    public func imageURL(for word: String, prompt: String) -> URL? {
        let url = fileURL(for: word, prompt: prompt)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func save(_ imageData: Data, for word: String, prompt: String) throws -> URL {
        guard imageData.count <= 20 * 1_024 * 1_024 else { throw ImageError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4_096, height <= 4_096,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageError.invalidImage
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.invalidImage }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = fileURL(for: word, prompt: prompt)
        try (png as Data).write(to: url, options: .atomic)
        return url
    }

    private func fileURL(for word: String, prompt: String) -> URL {
        let identity = Data((word.lowercased() + "\n" + prompt).utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(digest + ".png")
    }
}
