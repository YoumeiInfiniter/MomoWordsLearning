import AppKit
import SwiftUI
import WordMemoryCore

struct MemoryLinkPanelView: View {
    @ObservedObject var model: CompanionViewModel
    @State private var showMore = false
    @State private var showAdjustments = false
    @State private var showDetails = false
    @State private var showPractice = false
    @State private var presentation: LearningPresentation = .text
    @State private var panelHeight: CGFloat = 82
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var presentationSelection

    private enum LearningPresentation: String, CaseIterable {
        case text, image
        var label: String { self == .text ? "文字记法" : "图像记法" }
        var symbol: String { self == .text ? "text.alignleft" : "photo" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isMemoryRevealed {
                waitingContent(loading: false).transition(.identity)
            } else if model.memoryCard != nil || model.quickHint != nil {
                presentationPicker
                Group {
                    if presentation == .text { textMethod }
                    else if let card = model.memoryCard { illustrationArea(card) }
                }.transition(.identity)
                sharedMeaning
                if let card = model.memoryCard {
                    memoryDetails(card)
                    revisionControls
                } else {
                    Text("首条线索已到达 · 完整卡片尚未校验保存")
                        .font(.caption2).foregroundStyle(MemoryPalette.secondary)
                    if model.isGenerating { progressLine }
                }
            } else if model.isGenerating {
                waitingContent(loading: true).transition(.identity)
            } else {
                Text(model.modelIsConfigured ? "线索尚未准备好" : "先接入记忆模型")
                if model.memoryError == nil {
                    Button(model.modelIsConfigured ? "生成线索 · 可能计费" : "配置模型") {
                        if model.modelIsConfigured { model.generateMemoryCard() } else { model.openSettings() }
                    }.memoryGlassButtonStyle(prominent: true)
                }
            }
            if model.isMemoryRevealed, let error = model.memoryError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.isGenerating {
                    if model.quickHint != nil {
                        Text("首条线索仍可查看；完整卡片尚未保存").font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.currentFailedResponse != nil {
                        Text("已接收的回答保留在本机；本地解析不产生模型用量")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.canReparseCurrentResponse {
                            Button("重新解析已接收内容 · 不调用模型") { model.reparseReceivedResponse() }
                                .memoryGlassButtonStyle()
                        }
                    }
                    Button(model.currentFailedResponse == nil ? "重新生成 · 可能计费" : "按上次请求重新生成 · 可能计费") {
                        model.retrySelectedAnchor()
                    }.memoryGlassButtonStyle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 54, alignment: .topLeading)
        .padding(14)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MemoryPanelHeightKey.self, value: geometry.size.height)
        })
        .fixedSize(horizontal: false, vertical: true)
        // Only the containing surface changes height. Text keeps its natural layout
        // and is revealed by the growing clip, without fading/replacing the glass.
        .frame(height: panelHeight, alignment: .top)
        .clipped()
        .memoryGlass(cornerRadius: 25)
        .disclosureGroupStyle(MemoryDisclosureStyle())
        .onPreferenceChange(MemoryPanelHeightKey.self) { height in
            guard height > 0, abs(panelHeight - height) > 0.5 else { return }
            withAnimation(MemoryMotion.animation(reduceMotion: reduceMotion)) { panelHeight = height }
        }
        .onChange(of: model.snapshot.word) { _ in resetPresentation() }
        .onChange(of: model.isMemoryRevealed) { revealed in if !revealed { resetPresentation() } }
        .onChange(of: model.memoryCard?.versionKey) { _ in resetDetails() }
    }

    private func waitingContent(loading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(loading ? "正在准备线索…" : "先自己想一想")
                    .font(.custom("Songti SC", size: 18))
                if loading { ProgressView().controlSize(.mini) }
            }
            Text(loading ? "收到内容后，在这里逐步展开" : "轻触学习区域，查看线索")
                .font(.caption).foregroundStyle(MemoryPalette.secondary)
        }
    }

    private func resetPresentation() {
        presentation = .text
        showMore = false
        showAdjustments = false
        resetDetails()
    }

    private func resetDetails() {
        showDetails = false
        showPractice = false
    }

    private var presentationPicker: some View {
        HStack(spacing: 4) {
            ForEach(LearningPresentation.allCases, id: \.self) { item in
                Button {
                    withAnimation(MemoryMotion.animation(reduceMotion: reduceMotion)) { presentation = item }
                } label: {
                    Label(item.label, systemImage: item.symbol)
                        .font(.custom("Songti SC", size: 13))
                        .foregroundStyle(presentation == item ? MemoryPalette.cue : MemoryPalette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background {
                            if presentation == item {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(.white.opacity(0.10))
                                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.14)))
                                    .matchedGeometryEffect(id: "presentation", in: presentationSelection)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .disabled(item == .image && model.memoryCard == nil)
                .accessibilityAddTraits(presentation == item ? [.isSelected] : [])
                .accessibilityHint(item == .image ? "只切换展示；生成图片需另行点击" : "查看原词如何连接到意思")
            }
        }
        .padding(4)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.055)))
    }

    @ViewBuilder private var textMethod: some View {
        let card = model.memoryCard
        let hint = model.quickHint
        let kind = card?.anchor?.kind ?? hint?.anchor.kind
        if let link = card?.wordLink ?? hint?.wordLink {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel(kind?.label ?? "从原词认出意思", symbol: "link")
                Text(MemoryPanelCopy.cue(link.cue, source: link.source))
                    .font(.custom("Songti SC", size: 16)).foregroundStyle(MemoryPalette.cue)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(link.connection).font(.custom("Songti SC", size: 14)).foregroundStyle(MemoryPalette.body)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .memoryGlass(cornerRadius: 16, prominence: .subtle)
            if kind == .sound || kind == .hybrid {
                Text("声音联想是助记，不是标准发音或词源").font(.caption2).foregroundStyle(MemoryPalette.secondary)
            }
        } else if let card {
            legacyUpgrade("这份旧记法尚未记录原词联系")
            if let anchor = card.anchor { anchorContent(anchor) }
        } else if let hint {
            anchorContent(hint.anchor)
        }
        if card?.analysis?.notSuitableReason != nil {
            Button {
                withAnimation(MemoryMotion.animation(reduceMotion: reduceMotion)) { showDetails = true }
            } label: {
                Label("本次记法不适用 · 查看细节", systemImage: "exclamationmark.circle")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
        }
        if card != nil && model.isGenerating { progressLine }
    }

    private func memoryDetails(_ card: MemoryCard) -> some View {
        DisclosureGroup((card.analysis?.parts.count ?? 0) > 1 ? "拆词与记忆细节" : "记忆细节",
                        isExpanded: $showDetails.animation(MemoryMotion.animation(reduceMotion: reduceMotion))) {
            VStack(alignment: .leading, spacing: 11) {
                if let link = card.wordLink { recallLine(link.recall) }
                if let anchor = card.anchor, let link = card.wordLink,
                   anchor.cue != link.cue || anchor.explanation != link.connection {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("这条联想").font(.caption2).foregroundStyle(MemoryPalette.secondary)
                        Text(anchor.cue).font(.custom("Songti SC", size: 14)).foregroundStyle(MemoryPalette.cue)
                        Text(anchor.explanation).font(.custom("Songti SC", size: 13)).foregroundStyle(MemoryPalette.body)
                    }
                }
                if let analysis = card.analysis {
                    if !analysis.parts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(analysis.parts.map(\.text).joined(separator: " + "))
                                .font(.system(size: 16, design: .serif)).foregroundStyle(MemoryPalette.cue)
                                .textSelection(.enabled)
                            ForEach(Array(analysis.parts.enumerated()), id: \.offset) { _, part in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text(part.text).font(.system(size: 13, weight: .medium, design: .serif))
                                        .foregroundStyle(MemoryPalette.cue)
                                    Text(part.meaning ?? "剩余字母，无需另背含义")
                                        .font(.custom("Songti SC", size: 12)).foregroundStyle(MemoryPalette.body)
                                    Spacer(minLength: 0)
                                    Text(part.evidence == .mnemonic ? "助记" : "结构")
                                        .font(.caption2).foregroundStyle(MemoryPalette.secondary)
                                }
                            }
                        }
                    }
                    if let change = analysis.change { Text(change).foregroundStyle(MemoryPalette.body) }
                    if let reason = analysis.notSuitableReason {
                        Text("这次不适合：\(reason)").foregroundStyle(.orange)
                        if let suggestion = analysis.alternativeSuggestion {
                            Text("可尝试：\(suggestion)").foregroundStyle(MemoryPalette.secondary)
                        }
                    }
                    Text(analysis.relations.map(\.label).joined(separator: " · "))
                        .foregroundStyle(MemoryPalette.cue)
                    if let lemma = analysis.lemma { Text("原形参考：\(lemma)") }
                    if analysis.explanation != card.wordLink?.connection && analysis.explanation != card.anchor?.explanation {
                        Text(analysis.explanation)
                    }
                    ForEach(Array(analysis.relatedWords.enumerated()), id: \.offset) { _, related in
                        Text("\(related.word) · \(related.partOfSpeech) · \(related.meaning)（\(related.relation.label)）")
                    }
                    Text("语言分析由模型提供，尚未经词典核验；相关词不计入掌握记录")
                        .font(.caption2).foregroundStyle(MemoryPalette.secondary)
                }
                if let caveat = card.caveat { Text(caveat).foregroundStyle(MemoryPalette.secondary) }
            }
            .font(.custom("Songti SC", size: 12)).foregroundStyle(MemoryPalette.body)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        .font(.custom("Songti SC", size: 12)).foregroundStyle(MemoryPalette.secondary).tint(MemoryPalette.cue)
    }

    @ViewBuilder private var sharedMeaning: some View {
        let card = model.memoryCard
        if let concept = card?.coreConcept ?? model.quickHint?.coreConcept { coreMeaning(concept) }
        if card?.caveat != nil {
            Button {
                withAnimation(MemoryMotion.animation(reduceMotion: reduceMotion)) { showDetails = true }
            } label: {
                Label("词义有补充说明 · 查看细节", systemImage: "info.circle")
            }.buttonStyle(.plain).font(.caption2).foregroundStyle(MemoryPalette.secondary)
        }
        if let card, card.branches.count > 1 {
            Menu("当前用法：\(model.selectedBranch?.partOfSpeech ?? "选择")") {
                ForEach(card.branches) { branch in
                    Button("\(branch.partOfSpeech) · \(branch.chineseMeaning)") { model.selectBranch(branch) }
                }
            }.font(.caption)
        }
        if let branch = model.selectedBranch ?? model.quickHint?.branch { contextLine(branch) }
        if let card {
            DisclosureGroup("用一个新句试试", isExpanded: $showPractice.animation(MemoryMotion.animation(reduceMotion: reduceMotion))) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(card.transferCheck.sentence).font(.system(size: 14, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    Button(model.showAnswer ? "隐藏答案" : "查看答案") {
                        withAnimation(MemoryMotion.animation(reduceMotion: reduceMotion)) { model.showAnswer.toggle() }
                    }.memoryGlassButtonStyle()
                    if model.showAnswer {
                        Text(card.transferCheck.answer)
                        Text(card.transferCheck.clue).foregroundStyle(.secondary)
                    }
                }.font(.custom("Songti SC", size: 12)).padding(.top, 7)
            }.font(.custom("Songti SC", size: 12)).foregroundStyle(MemoryPalette.secondary).tint(MemoryPalette.context)
        }
    }

    private func anchorContent(_ anchor: MemoryAnchor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(anchor.kind.label).font(.caption2.weight(.medium)).foregroundStyle(MemoryPalette.secondary)
            Text(anchor.cue).font(.custom("Songti SC", size: 16)).foregroundStyle(MemoryPalette.cue)
                .fixedSize(horizontal: false, vertical: true)
            Text(anchor.explanation).font(.custom("Songti SC", size: 14)).foregroundStyle(MemoryPalette.body)
                .fixedSize(horizontal: false, vertical: true)
            if anchor.kind == .sound || anchor.kind == .hybrid {
                Text("声音联想是助记，不是标准发音或词源").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var revisionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Button("上一条") { model.moveHistory(by: -1) }
                    .disabled(model.isGenerating || !model.cardHistory.canMove(by: -1))
                Spacer(minLength: 0)
                Text("\(model.cardHistory.selectedIndex + 1) / \(model.cardHistory.cards.count)")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("下一条") { model.moveHistory(by: 1) }
                    .disabled(model.isGenerating || !model.cardHistory.canMove(by: 1))
            }.font(.custom("Songti SC", size: 12)).buttonStyle(.plain)
            DisclosureGroup("换个记法", isExpanded: $showAdjustments) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("选择后重新生成一次，可能消耗模型用量").font(.caption2).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MemoryPreset.common) { preset in
                            Button { model.regenerate(preset) } label: {
                                Text(preset.label).frame(maxWidth: .infinity)
                            }.memoryGlassButtonStyle().disabled(model.isGenerating)
                        }
                    }
                    DisclosureGroup("更多调整", isExpanded: $showMore) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(MemoryPreset.allCases.filter { !MemoryPreset.common.contains($0) }) { preset in
                                Button(preset.label) { model.regenerate(preset) }.disabled(model.isGenerating)
                            }
                            Menu("切回已有版本 · 不生成") {
                                ForEach(Array(model.cardHistory.cards.enumerated()), id: \.offset) { index, card in
                                    Button("第 \(index + 1) 条 · \(card.anchor?.kind.label ?? "已有线索")") { model.selectHistoryVersion(at: index) }
                                }
                            }.disabled(model.isGenerating)
                        }
                        .font(.custom("Songti SC", size: 12)).padding(.top, 8)
                    }.disclosureGroupStyle(MemoryDisclosureStyle())
                    if model.needsBranchSelection {
                        Text("先选择要补的词性和义项，再点击“只补这个用法”").font(.caption).foregroundStyle(.orange)
                    }
                    HStack(spacing: 6) {
                        ForEach(RevisionReasonTag.allCases, id: \.self) { tag in
                            Button(tag.label) {
                                if model.reasonTags.contains(tag) { model.reasonTags.remove(tag) }
                                else { model.reasonTags.insert(tag) }
                            }
                            .font(.custom("Songti SC", size: 10)).buttonStyle(.plain)
                            .padding(6).background(model.reasonTags.contains(tag) ? .white.opacity(0.18) : .white.opacity(0.055), in: Capsule())
                            .disabled(model.isGenerating)
                        }
                    }
                    TextField("额外补充（可不填）", text: $model.learnerNote)
                        .font(.custom("Songti SC", size: 12)).textFieldStyle(.roundedBorder).disabled(model.isGenerating)
                }.padding(.top, 10)
            }.font(.custom("Songti SC", size: 13))
        }
    }

    private func illustrationArea(_ card: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let url = model.memoryImageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
                    .accessibilityLabel("\(card.word) 的记忆插画；下方有画面对应解释")
            }
            if let plan = card.illustration {
                VStack(alignment: .leading, spacing: 9) {
                    sectionLabel(model.memoryImageURL == nil ? "这张图会怎样记住原词" : "画面怎样对应原词", symbol: "sparkle")
                    Text(plan.scene).font(.custom("Songti SC", size: 16)).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(plan.mappings.enumerated()), id: \.offset) { _, mapping in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(mapping.source).font(.system(size: 15, weight: .medium, design: .serif)).textSelection(.enabled)
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(mapping.visual).font(.custom("Songti SC", size: 13))
                            }
                            Text(mapping.meaning).font(.custom("Songti SC", size: 12)).foregroundStyle(.white.opacity(0.67))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    Text(plan.explanation).font(.custom("Songti SC", size: 14)).foregroundStyle(.white.opacity(0.79))
                        .fixedSize(horizontal: false, vertical: true)
                    recallLine(plan.recall)
                }
            } else {
                legacyUpgrade(model.memoryImageURL == nil ? "这份旧记法尚未记录图片映射" : "这是旧版插画，尚未记录对应的原词映射")
            }
            if let task = model.currentImageTask, task.state != .completed {
                HStack {
                    if task.state.isActive { ProgressView().controlSize(.small) }
                    Text(task.state.label).font(.custom("Songti SC", size: 12))
                }
                if let failure = task.failure {
                    Text(failure.userMessage).font(.caption).foregroundStyle(.orange)
                    if failure.isPaymentRequired {
                        Link("查看 MaiziAI 账户", destination: URL(string: "https://www.maizitech.ai/")!).font(.caption)
                        Button("检查图片 Key 设置") { model.openSettings() }.font(.caption)
                    }
                    if model.imageTasks.canResume(task) {
                        Button("继续下载／保存原结果") { model.resumeImageResult(task) }.memoryGlassButtonStyle()
                    } else if !task.state.isActive, card.illustration != nil {
                        Button(failure.isPaymentRequired ? "处理后重新提交 · 可能计费" : "重新生成一张 · 可能再次计费") { model.generateCurrentIllustration(newGeneration: true) }
                            .memoryGlassButtonStyle()
                    }
                }
            } else if model.memoryImageURL == nil, card.illustration != nil {
                Button("生成插画 · 可能计费") { model.generateCurrentIllustration() }
                    .memoryGlassButtonStyle(prominent: true)
            }
            if model.imageGenerator == nil, card.illustration != nil {
                Button("配置图片服务") { model.openSettings() }.font(.caption)
            }
            if model.currentImageTask == nil, let error = model.imageError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if card.illustration != nil {
                Text("生成需另行点击；开始后可切词、收起或切换记法")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if model.isGenerating { progressLine }
        }
    }

    private func legacyUpgrade(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(message).font(.custom("Songti SC", size: 13)).foregroundStyle(.white.opacity(0.66))
            Button("补齐原词联系 · 可能计费") { model.upgradeCurrentLearningLink() }
                .memoryGlassButtonStyle().disabled(model.isGenerating)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption2.weight(.medium)).foregroundStyle(MemoryPalette.cue.opacity(0.82))
    }

    private func recallLine(_ recall: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("下次看到原词").font(.caption2).foregroundStyle(MemoryPalette.secondary)
            Text(recall).font(.custom("Songti SC", size: 13)).foregroundStyle(MemoryPalette.body)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 3)
    }

    private func coreMeaning(_ concept: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("抓住共同的意思").font(.caption2).foregroundStyle(MemoryPalette.meaning.opacity(0.8))
            Text(concept).font(.custom("Songti SC", size: 16)).foregroundStyle(MemoryPalette.meaning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func contextLine(_ branch: MeaningBranch) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(branch.context).font(.system(size: 14, design: .serif)).foregroundStyle(MemoryPalette.context)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(branch.partOfSpeech).font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(MemoryPalette.context.opacity(0.84))
                Text(branch.chineseMeaning).font(.custom("Songti SC", size: 12))
                    .foregroundStyle(MemoryPalette.meaning)
            }.fixedSize(horizontal: false, vertical: true)
            Text(branch.explanation).font(.custom("Songti SC", size: 12)).foregroundStyle(MemoryPalette.body)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .memoryGlass(cornerRadius: 16, prominence: .subtle)
    }
    private var progressLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在准备线索…").font(.custom("Songti SC", size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Presentation-only removal of a redundant word label; actual phrases remain intact.
enum MemoryPanelCopy {
    static func cue(_ cue: String, source: String) -> String {
        let text = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              let word = text.range(of: source, options: [.anchored, .caseInsensitive]) else { return text }
        let remainder = text[word.upperBound...]
        for delimiter in [" 的", "的", "：", ":"] where remainder.hasPrefix(delimiter) {
            let compact = remainder.dropFirst(delimiter.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !compact.isEmpty { return compact }
        }
        return text
    }
}

struct ImageTaskListView: View {
    @ObservedObject var model: CompanionViewModel
    @ObservedObject var tasks: ImageTaskManager
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("后台插画任务").font(.title3)
                Spacer()
                Button("返回") { model.showImageTasks = false }
            }
            Text("关闭窗口继续运行；退出应用会中断等待，重启不会自动重复计费生成。")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = tasks.storageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tasks.records.isEmpty { Text("暂无任务").foregroundStyle(.secondary) }
                    ForEach(tasks.records.reversed()) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(task.identity.word) · \(task.state.label)")
                            Text("版本 \(task.identity.versionID.prefix(8)) · \(task.updatedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let failure = task.failure { Text(failure.userMessage).font(.caption).foregroundStyle(.orange) }
                            if task.state.isActive {
                                Button(task.state == .queued ? "取消排队" : "停止本地等待 · 远端可能计费") { model.cancelImageTask(task) }
                                    .font(.caption)
                            } else if tasks.canResume(task) {
                                Button("继续下载／保存原结果") { model.resumeImageResult(task) }.font(.caption)
                            }
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(minWidth: 300, idealWidth: 370, minHeight: 300, idealHeight: 470)
    }
}
