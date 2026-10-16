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
        let wire = wireObject(word: word)
        PreviewResponse.response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(decoding: try! JSONSerialization.data(withJSONObject: wire), as: UTF8.self)], "finish_reason": "stop"]]])
        let model = CompanionViewModel(memoryStore: store,
            imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")),
            imageGenerator: PreviewImage(data: image(word: word)),
            modelClient: OpenAICompatibleClient(session: URLSession(configuration: configuration)),
            modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "offline-preview", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(checks.snapshot(word)); model.revealMemoryHelp()
        return model
    }

    /// Exercise the actual SSE client and view transitions without any provider calls.
    static func streamingModel(firstDelay: Double = 6, completionDelay: Double = 14) -> CompanionViewModel {
        let checks = CompanionLifecycleChecks()
        let directory = try! checks.temporaryDirectory()
        let wire = wireObject(word: "temporary")
        let firstKeys = ["word", "coreConcept", "anchor", "wordLink", "branches"]
        func fields(_ keys: [String]) -> String {
            keys.map { key in
                let value = try! JSONSerialization.data(withJSONObject: wire[key]!, options: [.fragmentsAllowed, .sortedKeys])
                return "\"\(key)\":" + String(decoding: value, as: UTF8.self)
            }.joined(separator: ",")
        }
        let prefix = "{" + fields(firstKeys)
        let suffix = "," + fields(wire.keys.filter { !firstKeys.contains($0) }.sorted()) + "}"
        PreviewStream.configure(prefix: prefix, suffix: suffix, firstDelay: firstDelay, completionDelay: completionDelay)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PreviewStream.self]
        let model = CompanionViewModel(memoryStore: MemoryStore(fileURL: directory.appendingPathComponent("memory.json")),
            imageStore: MemoryImageStore(directoryURL: directory.appendingPathComponent("images")),
            modelClient: OpenAICompatibleClient(session: URLSession(configuration: configuration)),
            modelConfiguration: ModelConfiguration(endpoint: URL(string: "https://unit.test/chat/completions")!, model: "offline-stream", apiKey: "fixture-only"), checkStoredKeys: false)
        model.applySnapshot(checks.snapshot("temporary"))
        return model
    }

    static var streamRequestCount: Int { PreviewStream.count }

    private static func wireObject(word: String) -> [String: Any] {
        var wire = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(sample(word: word))) as! [String: Any]
        if var anchor = wire["anchor"] as? [String: Any] {
            anchor.removeValue(forKey: "wordLink"); anchor.removeValue(forKey: "illustration"); wire["anchor"] = anchor
        }
        wire["caveat"] = NSNull()
        wire["analysis"] = ["surfaceWord": word, "lemma": NSNull(), "relations": ["none"], "core": word,
            "change": NSNull(), "explanation": "整词视觉助记；没有把字母图形当作真实词源。", "parts": [], "relatedWords": [],
            "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]
        return wire
    }

    static func sample(word: String, legacy: Bool = false) -> MemoryCard {
        if word == "president" { return presidentSample() }
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

    /// Reproduces the user's long layout example; linguistic claims remain explicitly unverified.
    static func presidentSample() -> MemoryCard {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(sample(word: "temporary"))) as! [String: Any]
        let cue = "president 的 pre（在前）＋ sid（坐）＋ ent（人）"
        let connection = "president 中的 pre 表示“在前”，sid 与 sit（坐）同源，-ent 表示“人”；合起来是“坐在前面的人”，即主持者、主席、总统。"
        let recall = "看到 president → 拆出 pre 在前、sid 坐、ent 人 → 坐在前面的人 → 主席／总统"
        object["word"] = "president"; object["coreConcept"] = "主持事务、处在领导位置的人；主席／总统"
        object["coreImage"] = "president 的完整字母组成会议席位，最前方的位置承担主持作用"
        object["anchor"] = ["kind": "morphology", "cue": cue, "explanation": connection, "imagePrompt": NSNull()]
        object["wordLink"] = ["source": "president", "cue": cue, "connection": connection, "recall": recall]
        object["illustration"] = ["scene": "president 的完整字母组成会议席位，最前方的位置承担主持作用",
            "mappings": [["source": "pre", "visual": "前方的字母形成主持席位", "meaning": "处在领导位置"]],
            "explanation": "pre 的字母形成前排主持席位，以视觉助记连接主席的含义。", "recall": recall]
        object["branches"] = [["partOfSpeech": "noun", "meaningKey": "leader", "chineseMeaning": "总统；主席",
            "context": "The president addressed the nation.", "signal": "The 后作主语，是身份名词", "explanation": "这句指向全国讲话的总统。"]]
        object["methods"] = [["id": "structure", "kind": "morphology", "title": "核心结构", "cue": cue,
            "whyItHelps": connection, "isLanguageFact": false]]
        object["transferCheck"] = ["sentence": "She became president of the club.", "targetBranch": "leader", "answer": "她成为俱乐部主席。", "clue": "of the club 限定了领导的组织"]
        object["caveat"] = "离线排版样例；上述构词内容复现模型回答，尚未词典核验。"
        object["analysis"] = ["surfaceWord": "president", "lemma": NSNull(), "relations": ["derivation"], "core": "sid", "change": NSNull(),
            "explanation": connection, "parts": [
                ["text": "pre", "start": 0, "end": 3, "kind": "prefix", "meaning": "在前", "relation": "derivation", "evidence": "modelUnverified"],
                ["text": "sid", "start": 3, "end": 6, "kind": "base", "meaning": "坐", "relation": "derivation", "evidence": "modelUnverified"],
                ["text": "ent", "start": 6, "end": 9, "kind": "suffix", "meaning": "表人", "relation": "derivation", "evidence": "modelUnverified"]],
            "relatedWords": [], "notSuitableReason": NSNull(), "alternativeSuggestion": NSNull()]
        return try! JSONDecoder().decode(MemoryCard.self, from: JSONSerialization.data(withJSONObject: object))
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

private final class PreviewStream: URLProtocol, @unchecked Sendable {
    private struct Stages: Sendable {
        let prefix: String, suffix: String
        let firstDelay: Double, completionDelay: Double
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stages = Stages(prefix: "", suffix: "", firstDelay: 0, completionDelay: 0)
    nonisolated(unsafe) private static var requests = 0
    private var work: Task<Void, Never>?
    static var count: Int { lock.withLock { requests } }
    static func configure(prefix: String, suffix: String, firstDelay: Double, completionDelay: Double) {
        lock.withLock {
            stages = Stages(prefix: prefix, suffix: suffix, firstDelay: firstDelay, completionDelay: completionDelay)
            requests = 0
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stages = Self.lock.withLock { Self.requests += 1; return Self.stages }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        work = Task { @Sendable [weak self] in
            do {
                try await Task.sleep(for: .seconds(stages.firstDelay))
                guard let self else { return }
                self.send(stages.prefix, finished: false)
                try await Task.sleep(for: .seconds(stages.completionDelay))
                try Task.checkCancellation()
                self.send(stages.suffix, finished: true)
                self.client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            } catch { /* URLSession owns cancellation; never deliver another stage. */ }
        }
    }
    private func send(_ text: String, finished: Bool) {
        let choice: [String: Any] = ["delta": ["content": text], "finish_reason": finished ? "stop" : NSNull()]
        let json = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        client?.urlProtocol(self, didLoad: Data("data: ".utf8) + json + Data("\n\n".utf8))
    }
    override func stopLoading() { work?.cancel() }
}
#endif
