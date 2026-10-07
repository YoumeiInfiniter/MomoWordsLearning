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
    @Published private(set) var memoryImageURL: URL?
    @Published private(set) var imageGeneratingWord: String?
    @Published var imageError: String?
    @Published private(set) var isMemoryRevealed = false
    @Published private(set) var selectedAnchorKind: MemoryAnchorKind = .sound
    @Published private(set) var isShowingLastCapturedWord = false
    @Published private(set) var selectedBranchID: String?
    @Published private(set) var quickHint: QuickMemoryHint?
    @Published private(set) var generatingWord: String?
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
    @Published private(set) var isCheckingStoredAPIKey = true
    @Published var enteredImageAPIKey = ""
    @Published private(set) var hasStoredImageAPIKey = false
    @Published private(set) var isCheckingImageAPIKey = true
    @Published private(set) var isSavingImageKey = false
    @Published var imageSettingsMessage: String?

    let reader: MaimemoAccessibilityReader
    let memoryStore: MemoryStore
    let imageStore: MemoryImageStore
    private let injectedImageGenerator: (any MemoryImageGenerator)?
    private var previousWord: String?
    private var lastScanSnapshot: MaimemoAXSnapshot
    private let modelClient = OpenAICompatibleClient()
    private var quickHints: [String: QuickMemoryHint] = [:]
    private var generationTask: Task<Void, Never>?
    private var activeGenerationID: UUID?
    private var generatingAnchorKind: MemoryAnchorKind?
    private var imageSelectionIntent: String?
    private var imageGenerationTask: Task<Void, Never>?
    private var activeImageGenerationID: UUID?

    var isGenerating: Bool { generatingWord == snapshot.word && generatingWord != nil }
    var isGeneratingCurrentImage: Bool { imageGeneratingWord == snapshot.word && imageGeneratingWord != nil }
    var imageGenerator: (any MemoryImageGenerator)? {
        injectedImageGenerator ?? (hasStoredImageAPIKey ? MaiziImageGenerator() : nil)
    }

    init(reader: MaimemoAccessibilityReader = MaimemoAccessibilityReader(), memoryStore: MemoryStore = MemoryStore(), imageStore: MemoryImageStore = MemoryImageStore(), imageGenerator: (any MemoryImageGenerator)? = nil) {
        self.reader = reader
        self.memoryStore = memoryStore
        self.imageStore = imageStore
        self.injectedImageGenerator = imageGenerator
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
            guard let self else { return }
            self.hasStoredAPIKey = exists
            self.isCheckingStoredAPIKey = false
            self.generateRevealedCardIfNeeded()
        }
        Task { [weak self] in
            let exists = await Task.detached(priority: .utility) {
                ImageSecretStore.exists()
            }.value
            guard let self else { return }
            self.hasStoredImageAPIKey = exists
            self.isCheckingImageAPIKey = false
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
            imageSelectionIntent = nil
            imageGenerationTask?.cancel()
            imageGenerationTask = nil
            activeImageGenerationID = nil
            imageGeneratingWord = nil
            lastChangeAt = Date()
            isMemoryRevealed = false
            selectedMethodKind = nil
            memoryError = memoryStore.loadWarning
            if let word = next.word {
                memoryCard = memoryStore.card(for: word)
                selectedAnchorKind = memoryCard?.anchor?.kind ?? .sound
                memoryImageURL = memoryCard.flatMap { imageURL(for: $0) }
                imageError = nil
                quickHint = quickHints[word.lowercased()]
                selectedBranchID = memoryCard?.branches.first?.id
                showAnswer = false
                learnerNote = ""
                if memoryCard != nil {
                    do { try memoryStore.recordEncounter(word: word) }
                    catch { memoryError = "本地记录更新失败：\(error.localizedDescription)" }
                }
            }
        } else if next.word == nil, previousWord != nil {
            imageSelectionIntent = nil
            imageGenerationTask?.cancel()
            imageGenerationTask = nil
            activeImageGenerationID = nil
            imageGeneratingWord = nil
            memoryCard = nil
            selectedAnchorKind = .sound
            memoryImageURL = nil
            imageError = nil
            quickHint = nil
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
        guard snapshot.word != nil, !isMemoryRevealed else { return }
        isMemoryRevealed = true
        generateRevealedCardIfNeeded()
    }

    func returnToLearning() {
        showSettings = false
        generateRevealedCardIfNeeded()
    }

    private func generateRevealedCardIfNeeded() {
        guard snapshot.word != nil, isMemoryRevealed, !showSettings,
              memoryCard == nil, quickHint == nil, !isGenerating, modelIsConfigured else { return }
        generateMemoryCard()
    }

    func chooseAnchor(_ kind: MemoryAnchorKind) {
        guard isMemoryRevealed, let word = snapshot.word else { return }
        selectedAnchorKind = kind
        imageError = nil
        imageSelectionIntent = kind == .letterIllustration ? word : nil
        if let card = memoryCard, let selected = card.selectingAnchor(kind) {
            if generatingWord == word {
                generationTask?.cancel()
                generationTask = nil
                activeGenerationID = nil
                generatingWord = nil
                generatingAnchorKind = nil
                quickHint = nil
                quickHints.removeValue(forKey: word.lowercased())
            }
            do {
                if card.anchor?.kind != kind { try memoryStore.save(selected) }
                memoryCard = selected
                memoryImageURL = imageURL(for: selected)
                if kind == .letterIllustration {
                    imageSelectionIntent = nil
                    generateImageIfNeeded(for: selected)
                }
            } catch {
                imageSelectionIntent = nil
                memoryError = "联想方式保存失败：\(error.localizedDescription)"
            }
        } else {
            generateMemoryCard(requestedAnchorKind: kind, switchingAnchor: memoryCard != nil)
        }
    }

    func retrySelectedAnchor() {
        guard isMemoryRevealed, let word = snapshot.word else { return }
        imageSelectionIntent = selectedAnchorKind == .letterIllustration ? word : nil
        generateMemoryCard(requestedAnchorKind: selectedAnchorKind, switchingAnchor: memoryCard != nil)
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

    func saveImageSettings() {
        guard !isSavingImageKey else { return }
        let key = enteredImageAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            imageSettingsMessage = hasStoredImageAPIKey ? "图片生成 Key 已保存；无需重复输入" : "请填写图片生成 API Key"
            return
        }
        isSavingImageKey = true
        imageSettingsMessage = nil
        Task { @MainActor in
            defer { isSavingImageKey = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageSecretStore.save(key)
                }.value
                enteredImageAPIKey = ""
                hasStoredImageAPIKey = true
                imageSettingsMessage = "图片生成 Key 已保存在本机钥匙串"
            } catch {
                imageSettingsMessage = "图片生成 Key 保存失败：\(error.localizedDescription)"
            }
        }
    }

    func generateMemoryCard(requestedAnchorKind: MemoryAnchorKind? = nil, switchingAnchor: Bool = false) {
        guard let word = snapshot.word else { return }
        let anchorKind = requestedAnchorKind ?? selectedAnchorKind
        if generatingWord == word && generatingAnchorKind == anchorKind { return }
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
            focusMeaningKey: switchingAnchor ? nil : selectedBranch?.meaningKey,
            preferredAnchorKind: anchorKind
        )
        let existingCard = switchingAnchor ? memoryCard : nil
        if let oldWord = generatingWord {
            generationTask?.cancel()
            quickHints.removeValue(forKey: oldWord.lowercased())
            activeGenerationID = nil
        }
        let generationID = UUID()
        activeGenerationID = generationID
        generatingWord = word
        generatingAnchorKind = anchorKind
        quickHint = nil
        memoryError = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = await Task.detached(priority: .userInitiated, operation: {
                    ModelSecretStore.load()
                }).value else {
                    if activeGenerationID == generationID && snapshot.word == word {
                        openSettings()
                        settingsMessage = MemoryHarnessError.notConfigured.localizedDescription
                    }
                    finishGeneration(generationID)
                    return
                }
                try Task.checkCancellation()
                guard activeGenerationID == generationID else { return }
                let configuration = ModelConfiguration(endpoint: url, model: modelName, apiKey: key)
                let generated = try await modelClient.generateStreaming(request, configuration: configuration) { [weak self] hint in
                    await self?.receiveQuickHint(hint, generationID: generationID)
                }
                try Task.checkCancellation()
                guard activeGenerationID == generationID else { return }
                let card = if let existingCard {
                    generated.withAlternateAnchor(existingCard.anchor(for: anchorKind == .sound ? .letterIllustration : .sound))
                } else {
                    generated
                }
                try memoryStore.save(card)
                quickHints.removeValue(forKey: word.lowercased())
                if snapshot.word == word && selectedAnchorKind == anchorKind {
                    memoryCard = card
                    memoryImageURL = imageURL(for: card)
                    quickHint = nil
                    selectedBranchID = card.branches.first?.id
                    showAnswer = false
                    if anchorKind == .letterIllustration && imageSelectionIntent == word {
                        imageSelectionIntent = nil
                        generateImageIfNeeded(for: card)
                    }
                }
            } catch {
                if activeGenerationID == generationID && !Task.isCancelled {
                    if snapshot.word == word {
                        memoryError = error.localizedDescription
                    }
                }
            }
            finishGeneration(generationID)
        }
    }

    private func receiveQuickHint(_ hint: QuickMemoryHint, generationID: UUID) {
        guard activeGenerationID == generationID, !Task.isCancelled else { return }
        quickHints[hint.word.lowercased()] = hint
        if snapshot.word?.caseInsensitiveCompare(hint.word) == .orderedSame {
            quickHint = hint
        }
    }

    private func finishGeneration(_ generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        activeGenerationID = nil
        generatingWord = nil
        generatingAnchorKind = nil
        generationTask = nil
    }

    private func imageURL(for card: MemoryCard) -> URL? {
        guard card.anchor?.kind == .letterIllustration,
              let prompt = card.anchor?.imagePrompt else { return nil }
        return imageStore.imageURL(for: card.word, prompt: prompt)
    }

    private func generateImageIfNeeded(for card: MemoryCard) {
        guard isMemoryRevealed, snapshot.word == card.word,
              card.anchor?.kind == .letterIllustration,
              let prompt = card.anchor?.imagePrompt,
              let imageGenerator,
              imageStore.imageURL(for: card.word, prompt: prompt) == nil else { return }
        if imageGeneratingWord == card.word { return }
        imageGenerationTask?.cancel()
        let generationID = UUID()
        activeImageGenerationID = generationID
        imageGeneratingWord = card.word
        imageError = nil
        let imageStore = self.imageStore
        imageGenerationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await imageGenerator.generateImage(prompt: prompt)
                try Task.checkCancellation()
                guard activeImageGenerationID == generationID else { return }
                let url = try await Task.detached(priority: .utility) {
                    try imageStore.save(image, for: card.word, prompt: prompt)
                }.value
                try Task.checkCancellation()
                if activeImageGenerationID == generationID && snapshot.word == card.word {
                    memoryImageURL = url
                }
            } catch {
                if activeImageGenerationID == generationID && !Task.isCancelled && snapshot.word == card.word {
                    imageError = error.localizedDescription
                }
            }
            if activeImageGenerationID == generationID {
                activeImageGenerationID = nil
                imageGeneratingWord = nil
                imageGenerationTask = nil
            }
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
    @State private var isRevealHovered = false

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

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.showSettings {
                            settingsPage
                        } else {
                            header
                            if !model.snapshot.appFound || !model.snapshot.isTrusted || model.isShowingLastCapturedWord {
                                connectionCard
                            }
                            if model.isMemoryRevealed {
                                wordCard
                                MemoryLinkPanelView(model: model)
                            } else {
                                revealSurface(minHeight: geometry.size.height - 140)
                            }
                        }
                    }
                    .padding(26)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 410, maxWidth: 580, minHeight: 300)
        .preferredColorScheme(.dark)
    }

    private func revealSurface(minHeight: CGFloat) -> some View {
        Button {
            model.revealMemoryHelp()
        } label: {
            VStack(alignment: .leading, spacing: 24) {
                wordCard
                MemoryLinkPanelView(model: model)
            }
            .frame(maxWidth: .infinity, minHeight: max(0, minHeight), alignment: .topLeading)
            .contentShape(Rectangle())
            .background(isRevealHovered ? .white.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .disabled(model.snapshot.word == nil)
        .accessibilityLabel("查看\(model.snapshot.word ?? "当前单词")的线索")
        .accessibilityHint("已有线索立即显示；没有线索时调用已配置的模型")
        .onHover { isRevealHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: isRevealHovered)
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
                Button { model.returnToLearning() } label: {
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
                Text("点击学习区域且当前词没有本地线索时，或主动重做记法时调用。当前词与填写的卡点会发送给所配置的接口。")
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
            imageSettingsCard
            permissionCard
            debugCard
        }
    }

    private var imageSettingsCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("字母插画")
                .font(.custom("Songti SC", size: 21))
            Text("gpt-image-2.5 · 1:1 · 1K · 每次一张。只有你主动选择插画且本机没有缓存时才会调用图片服务。")
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(muted)
            SecureField(model.hasStoredImageAPIKey ? "图片生成 Key 已保存；留空沿用" : "图片生成 API Key", text: $model.enteredImageAPIKey)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isSavingImageKey)
            HStack(spacing: 10) {
                Button("保存图片 Key") { model.saveImageSettings() }
                    .buttonStyle(.bordered)
                    .disabled(model.isSavingImageKey)
                if model.isSavingImageKey { ProgressView().controlSize(.small) }
            }
            if let message = model.imageSettingsMessage {
                Text(message)
                    .font(.custom("Songti SC", size: 12))
                    .foregroundStyle(accent)
            }
            Text("图片服务与记忆模型分别配置；密钥仅存于 macOS 钥匙串，生成图片保存在本机。首次生成和手动重试都可能产生费用。")
                .font(.custom("Songti SC", size: 12))
                .foregroundStyle(muted)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
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
