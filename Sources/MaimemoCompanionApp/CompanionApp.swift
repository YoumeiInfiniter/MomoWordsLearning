import AppKit
import Combine
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
    @Published var imageError: String?
    @Published private(set) var isMemoryRevealed = false
    @Published private(set) var selectedAnchorKind: MemoryAnchorKind = .sound
    @Published private(set) var isShowingLastCapturedWord = false
    @Published private(set) var selectedBranchID: String?
    @Published private(set) var quickHint: QuickMemoryHint?
    @Published var memoryError: String?
    @Published var learnerNote = ""
    @Published var reasonTags: Set<RevisionReasonTag> = []
    @Published var showImageTasks = false
    @Published var needsBranchSelection = false
    @Published var selectedMethodKind: MemoryMethodKind? = nil
    @Published var showAnswer = false
    @Published var showSettings = false
    @Published var settingsMessage: String?
    @Published private(set) var isSavingModelSettings = false
    @Published var endpointText: String
    @Published var modelText: String
    @Published var thinkingEnabled: Bool {
        didSet {
            // Saving this preference never starts or restarts a model request.
            UserDefaults.standard.set(thinkingEnabled, forKey: "memory.model.thinkingEnabled")
        }
    }
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
    let failedResponses: FailedMemoryResponseStore
    let imageStore: MemoryImageStore
    private let injectedImageGenerator: (any MemoryImageGenerator)?
    private var previousWord: String?
    private var lastScanSnapshot: MaimemoAXSnapshot
    private let modelClient: OpenAICompatibleClient
    private let injectedModelConfiguration: ModelConfiguration?
    private var selectedBranchWasExplicit = false
    private var quickHints: [String: QuickMemoryHint] = [:]
    @Published private var activeGenerations: [String: UUID] = [:]
    private var generationTasks: [String: Task<Void, Never>] = [:]
    private var generationErrors: [String: String] = [:]
    let imageTasks: ImageTaskManager
    private var taskObservation: AnyCancellable?

    var isGenerating: Bool { snapshot.word.map { activeGenerations[$0.lowercased()] != nil } ?? false }
    var currentImageIdentity: ImageTaskIdentity? {
        memoryCard.map { ImageTaskIdentity(word: $0.word, versionID: $0.versionKey, prompt: $0.illustrationPrompt) }
    }
    var currentImageTask: ImageTaskRecord? { currentImageIdentity.flatMap { imageTasks.task(for: $0) } }
    var isGeneratingCurrentImage: Bool { currentImageTask?.state.isActive == true }
    var imageGenerator: (any MemoryImageGenerator)? {
        injectedImageGenerator ?? (hasStoredImageAPIKey ? MaiziImageGenerator() : nil)
    }

    init(reader: MaimemoAccessibilityReader = MaimemoAccessibilityReader(), memoryStore: MemoryStore = MemoryStore(), imageStore: MemoryImageStore = MemoryImageStore(), imageGenerator: (any MemoryImageGenerator)? = nil, modelClient: OpenAICompatibleClient = OpenAICompatibleClient(), modelConfiguration: ModelConfiguration? = nil, checkStoredKeys: Bool = true) {
        self.modelClient = modelClient
        self.injectedModelConfiguration = modelConfiguration
        self.reader = reader
        self.memoryStore = memoryStore
        self.failedResponses = FailedMemoryResponseStore(fileURL: memoryStore.fileURL.deletingLastPathComponent().appendingPathComponent("failed-memory-responses.json"))
        self.imageStore = imageStore
        self.imageTasks = ImageTaskManager(imageStore: imageStore)
        self.injectedImageGenerator = imageGenerator
        self.endpointText = modelConfiguration?.endpoint.absoluteString ?? UserDefaults.standard.string(forKey: "memory.model.endpoint") ?? ""
        self.modelText = modelConfiguration?.model ?? UserDefaults.standard.string(forKey: "memory.model.name") ?? ""
        self.thinkingEnabled = UserDefaults.standard.object(forKey: "memory.model.thinkingEnabled") as? Bool ?? true
        self.hasStoredAPIKey = modelConfiguration != nil
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
        taskObservation = imageTasks.$records.sink { [weak self] _ in
            // Published values arrive before assignment; redraw from the completed update.
            Task { @MainActor [weak self] in self?.refreshImageState() }
        }
        guard checkStoredKeys else {
            isCheckingStoredAPIKey = false; isCheckingImageAPIKey = false
            return
        }
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
        return applySnapshot(next)
    }

    @discardableResult
    func applySnapshot(_ next: MaimemoAXSnapshot) -> MaimemoAXSnapshot {
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
                selectedAnchorKind = memoryCard?.anchor?.kind ?? .sound
                memoryImageURL = memoryCard.flatMap { imageURL(for: $0) }
                imageError = nil
                quickHint = quickHints[word.lowercased()]
                if quickHint == nil, activeGenerations[word.lowercased()] == nil,
                   let received = failedResponses.latest(for: word), received.finishReason != "content_filter",
                   let hint = MemoryHarness.quickHint(from: received.content, expectedWord: word, requiresLearningLink: received.request.requiresLearningLink == true),
                   received.request.allowedAnchorKinds.contains(hint.anchor.kind) {
                    quickHint = hint
                }
                selectedBranchID = memoryCard?.branches.first?.id
                showAnswer = false
                learnerNote = ""
                reasonTags = []; needsBranchSelection = false
                selectedBranchWasExplicit = false
                if memoryCard != nil {
                    do { try memoryStore.recordEncounter(word: word) }
                    catch { memoryError = "本地记录更新失败：\(error.localizedDescription)" }
                }
            }
        } else if next.word == nil, previousWord != nil {
            memoryCard = nil
            selectedAnchorKind = .sound
            memoryImageURL = nil
            imageError = nil
            quickHint = nil
            selectedBranchID = nil
            isMemoryRevealed = false
            selectedMethodKind = nil
            learnerNote = ""
            reasonTags = []; needsBranchSelection = false
        }
        if next.word != previousWord {
            memoryError = next.word.flatMap { generationErrors[$0.lowercased()] ?? failedResponses.latest(for: $0)?.failureReason }
                ?? memoryStore.loadWarning ?? failedResponses.loadWarning
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

    var supportsThinkingToggle: Bool {
        guard let endpoint = URL(string: endpointText) else { return false }
        return ModelConfiguration.supportsThinkingToggle(at: endpoint)
    }

    func revealMemoryHelp() {
        guard snapshot.word != nil, !isMemoryRevealed else { return }
        isMemoryRevealed = true
        generateRevealedCardIfNeeded()
    }

    func collapseMemoryHelp() { isMemoryRevealed = false; showAnswer = false }

    func returnToLearning() {
        showSettings = false
        generateRevealedCardIfNeeded()
    }

    private func generateRevealedCardIfNeeded() {
        guard snapshot.word != nil, isMemoryRevealed, !showSettings,
              memoryStore.loadWarning == nil, failedResponses.loadWarning == nil,
              failedResponses.latest(for: snapshot.word!) == nil, generationErrors[snapshot.word!.lowercased()] == nil,
              memoryCard == nil, quickHint == nil, !isGenerating, modelIsConfigured else { return }
        generateMemoryCard()
    }

    func chooseAnchor(_ kind: MemoryAnchorKind, generateImage: Bool = true) {
        guard isMemoryRevealed, !isGenerating else { return }
        if let card = memoryCard, let selected = card.selectingAnchor(kind) {
            do {
                try memoryStore.save(selected)
                memoryCard = selected; selectedAnchorKind = kind
                learnerNote = ""; reasonTags = []
                refreshImageState()
                if kind == .letterIllustration && generateImage { generateCurrentIllustration() }
            } catch { memoryError = error.localizedDescription }
        } else {
            generateMemoryCard(requestedAnchorKind: kind, switchingAnchor: memoryCard != nil, authorizeIllustration: kind == .letterIllustration && generateImage)
        }
    }

    var currentFailedResponse: FailedMemoryResponse? {
        snapshot.word.flatMap { failedResponses.latest(for: $0) }
    }
    var canReparseCurrentResponse: Bool {
        guard let response = currentFailedResponse else { return false }
        return !isGenerating && response.canReparse && response.request.existingCard == memoryCard
    }
    func retrySelectedAnchor() {
        if let response = currentFailedResponse, response.request.existingCard == memoryCard {
            generateMemoryCard(capturedRequest: response.request.renewed(requiresLearningLink: true))
        } else { generateMemoryCard() }
    }
    func upgradeCurrentLearningLink() {
        guard isMemoryRevealed, memoryCard != nil, !isGenerating else { return }
        // Explicit text improvement prepares both explanations; it does not authorize an image POST.
        generateMemoryCard()
    }
    func reparseReceivedResponse() {
        guard let response = currentFailedResponse, canReparseCurrentResponse else { return }
        do {
            let generated = try response.parseLocally()
            guard memoryStore.card(for: response.request.word) == response.request.existingCard else { throw MemoryStore.StoreError.staleRevision }
            let card = response.request.existingCard.map { generated.preservingAnchors(from: $0) } ?? generated
            let record = MemoryRedoRecord(request: response.request, card: card, model: response.model,
                endpoint: response.endpoint, thinkingEnabled: response.thinkingEnabled)
            try memoryStore.save(card, replacing: response.request.existingCard, reason: response.request.learnerNote, redoRecord: record)
            try? failedResponses.remove(for: card.word)
            memoryCard = card; selectedAnchorKind = card.anchor?.kind ?? .context
            quickHint = nil; quickHints.removeValue(forKey: card.word.lowercased())
            selectedBranchID = response.request.focusBranchID ?? card.branches.first?.id
            showAnswer = false; memoryError = nil; generationErrors.removeValue(forKey: card.word.lowercased())
            refreshImageState()
            // Local reprocessing never generates images, including an old illustration request.
        } catch {
            memoryError = error.localizedDescription + "；本次只在本机重新解析，未请求模型"
            if let word = snapshot.word { generationErrors[word.lowercased()] = memoryError }
        }
    }
    private func receiveFailedResponse(_ response: FailedMemoryResponse) {
        guard activeGenerations[response.request.word.lowercased()] == response.id else { return }
        do { try failedResponses.save(response) }
        catch {
            generationErrors[response.request.word.lowercased()] = response.failureReason + "；响应仅保留在本次运行内，暂存文件未写入"
        }
        objectWillChange.send()
    }

    func regenerate(_ preset: MemoryPreset) {
        guard isMemoryRevealed, memoryCard != nil, !isGenerating else { return }
        if let conflict = preset.conflict(with: learnerNote) { memoryError = conflict; return }
        if preset == .focusBranch, selectedBranch == nil || (memoryCard!.branches.count > 1 && !selectedBranchWasExplicit) {
            needsBranchSelection = true; return
        }
        generateMemoryCard(preset: preset)
    }

    var cardHistory: SoundAnchorHistory {
        snapshot.word.map { memoryStore.history(for: $0) } ?? SoundAnchorHistory(cards: [], selectedIndex: 0)
    }

    func moveHistory(by offset: Int) {
        guard cardHistory.canMove(by: offset) else { return }
        selectHistoryVersion(at: cardHistory.selectedIndex + offset)
    }

    func selectHistoryVersion(at index: Int) {
        guard isMemoryRevealed, !isGenerating, let word = snapshot.word else { return }
        do {
            guard let card = try memoryStore.selectHistory(for: word, at: index) else { return }
            memoryCard = card; selectedAnchorKind = card.anchor?.kind ?? .context
            quickHint = nil; quickHints.removeValue(forKey: word.lowercased())
            learnerNote = ""; reasonTags = []; memoryError = nil; selectedBranchWasExplicit = false
            selectedBranchID = card.branches.first?.id; showAnswer = false
            refreshImageState()
        } catch { memoryError = "历史切换失败：\(error.localizedDescription)" }
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

    func generateMemoryCard(requestedAnchorKind: MemoryAnchorKind? = nil, switchingAnchor: Bool = false, preset: MemoryPreset? = nil, capturedRequest: MemoryRequest? = nil, authorizeIllustration: Bool = false) {
        guard let word = snapshot.word, !isGenerating else { return }
        guard memoryStore.loadWarning == nil else { memoryError = memoryStore.loadWarning; return }
        let wordKey = word.lowercased()
        let modelName = modelText
        let requestThinkingEnabled = thinkingEnabled
        guard let endpoint = URL(string: endpointText), !modelName.isEmpty else {
            openSettings(); settingsMessage = MemoryHarnessError.notConfigured.localizedDescription; return
        }
        let original = memoryCard
        let expectedStoredCard = memoryStore.card(for: word)
        let focused = preset == .focusBranch ? selectedBranch : nil
        let previous = branchHistory
        let request = capturedRequest ?? MemoryRequest(word: word, learnerNote: learnerNote,
            previousReason: previous?.forgetReason, preferredMethod: selectedMethodKind,
            previousMethod: previous?.methodVersions.last?.method.cue, existingCard: original,
            focusMeaningKey: switchingAnchor ? nil : (focused?.meaningKey ?? selectedBranch?.meaningKey),
            preferredAnchorKind: requestedAnchorKind ?? .sound, isAnchorRevision: original != nil,
            strategy: requestedAnchorKind == nil ? (preset?.strategy ?? .auto) : nil,
            preset: preset, reasonTags: RevisionReasonTag.allCases.filter { reasonTags.contains($0) },
            visibleContext: nil, focusBranchID: focused?.id, previousUserNote: previous?.userNote ?? "", requiresLearningLink: true)
        guard request.word == word, request.existingCard == original else { memoryError = MemoryStore.StoreError.staleRevision.localizedDescription; return }
        let generationID = request.requestID
        activeGenerations[wordKey] = generationID
        quickHint = nil; quickHints.removeValue(forKey: wordKey)
        memoryError = nil; generationErrors.removeValue(forKey: wordKey)
        // Image choice authorizes one generation after the full text prompt passes validation.
        let wantsImage = authorizeIllustration && request.requiredAnchorKind == .letterIllustration
        generationTasks[wordKey] = Task { [weak self] in
            guard let self else { return }
            defer {
                if activeGenerations[wordKey] == generationID {
                    activeGenerations.removeValue(forKey: wordKey); generationTasks.removeValue(forKey: wordKey)
                }
            }
            do {
                let capturedKey: String?
                if let injectedModelConfiguration { capturedKey = injectedModelConfiguration.apiKey }
                else { capturedKey = await Task.detached(priority: .userInitiated, operation: { ModelSecretStore.load() }).value }
                guard let key = capturedKey else {
                    throw MemoryHarnessError.notConfigured
                }
                let configuration = ModelConfiguration(endpoint: endpoint, model: modelName, apiKey: key, thinkingEnabled: requestThinkingEnabled)
                let generated = try await modelClient.generateStreaming(request, configuration: configuration, onFailure: { [weak self] response in
                    await self?.receiveFailedResponse(response)
                }) { [weak self] hint in
                    await self?.receiveQuickHint(hint, generationID: generationID)
                }
                try Task.checkCancellation()
                guard activeGenerations[wordKey] == generationID,
                      memoryStore.card(for: word) == expectedStoredCard else { throw MemoryStore.StoreError.staleRevision }
                let card = original.map { generated.preservingAnchors(from: $0) } ?? generated
                var safeEndpoint = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
                safeEndpoint?.query = nil; safeEndpoint?.user = nil; safeEndpoint?.password = nil
                let record = MemoryRedoRecord(request: request, card: card, model: modelName, endpoint: safeEndpoint?.string ?? endpoint.host ?? "", thinkingEnabled: requestThinkingEnabled)
                try memoryStore.save(card, replacing: original, reason: request.learnerNote, redoRecord: record)
                try? failedResponses.remove(for: word)
                quickHints.removeValue(forKey: wordKey)
                // Save to the captured word first. Visibility is independent of completion.
                if snapshot.word == word {
                    memoryCard = card; selectedAnchorKind = card.anchor?.kind ?? .context
                    quickHint = nil; selectedBranchID = focused?.id ?? card.branches.first?.id
                    showAnswer = false; learnerNote = ""; reasonTags = []
                    refreshImageState()
                }
                if wantsImage { enqueueIllustration(for: card) }
            } catch {
                if !Task.isCancelled {
                    let diagnostic = generationErrors[wordKey] ?? error.localizedDescription
                    generationErrors[wordKey] = diagnostic
                    if snapshot.word == word { memoryError = diagnostic }
                }
            }
        }
    }

    private func receiveQuickHint(_ hint: QuickMemoryHint, generationID: UUID) {
        guard activeGenerations[hint.word.lowercased()] == generationID else { return }
        quickHints[hint.word.lowercased()] = hint
        if snapshot.word == hint.word { quickHint = hint }
    }

    private func imageURL(for card: MemoryCard) -> URL? {
        let identity = ImageTaskIdentity(word: card.word, versionID: card.versionKey, prompt: card.illustrationPrompt)
        return imageTasks.imageURL(for: identity, prompt: card.illustrationPrompt)
    }

    private func refreshImageState() {
        memoryImageURL = memoryCard.flatMap { imageURL(for: $0) }
        imageError = currentImageTask?.failure?.userMessage ?? imageTasks.storageWarning
        objectWillChange.send()
    }

    func generateCurrentIllustration(newGeneration: Bool = false) {
        guard isMemoryRevealed, let card = memoryCard else { return }
        enqueueIllustration(for: card, newGeneration: newGeneration)
    }

    private func enqueueIllustration(for card: MemoryCard, newGeneration: Bool = false) {
        guard card.wordLink != nil, card.illustration != nil else {
            imageError = "这份旧记法尚未记录原词与图片元素的对应关系；请先补齐原词联系，再主动生成插画"
            return
        }
        guard let generator = imageGenerator else { imageError = MaiziImageError.notConfigured.localizedDescription; return }
        do {
            let identity = ImageTaskIdentity(word: card.word, versionID: card.versionKey, prompt: card.illustrationPrompt)
            try imageTasks.enqueue(identity: identity, prompt: card.illustrationPrompt, generator: generator, newGeneration: newGeneration)
            refreshImageState()
        } catch { imageError = error.localizedDescription }
    }

    func resumeImageResult(_ record: ImageTaskRecord) {
        let generator = imageGenerator ?? MaiziImageGenerator()
        do { try imageTasks.resumeResult(id: record.id, generator: generator); refreshImageState() }
        catch { imageError = error.localizedDescription }
    }

    func cancelImageTask(_ record: ImageTaskRecord) {
        do { try imageTasks.cancel(id: record.id); refreshImageState() }
        catch { imageError = error.localizedDescription }
    }

    func selectBranch(_ branch: MeaningBranch) {
        selectedBranchID = branch.id
        selectedBranchWasExplicit = true; needsBranchSelection = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            RadialGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.75).opacity(0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 430)
                .ignoresSafeArea().allowsHitTesting(false)

            GeometryReader { geometry in
                let inset: CGFloat = geometry.size.width < 365 ? 18 : 24
                if model.showSettings {
                    ScrollView {
                        settingsPage.padding(inset).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(spacing: 0) {
                        header.padding(.horizontal, inset).padding(.top, 24).padding(.bottom, 20)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                if !model.snapshot.appFound || !model.snapshot.isTrusted || model.isShowingLastCapturedWord {
                                    connectionCard
                                }
                                wordCard
                                // A single view and material surface survive reveal, loading and streaming.
                                MemoryLinkPanelView(model: model)
                            }
                            .padding(.horizontal, inset).padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if !model.isMemoryRevealed, model.snapshot.word != nil {
                                // A gesture-only surface has no Button hover highlight and
                                // also receives taps over text and empty scroll-view margins.
                                Color.clear.contentShape(Rectangle())
                                    .onTapGesture { model.revealMemoryHelp() }
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityIdentifier("learning-area")
                        .accessibilityLabel(model.isMemoryRevealed ? "学习区域" : "查看\(model.snapshot.word ?? "当前单词")的线索")
                        .accessibilityHint(model.isMemoryRevealed ? "" : "顶部工具栏下方均可点开；已有线索立即显示，没有线索时调用已配置的模型")
                        .accessibilityAction(named: Text("查看线索")) { model.revealMemoryHelp() }
                    }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 410, maxWidth: 580, minHeight: 300)
        .preferredColorScheme(.dark)
        .animation(MemoryMotion.animation(reduceMotion: reduceMotion), value: model.showSettings)
        .sheet(isPresented: $model.showImageTasks) {
            ImageTaskListView(model: model, tasks: model.imageTasks)
        }
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
            if model.isMemoryRevealed {
                Button { model.collapseMemoryHelp() } label: { Image(systemName: "eye.slash").frame(width: 16, height: 16) }
                    .memoryGlassButtonStyle().accessibilityLabel("收起线索")
            }
            Button { model.showImageTasks = true } label: {
                Image(systemName: "photo.stack").frame(width: 16, height: 16)
                    .overlay(alignment: .topTrailing) {
                        if model.imageTasks.records.contains(where: { $0.state.isActive }) {
                            Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 5, y: -5)
                        }
                    }
            }.memoryGlassButtonStyle().accessibilityLabel("后台插画任务")
            Button { model.openSettings() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .memoryGlassButtonStyle()
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
        .padding(.top, 16)
        .padding(.bottom, 12)
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
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("开启思考模式", isOn: $model.thinkingEnabled)
                        .toggleStyle(.switch)
                        .font(.custom("Songti SC", size: 15))
                        .tint(accent)
                        .disabled(!model.supportsThinkingToggle)
                    Text(model.supportsThinkingToggle
                         ? "开启：先思考再输出；关闭：直接生成，通常更快。"
                         : "此开关仅适用于 DeepSeek 官方接口，其他接口不发送思考参数。")
                        .font(.custom("Songti SC", size: 12))
                        .foregroundStyle(muted)
                    Text("开关自动保存，下次生成生效；进行中的请求与已有卡片不变。比较速度请使用尚未生成线索的单词。")
                        .font(.custom("Songti SC", size: 11))
                        .foregroundStyle(muted)
                }
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
    let model: CompanionViewModel
    private var window: NSWindow?
    private var timer: Timer?
    private var scanInFlight = false

    override init() {
        #if DEBUG
        if (CommandLine.arguments.contains("--offline-preview") || Bundle.main.bundleIdentifier == "local.maimemo.companion.preview") {
            switch Bundle.main.object(forInfoDictionaryKey: "MaimemoPreviewScenario") as? String {
            case "response-recovery": model = CompanionLifecycleChecks.recoveryPreviewModel()
            case "image-payment": model = CompanionLifecycleChecks.paymentPreviewModel()
            case "learning-link": model = LearningPreview.model()
            case "measure-link": model = LearningPreview.model(word: "measure")
            case "president-link": model = LearningPreview.model(word: "president")
            case "legacy-link": model = LearningPreview.model(legacy: true)
            case "streaming-link": model = LearningPreview.streamingModel()
            default: model = CompanionLifecycleChecks.previewModel()
            }
        }
        else { model = CompanionViewModel() }
        #else
        model = CompanionViewModel()
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(); menu.addItem(applicationItem)
        let applicationMenu = NSMenu(); applicationItem.submenu = applicationMenu
        let reopen = NSMenuItem(title: "显示侧栏", action: #selector(reopenWindow), keyEquivalent: "0")
        reopen.target = self; applicationMenu.addItem(reopen)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "退出 Maimemo Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSApp.mainMenu = menu
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

        #if DEBUG
        if (CommandLine.arguments.contains("--offline-preview") || Bundle.main.bundleIdentifier == "local.maimemo.companion.preview") {
            window.title = "Maimemo Companion · 离线界面预览"
            let previewWidth = min(580, max(320, Bundle.main.object(forInfoDictionaryKey: "MaimemoPreviewWidth") as? Double ?? 410))
            window.setFrame(NSRect(x: 600, y: 100, width: previewWidth, height: 850), display: true)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        #endif

        refreshAndPosition()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAndPosition() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    @objc private func reopenWindow() { window?.makeKeyAndOrderFront(nil) }

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
    static func main() async throws {
        #if DEBUG
        if CommandLine.arguments.contains("--offline-check") {
            try await CompanionLifecycleChecks.run()
            return
        }
        #endif
        let application = NSApplication.shared
        let delegate = CompanionAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
