#if DEBUG
import AppKit
import Foundation
import WordMemoryCore

/// Isolated layout fixtures. Both the answer and the image are local, never a paid generation.
@MainActor
enum LearningPreview {
    static func model(word: String = "temporary", legacy: Bool = false) -> CompanionViewModel {
        let checks = CompanionLifecycleChecks()
        let directory = try! checks.temporaryDirectory()
        let card = sample(word: word, legacy: legacy)
        let store = MemoryStore(fileURL: directory.appendingPathComponent("memory.json"))
        try! store.save(card)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PreviewResponse.self]
        var wire = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(sample(word: word))) as! [String: Any]
        if var anchor = wire["anchor"] as? [String: Any] {
            anchor.removeValue(forKey: "wordLink"); anchor.removeValue(forKey: "illustration"); wire["anchor"] = anchor
        }
        wire["caveat"] = NSNull()
        wire["analysis"] = ["surfaceWord": word, "lemma": NSNull(), "relations": ["none"], "core": word,
            "change": NSNull(), "explanation": "整词视觉助记；没有把字母图形当作真实词源。", "parts": [], "relatedWords": [],
            "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]
        PreviewResponse.response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(decoding: try! JSONSerialization.data(withJSONObject: wire), as: UTF8.self)], "finish_reason": "stop"]]])
        let model = CompanionViewModel(memoryStore: store,
            imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")),
            imageGenerator: PreviewImage(data: image(word: word)),
            modelClient: OpenAICompatibleClient(session: URLSession(configuration: configuration)),
            modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "offline-preview", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(checks.snapshot(word)); model.revealMemoryHelp()
        return model
    }

    static func sample(word: String, legacy: Bool = false) -> MemoryCard {
        let temporary = word == "temporary"
        let meaning = temporary ? "在有限时间内有效，之后撤下或替换" : "用标准比出大小、程度或价值"
        let cue = temporary ? "temporary 的字母搭成一块可撤走的标牌" : "measure 的整词字母排成一把量尺"
        let connection = temporary
            ? "让 temporary 的整词字形成为可拆结构：标牌只在倒计时内保留，到点撤下，联到“暂时的”。这是个人视觉助记。"
            : "把 measure 的完整字形当量尺，m 做支架，字母间距形成刻度；先量长度，再想到用标准衡量价值。这是个人视觉助记。"
        let recall = temporary ? "temporary → 可撤走的字母标牌 → 暂时的" : "measure → 字母量尺 → 测量／衡量"
        let mapping = MemoryVisualMapping(source: word,
            visual: temporary ? "完整字母本身拼成可拆标牌，末端逐渐松开" : "全部字母按拼写顺序构成量尺的尺身与刻度",
            meaning: temporary ? "倒计时结束后拆下，表示只暂时有效" : "把对象与刻度比较，表示测量与衡量")
        return MemoryCard(word: word, coreConcept: meaning, coreImage: cue,
            branches: [MeaningBranch(partOfSpeech: temporary ? "adjective" : "verb", meaningKey: "core",
                chineseMeaning: temporary ? "临时的；暂时的" : "衡量；判断",
                context: temporary ? "This is only a temporary solution." : "It is hard to measure the true value of friendship.",
                signal: temporary ? "temporary 修饰 solution" : "to measure 后接所衡量的价值",
                explanation: temporary ? "这个办法只在一段时间内采用，之后会被替换。" : "用抽象的标准衡量友情的价值，沿用“用标准比较”的核心关系。")],
            methods: [MemoryMethod(id: "visual", kind: .image, title: "整词视觉助记", cue: cue, whyItHelps: connection, isLanguageFact: false)],
            transferCheck: TransferCheck(sentence: temporary ? "She found a temporary job." : "How do you measure success?", targetBranch: "core",
                answer: temporary ? "她找到了一份临时工作。" : "你怎样衡量成功？", clue: temporary ? "工作只持续有限时间" : "用什么标准作比较"),
            caveat: "离线排版样例；图像由本机绘制，未调用模型或生图服务。",
            anchor: MemoryAnchor(kind: .context, cue: cue, explanation: connection),
            wordLink: legacy ? nil : MemoryWordLink(source: word, cue: cue, connection: connection, recall: recall),
            illustration: legacy ? nil : MemoryIllustrationPlan(scene: cue + "，字母本身承担物体与动作。", mappings: [mapping],
                explanation: temporary ? "temporary 的全部字母组成标牌，字母可拆的结构配合撤下动作，连接暂时有效的意思。" : "measure 的字母本身就是量尺，字母的间距成为比较用的刻度，连接测量与衡量的意思。", recall: recall))
    }

    static func image(word: String) -> Data {
        let size = NSSize(width: 840, height: 560)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.26, alpha: 1).setStroke()
        if word == "temporary" {
            let thread = NSBezierPath(); thread.move(to: NSPoint(x: 175, y: 410)); thread.line(to: NSPoint(x: 175, y: 480));
            thread.move(to: NSPoint(x: 675, y: 410)); thread.line(to: NSPoint(x: 675, y: 480)); thread.lineWidth = 3; thread.stroke()
        }
        let base = NSBezierPath(); base.move(to: NSPoint(x: 80, y: 225)); base.line(to: NSPoint(x: 760, y: 225)); base.lineWidth = 3; base.stroke()
        let font = NSFont(name: "Georgia", size: word == "measure" ? 111 : 94) ?? .systemFont(ofSize: 94)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.26, alpha: 1)]
        let text = NSAttributedString(string: word, attributes: attributes)
        text.draw(at: NSPoint(x: (size.width - text.size().width) / 2, y: 237))
        if word == "measure" {
            for step in 0...20 {
                let x = CGFloat(80 + step * 34)
                let tick = NSBezierPath(); tick.move(to: NSPoint(x: x, y: 225)); tick.line(to: NSPoint(x: x, y: step % 5 == 0 ? 185 : 205)); tick.lineWidth = 2; tick.stroke()
            }
        } else {
            let circle = NSBezierPath(ovalIn: NSRect(x: 377, y: 89, width: 86, height: 86)); circle.lineWidth = 3; circle.stroke()
            let hands = NSBezierPath(); hands.move(to: NSPoint(x: 420, y: 156)); hands.line(to: NSPoint(x: 420, y: 132)); hands.line(to: NSPoint(x: 439, y: 118)); hands.lineWidth = 3; hands.stroke()
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}

private struct PreviewImage: MemoryImageGenerator {
    let data: Data
    func generateImage(prompt: String) async throws -> Data {
        try await Task.sleep(for: .milliseconds(550))
        return data
    }
}
private final class PreviewResponse: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
