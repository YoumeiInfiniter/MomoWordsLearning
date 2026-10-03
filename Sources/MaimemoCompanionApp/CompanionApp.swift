import AppKit
import SwiftUI
import MaimemoAXCore
import WordMemoryCore

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published private(set) var snapshot: MaimemoAXSnapshot
    @Published private(set) var diagnosticSnapshot: MaimemoAXSnapshot
    @Published private(set) var lastChangeAt: Date?
    @Published private(set) var memoryCard: MemoryCard?
    @Published private(set) var isMemoryRevealed = false
    @Published private(set) var isShowingLastCapturedWord = false
    @Published private(set) var selectedBranchID: String?
    @Published private(set) var isGenerating = false
    @Published var memoryError: String?
    @Published var learnerNote = ""
    @Published var selectedMethodKind: MemoryMethodKind? = nil
    @Published var showAnswer = false
    @Published var showSettings = false
    @Published var settingsMessage: String?
    @Published private(set) var isSavingModelSettings = false
    @Published var endpointText: String
    @Published var modelText: String
    @Published var enteredAPIKey = ""
    @Published private(set) var hasStoredAPIKey: Bool

    let reader: MaimemoAccessibilityReader
    let memoryStore: MemoryStore
    private var previousWord: String?
    private var lastScanSnapshot: MaimemoAXSnapshot
    private let modelClient = OpenAICompatibleClient()

    init(reader: MaimemoAccessibilityReader = MaimemoAccessibilityReader(), memoryStore: MemoryStore = MemoryStore()) {
        self.reader = reader
        self.memoryStore = memoryStore
        self.endpointText = UserDefaults.standard.string(forKey: "memory.model.endpoint") ?? ""
        self.modelText = UserDefaults.standard.string(forKey: "memory.model.name") ?? ""
        self.hasStoredAPIKey = false
        self.memoryError = memoryStore.loadWarning
        let initialSnapshot = MaimemoAXSnapshot(
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
        self.snapshot = initialSnapshot
        self.diagnosticSnapshot = initialSnapshot
        self.lastScanSnapshot = initialSnapshot
        Task { [weak self] in
            let exists = await Task.detached(priority: .utility) {
                ModelSecretStore.exists()
            }.value
            self?.hasStoredAPIKey = exists
        }
    }

    func refresh() async -> MaimemoAXSnapshot {
        let next = await reader.scanAsync()
        lastScanSnapshot = next
        // A partial AX traversal is not proof that the displayed word disappeared.
        // Keep the last complete result until a complete scan or app/permission change.
        if next.word == nil && snapshot.word != nil && next.appFound && next.isTrusted &&
            (next.scanIncomplete || next.nodeCount < 10) {
            isShowingLastCapturedWord = true
            return snapshot
        }
        isShowingLastCapturedWord = false
        if next.word != previousWord, next.word != nil {
            lastChangeAt = Date()
            isMemoryRevealed = false
            selectedMethodKind = nil
            memoryError = memoryStore.loadWarning
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
            isMemoryRevealed = false
            selectedMethodKind = nil
        }
        previousWord = next.word
        if next.word != snapshot.word || next.appFound != snapshot.appFound || next.isTrusted != snapshot.isTrusted {
            snapshot = next
        }
        return next
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

    func revealMemoryHelp() {
        guard snapshot.word != nil else { return }
        isMemoryRevealed = true
    }

    func saveModelSettings() {
        guard !isSavingModelSettings else { return }
        let endpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), !model.isEmpty else {
            settingsMessage = "请填写完整的模型地址与名称"
            return
        }
        let host = url.host?.lowercased() ?? ""
        guard !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            settingsMessage = MemoryHarnessError.unsafeEndpoint.localizedDescription
            return
        }
        isSavingModelSettings = true
        settingsMessage = nil
        let key = enteredAPIKey
        Task { @MainActor in
            defer { isSavingModelSettings = false }
            do {
                if !key.isEmpty {
                    try await Task.detached(priority: .userInitiated) {
                        try ModelSecretStore.save(key)
                    }.value
                    hasStoredAPIKey = true
                    enteredAPIKey = ""
                }
                endpointText = endpoint
                modelText = model
                UserDefaults.standard.set(endpoint, forKey: "memory.model.endpoint")
                UserDefaults.standard.set(model, forKey: "memory.model.name")
                settingsMessage = hasStoredAPIKey ? "模型设置已保存在本机" : "地址与模型已保存；还需要 API Key 才能生成"
            } catch {
                settingsMessage = "API Key 无法保存到钥匙串：\(error.localizedDescription)"
            }
        }
    }

    func generateMemoryCard() {
        guard let word = snapshot.word else { return }
        let modelName = modelText
        guard let url = URL(string: endpointText), !modelName.isEmpty else {
            openSettings()
            settingsMessage = MemoryHarnessError.notConfigured.localizedDescription
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
        isGenerating = true
        memoryError = nil
        Task {
            do {
                guard let key = await Task.detached(priority: .userInitiated, operation: {
                    ModelSecretStore.load()
                }).value else {
                    openSettings()
                    settingsMessage = MemoryHarnessError.notConfigured.localizedDescription
                    isGenerating = false
                    return
                }
                let configuration = ModelConfiguration(endpoint: url, model: modelName, apiKey: key)
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
    }

    func openAccessibilitySettings() {
        reader.openAccessibilitySettings()
    }

    func openSettings() {
        diagnosticSnapshot = lastScanSnapshot
        settingsMessage = nil
        showSettings = true
    }

    func refreshDiagnostic() {
        diagnosticSnapshot = lastScanSnapshot
    }
}

struct SidebarView: View {
    @ObservedObject var model: CompanionViewModel

    private let background = Color(red: 0.055, green: 0.075, blue: 0.105)
    private let muted = Color.white.opacity(0.58)
    private let accent = Color(red: 0.76, green: 0.85, blue: 0.96)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [background, Color(red: 0.10, green: 0.15, blue: 0.22), background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.showSettings {
                        settingsPage
                    } else {
                        header
                        if !model.snapshot.appFound || !model.snapshot.isTrusted || model.isShowingLastCapturedWord {
                            connectionCard
                        }
                        wordCard
                        MemoryPanelView(model: model)
                    }
                }
                .padding(26)
            }
        }
        .frame(minWidth: 320, idealWidth: 410, maxWidth: 580, minHeight: 300)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("M A I M E M O")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(2.1)
                .foregroundStyle(accent)
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Spacer()
            Button { model.openSettings() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusTitle)
                .font(.custom("Songti SC", size: 14))
            Spacer()
            Text("只读跟随")
                .font(.custom("Songti SC", size: 12))
                .foregroundStyle(muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var wordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.snapshot.word == nil ? "等待墨墨显示单词" :
                 model.isShowingLastCapturedWord ? "最近捕获的单词" : "此刻的单词")
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(muted)
            Text(model.snapshot.word ?? "等待学习页单词")
                .font(.system(size: model.snapshot.word == nil ? 25 : 57, weight: .regular, design: .serif))
                .tracking(model.snapshot.word == nil ? 0 : 0.5)
                .foregroundStyle(.white.opacity(0.95))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 24)
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Button { model.showSettings = false } label: {
                    Label("返回学习", systemImage: "chevron.left")
                        .font(.custom("Songti SC", size: 14))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("设置")
                    .font(.custom("Songti SC", size: 26))
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("记忆模型")
                    .font(.custom("Songti SC", size: 21))
                Text("仅在你主动生成记忆卡时调用。当前词与填写的卡点会发送给所配置的接口。")
                    .font(.custom("Songti SC", size: 13))
                    .foregroundStyle(muted)
                TextField("完整接口地址 · https://…/v1/chat/completions", text: $model.endpointText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSavingModelSettings)
                TextField("模型名称", text: $model.modelText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSavingModelSettings)
                SecureField(model.hasStoredAPIKey ? "API Key 已保存；留空沿用" : "API Key", text: $model.enteredAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isSavingModelSettings)
                HStack {
                    Button("保存模型设置") { model.saveModelSettings() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isSavingModelSettings)
                    if model.isSavingModelSettings { ProgressView().controlSize(.small) }
                }
                if let message = model.settingsMessage {
                    Text(message)
                        .font(.custom("Songti SC", size: 13))
                        .foregroundStyle(accent)
                }
                Text("地址和模型名保存在本机偏好设置；密钥仅存于 macOS 钥匙串。")
                    .font(.custom("Songti SC", size: 12))
                    .foregroundStyle(muted)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            permissionCard
            debugCard
        }
    }

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("连接诊断", systemImage: "waveform.path.ecg")
                    .font(.custom("Songti SC", size: 18))
                Spacer()
                Button("刷新") { model.refreshDiagnostic() }
                    .font(.custom("Songti SC", size: 12))
            }
            Text(model.diagnosticSnapshot.diagnostic)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            Text("节点：\(model.diagnosticSnapshot.nodeCount) · 扫描：\(model.diagnosticSnapshot.scannedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
            if !model.diagnosticSnapshot.candidates.isEmpty {
                Text("候选：" + model.diagnosticSnapshot.candidates.prefix(4).map(\.text).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("辅助功能权限")
                .font(.custom("Songti SC", size: 18))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var statusTitle: String {
        if !model.snapshot.appFound { return "等待墨墨运行" }
        if !model.snapshot.isTrusted { return "需要辅助功能权限" }
        if model.isShowingLastCapturedWord { return "已连接 · 等待刷新" }
        if model.snapshot.word == nil { return "已连接，等待当前词" }
        return "已连接墨墨"
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
    private var scanInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: SidebarView(model: model))
        let contentRect = NSRect(x: 0, y: 0, width: 410, height: 540)
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
        window.minSize = NSSize(width: 320, height: 300)
        window.setFrameAutosaveName("MaimemoCompanionCompactSidebar")
        window.makeKeyAndOrderFront(nil)
        self.window = window

        refreshAndPosition()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAndPosition() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func refreshAndPosition() {
        guard !scanInFlight else { return }
        scanInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let next = await model.refresh()
            scanInFlight = false
            if let windowFrame = next.windowFrame {
                positionBesideMaimemo(windowFrame)
            }
        }
    }

    private func positionBesideMaimemo(_ axFrame: CGRect) {
        guard let window else { return }
        guard !window.inLiveResize, axFrame.width > 0, axFrame.height > 0,
              let primaryScreen = NSScreen.screens.first else { return }

        // Accessibility uses a top-left origin; AppKit uses a bottom-left origin.
        let maimemoFrame = CGRect(
            x: axFrame.minX,
            y: primaryScreen.frame.maxY - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        guard let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(maimemoFrame).area < $1.frame.intersection(maimemoFrame).area
        }), screen.frame.intersection(maimemoFrame).area > 0 else { return }

        let visibleMaimemo = maimemoFrame.intersection(screen.visibleFrame)
        let availableWidth = screen.visibleFrame.maxX - maimemoFrame.maxX
        let width = min(410, availableWidth)
        // A narrow or full-screen Maimemo window leaves no usable right-side dock.
        guard !visibleMaimemo.isNull, width >= window.minSize.width,
              visibleMaimemo.height >= window.minSize.height else { return }

        let destination = NSRect(
            x: maimemoFrame.maxX,
            y: visibleMaimemo.minY,
            width: width,
            height: visibleMaimemo.height
        )
        let current = window.frame
        guard abs(current.minX - destination.minX) > 1 ||
              abs(current.minY - destination.minY) > 1 ||
              abs(current.width - destination.width) > 1 ||
              abs(current.height - destination.height) > 1 else { return }
        window.setFrame(destination, display: true)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
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
