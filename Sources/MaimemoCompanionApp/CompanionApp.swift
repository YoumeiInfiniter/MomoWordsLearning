import AppKit
import SwiftUI
import MaimemoAXCore
import WordMemoryCore

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published private(set) var snapshot: MaimemoAXSnapshot
    @Published private(set) var lastChangeAt: Date?
    @Published private(set) var memoryCard: MemoryCard?
    @Published private(set) var selectedBranchID: String?
    @Published private(set) var isGenerating = false
    @Published var memoryError: String?
    @Published var learnerNote = ""
    @Published var selectedMethodKind: MemoryMethodKind? = nil
    @Published var showAnswer = false
    @Published var showModelSettings = false
    @Published var endpointText: String
    @Published var modelText: String
    @Published var enteredAPIKey = ""
    @Published private(set) var hasStoredAPIKey: Bool

    let reader: MaimemoAccessibilityReader
    let memoryStore: MemoryStore
    private var previousWord: String?
    private let modelClient = OpenAICompatibleClient()

    init(reader: MaimemoAccessibilityReader = MaimemoAccessibilityReader(), memoryStore: MemoryStore = MemoryStore()) {
        self.reader = reader
        self.memoryStore = memoryStore
        self.endpointText = UserDefaults.standard.string(forKey: "memory.model.endpoint") ?? ""
        self.modelText = UserDefaults.standard.string(forKey: "memory.model.name") ?? ""
        self.hasStoredAPIKey = ModelSecretStore.load() != nil
        self.memoryError = memoryStore.loadWarning
        self.snapshot = MaimemoAXSnapshot(
            appFound: false,
            appName: "墨墨",
            isTrusted: AXIsProcessTrusted(),
            word: nil,
            windowFrame: nil,
            nodeCount: 0,
            candidates: [],
            scannedAt: Date(),
            diagnostic: "正在连接墨墨…"
        )
    }

    func refresh() {
        let next = reader.scan()
        if next.word != previousWord, next.word != nil {
            lastChangeAt = Date()
            if let word = next.word {
                memoryCard = memoryStore.card(for: word)
                selectedBranchID = memoryCard?.branches.first?.id
                showAnswer = false
                learnerNote = ""
                if memoryCard != nil {
                    do { try memoryStore.recordEncounter(word: word) }
                    catch { memoryError = "本地记录更新失败：\(error.localizedDescription)" }
                }
            }
        } else if next.word == nil, previousWord != nil {
            memoryCard = nil
            selectedBranchID = nil
        }
        previousWord = next.word
        snapshot = next
    }

    var selectedBranch: MeaningBranch? {
        memoryCard?.branches.first(where: { $0.id == selectedBranchID }) ?? memoryCard?.branches.first
    }

    var branchHistory: BranchMemory? {
        guard let branch = selectedBranch, let word = snapshot.word else { return nil }
        return memoryStore.branch(for: word, partOfSpeech: branch.partOfSpeech, meaningKey: branch.meaningKey)
    }

    var modelIsConfigured: Bool {
        !endpointText.isEmpty && !modelText.isEmpty && hasStoredAPIKey
    }

    func saveModelSettings() {
        let endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), !model.isEmpty else {
            memoryError = "请填写完整的模型地址与名称"
            return
        }
        let host = url.host?.lowercased() ?? ""
        guard !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            memoryError = MemoryHarnessError.unsafeEndpoint.localizedDescription
            return
        }
        do {
            if !enteredAPIKey.isEmpty {
                try ModelSecretStore.save(enteredAPIKey)
                hasStoredAPIKey = true
                enteredAPIKey = ""
            }
            endpointText = endpoint
            modelText = model
            UserDefaults.standard.set(endpoint, forKey: "memory.model.endpoint")
            UserDefaults.standard.set(model, forKey: "memory.model.name")
            memoryError = nil
            showModelSettings = false
        } catch {
            memoryError = "API Key 无法保存到钥匙串：\(error.localizedDescription)"
        }
    }

    func generateMemoryCard() {
        guard let word = snapshot.word else { return }
        guard let url = URL(string: endpointText), let key = ModelSecretStore.load() else {
            showModelSettings = true
            memoryError = MemoryHarnessError.notConfigured.localizedDescription
            return
        }
        let previous = branchHistory
        let request = MemoryRequest(
            word: word,
            learnerNote: learnerNote,
            previousReason: previous?.forgetReason,
            preferredMethod: selectedMethodKind,
            previousMethod: previous?.methodVersions.last?.method.cue,
            existingCard: memoryCard,
            focusMeaningKey: selectedBranch?.meaningKey
        )
        let configuration = ModelConfiguration(endpoint: url, model: modelText, apiKey: key)
        isGenerating = true
        memoryError = nil
        Task {
            do {
                let card = try await modelClient.generate(request, configuration: configuration)
                try memoryStore.save(card)
                if snapshot.word == word {
                    memoryCard = card
                    selectedBranchID = card.branches.first?.id
                    showAnswer = false
                }
            } catch {
                memoryError = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func selectBranch(_ branch: MeaningBranch) {
        selectedBranchID = branch.id
        showAnswer = false
    }

    func selectMethod(_ method: MemoryMethod) {
        guard let word = snapshot.word, let branch = selectedBranch else { return }
        let reason = branchHistory?.forgetReason == .methodFailed ? "上次记法无效，用户选择新方法" : nil
        do {
            try memoryStore.selectMethod(word: word, branch: branch, method: method, reason: reason)
            objectWillChange.send()
        } catch {
            memoryError = "记法保存失败：\(error.localizedDescription)"
        }
    }

    func recordFeedback(_ result: RecallResult, reason: ForgetReason?) {
        guard let word = snapshot.word, let branch = selectedBranch else { return }
        do {
            let condition: RecallCondition
            if memoryCard?.transferCheck.targetBranch != branch.meaningKey {
                condition = .selfReport
            } else {
                condition = showAnswer ? .newSentenceAfterReveal : .newSentenceBeforeReveal
            }
            try memoryStore.recordFeedback(word: word, branch: branch, result: result, condition: condition, reason: reason, note: learnerNote)
            objectWillChange.send()
        } catch {
            memoryError = "反馈保存失败：\(error.localizedDescription)"
        }
    }

    func promptForAccessibility() {
        reader.requestPermissionPrompt()
        reader.openAccessibilitySettings()
        refresh()
    }

    func openAccessibilitySettings() {
        reader.openAccessibilitySettings()
    }
}

struct SidebarView: View {
    @ObservedObject var model: CompanionViewModel

    private let blue = Color(red: 0.08, green: 0.28, blue: 0.62)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [blue, Color(red: 0.12, green: 0.43, blue: 0.77)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectionCard
                    wordCard
                    MemoryPanelView(model: model)
                    debugCard
                    permissionCard
                }
                .padding(22)
            }
        }
        .frame(minWidth: 360, idealWidth: 410, maxWidth: 520, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Maimemo Companion")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("跟词 · 理解 · 记住")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var wordCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前单词")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text(model.snapshot.word ?? "等待学习页单词")
                .font(.system(size: model.snapshot.word == nil ? 24 : 42, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let changed = model.lastChangeAt {
                Text("最近变化：\(changed.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("调试信息", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text(model.snapshot.diagnostic)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            Text("节点：\(model.snapshot.nodeCount) · 扫描：\(model.snapshot.scannedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            if !model.snapshot.candidates.isEmpty {
                Text("候选：" + model.snapshot.candidates.prefix(4).map(\.text).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("辅助功能权限")
                .font(.headline)
            Text(model.snapshot.isTrusted ? "已授权：可以读取墨墨辅助功能树" : "未授权：需要允许本应用读取墨墨")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            HStack(spacing: 8) {
                Button("请求授权") { model.promptForAccessibility() }
                    .buttonStyle(.borderedProminent)
                Button("打开设置") { model.openAccessibilitySettings() }
                    .buttonStyle(.bordered)
            }
            Text("系统设置 → 隐私与安全性 → 辅助功能 → Maimemo Companion")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusTitle: String {
        if !model.snapshot.appFound { return "等待墨墨运行" }
        if !model.snapshot.isTrusted { return "需要辅助功能权限" }
        if model.snapshot.word == nil { return "已连接，等待当前词" }
        return "已连接墨墨"
    }

    private var statusDetail: String {
        if !model.snapshot.appFound { return "启动 /Applications/Maimemo.app 后会自动重试" }
        if !model.snapshot.isTrusted { return "只读访问被系统拦截，侧栏不会伪称已跟词" }
        return "每 0.8 秒只读扫描一次"
    }

    private var statusColor: Color {
        if !model.snapshot.appFound || !model.snapshot.isTrusted { return .orange }
        if model.snapshot.word == nil { return .yellow }
        return .green
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionViewModel()
    private var window: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: SidebarView(model: model))
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 760)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maimemo Companion"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 360, height: 560)
        window.setFrameAutosaveName("MaimemoCompanionSidebar")
        window.makeKeyAndOrderFront(nil)
        self.window = window

        refreshAndPosition()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshAndPosition() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func refreshAndPosition() {
        model.refresh()
        if let windowFrame = model.snapshot.windowFrame {
            positionBesideMaimemo(windowFrame)
        }
    }

    private func positionBesideMaimemo(_ axFrame: CGRect) {
        guard let window else { return }
        let sidebarSize = window.frame.size
        let screen = NSScreen.screens.first { screen in
            let candidateY = screen.frame.maxY - axFrame.midY
            return screen.frame.contains(CGPoint(x: axFrame.midX, y: candidateY))
        } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let appKitY = screen.frame.maxY - axFrame.maxY
        let desiredX = axFrame.maxX + 12
        let x = min(desiredX, visible.maxX - sidebarSize.width)
        let y = min(max(appKitY, visible.minY), visible.maxY - sidebarSize.height)
        window.setFrameOrigin(NSPoint(x: max(visible.minX, x), y: y))
    }
}

@main
@MainActor
struct MaimemoCompanionMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = CompanionAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
