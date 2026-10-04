import SwiftUI
import WordMemoryCore

struct MemoryPanelView: View {
    @ObservedObject var model: CompanionViewModel
    @State private var forgetReason: ForgetReason = .core
    @State private var helpIndex = 0
    @State private var isDeepDiveOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.isMemoryRevealed {
                recallFirstState
            } else if let card = model.memoryCard {
                quickCard(card)
                if isDeepDiveOpen {
                    deepDive(card)
                }
            } else if let hint = model.quickHint {
                quickHintCard(hint)
            } else if model.isGenerating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在整理一条有用的线索…")
                        .font(.custom("Songti SC", size: 15))
                }
            } else {
                emptyState
            }
            if model.isMemoryRevealed, let error = model.memoryError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
        .onChange(of: model.snapshot.word) { _ in
            forgetReason = .core
            helpIndex = 0
            isDeepDiveOpen = false
        }
        .onChange(of: model.memoryCard) { _ in
            helpIndex = 0
        }
    }

    private var recallFirstState: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.snapshot.word == nil ? "等待墨墨显示当前词" : "先自己想一想")
                    .font(.custom("Songti SC", size: 18))
                Text("需要时再打开提示")
                    .font(.custom("Songti SC", size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 8)
            Button("给我线索") {
                model.revealMemoryHelp()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.snapshot.word == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有这个词的线索")
                .font(.custom("Songti SC", size: 17))
            Button(model.modelIsConfigured ? "生成一条线索" : "配置模型") {
                if model.modelIsConfigured { model.generateMemoryCard() }
                else { model.openSettings() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func quickHintCard(_ hint: QuickMemoryHint) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionLabel("抓住一个核心")
            Text(hint.coreConcept)
                .font(.custom("Songti SC", size: 21))
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(.white.opacity(0.12))
            Text(hint.branch.context)
                .font(.system(size: 16, weight: .regular, design: .serif))
                .textSelection(.enabled)
            Text("→ \(hint.branch.chineseMeaning)")
                .font(.custom("Songti SC", size: 15))
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 10) {
                if model.isGenerating { ProgressView().controlSize(.small) }
                Text("更多内容正在准备")
                    .font(.custom("Songti SC", size: 12))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
                Button(isDeepDiveOpen ? "已等待展开" : "深入理解") {
                    isDeepDiveOpen = true
                }
                .buttonStyle(.plain)
                .disabled(isDeepDiveOpen)
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func quickCard(_ card: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionLabel("抓住一个核心")
            Text(card.coreConcept)
                .font(.custom("Songti SC", size: 21))
                .fixedSize(horizontal: false, vertical: true)

            if let branch = model.selectedBranch {
                Divider().overlay(.white.opacity(0.12))
                Text(branch.context)
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .textSelection(.enabled)
                Text("→ \(branch.chineseMeaning)")
                    .font(.custom("Songti SC", size: 15))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if helpIndex > 0 {
                oneMoreCue(card)
            }

            HStack(spacing: 16) {
                Button(helpIndex == 0 ? "换个说法" : "再换一条") {
                    showNextCue(card)
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button(isDeepDiveOpen ? "收起更多" : "深入理解") {
                    isDeepDiveOpen.toggle()
                }
                .buttonStyle(.plain)
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    @ViewBuilder
    private func oneMoreCue(_ card: MemoryCard) -> some View {
        let hasImage = !card.coreImage.isEmpty
        let methodIndex = helpIndex - (hasImage ? 2 : 1)
        VStack(alignment: .leading, spacing: 5) {
            if hasImage && helpIndex == 1 {
                sectionLabel("换个画面")
                Text(card.coreImage)
                    .font(.custom("Songti SC", size: 15))
            } else if card.methods.indices.contains(methodIndex) {
                let method = card.methods[methodIndex]
                sectionLabel(method.kind.label)
                Text(method.cue)
                    .font(.custom("Songti SC", size: 15))
                if !method.isLanguageFact {
                    Text("辅助联想，不是词源或标准发音")
                        .font(.custom("Songti SC", size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func showNextCue(_ card: MemoryCard) {
        let count = card.methods.count + (card.coreImage.isEmpty ? 0 : 1)
        guard count > 0 else { return }
        helpIndex = helpIndex % count + 1
    }

    private func deepDive(_ card: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Divider().overlay(.white.opacity(0.15))
            sectionLabel("其他语境")
            ForEach(card.branches) { branch in
                Button {
                    model.selectBranch(branch)
                    helpIndex = 0
                } label: {
                    branchRow(branch, isSelected: model.selectedBranch?.id == branch.id)
                }
                .buttonStyle(.plain)
            }
            if let branch = model.selectedBranch {
                branchDetails(branch)
                memoryMethods(card.methods)
                if card.transferCheck.targetBranch == branch.meaningKey {
                    transferCheck(card.transferCheck)
                }
                feedbackSection
            }
            if let caveat = card.caveat, !caveat.isEmpty {
                Text("待核验：\(caveat)")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
            }
            generationControls
        }
    }

    private func branchRow(_ branch: MeaningBranch, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(branch.partOfSpeech) · \(branch.chineseMeaning)")
                    .font(.subheadline.weight(.semibold))
                Text(branch.signal)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
            }
            Spacer(minLength: 0)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .mint : .white.opacity(0.5))
        }
        .padding(10)
        .background(isSelected ? .white.opacity(0.16) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func branchDetails(_ branch: MeaningBranch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(branch.context)
                .font(.subheadline.weight(.medium))
                .textSelection(.enabled)
            Text(branch.explanation)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
            if let history = model.branchHistory {
                HStack(spacing: 8) {
                    Text("遇见 \(history.encounterCount) 次")
                    if let result = history.lastResult { Text("· 上次：\(result.label)") }
                    if let reason = history.forgetReason { Text("· \(reason.label)") }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                if let condition = history.lastCondition {
                    Text(condition.label)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private func memoryMethods(_ methods: [MemoryMethod]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("试哪种记法更有感觉")
            ForEach(methods) { method in
                let selected = model.branchHistory?.methodVersions.last?.method == method
                Button { model.selectMethod(method) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(method.kind.label + " · " + method.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint) }
                        }
                        Text(method.cue)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(method.whyItHelps)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.66))
                        Text(method.isLanguageFact ? "语言线索" : "个人辅助联想 · 待试用")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(selected ? .white.opacity(0.17) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if let version = model.branchHistory?.methodVersions.last {
                Text("当前沿用 V\(version.version) · \(version.method.title)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.64))
            }
        }
    }

    private func transferCheck(_ check: TransferCheck) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("换一个新句试试")
            Text(check.sentence)
                .font(.subheadline.weight(.medium))
                .textSelection(.enabled)
            if model.showAnswer {
                Text("当句意思：\(check.answer)")
                    .font(.caption)
                Text("判断线索：\(check.clue)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Button("看解释") { model.showAnswer = true }
                    .buttonStyle(.bordered)
            }
            Text("自编新句；先不看解释，想想这个词对句意做了什么。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("这一次的真实反馈")
            HStack(spacing: 6) {
                ForEach(RecallResult.allCases, id: \.self) { result in
                    Button(result.label) {
                        model.recordFeedback(result, reason: result == .forgotten ? forgetReason : nil)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }
            }
            Picker("忘在哪里", selection: $forgetReason) {
                ForEach(ForgetReason.allCases, id: \.self) { reason in
                    Text(reason.label).tag(reason)
                }
            }
            .font(.caption)
            Text("选择原因后点“又忘了”；会记录是否已经看过新句答案，只记当前词性／义项。")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("告诉我这次卡在哪里（可选）")
            TextField("例如：名词会，动词又忘了；换个画面", text: $model.learnerNote)
                .textFieldStyle(.roundedBorder)
            Picker("想试的记法", selection: $model.selectedMethodKind) {
                Text("自动推荐").tag(nil as MemoryMethodKind?)
                ForEach(MemoryMethodKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(Optional(kind))
                }
            }
            .font(.caption)
            HStack {
                Button(model.memoryCard == nil ? "生成记忆卡" : "按反馈换个办法") {
                    model.generateMemoryCard()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.snapshot.word == nil || model.isGenerating)
                if model.isGenerating { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.modelIsConfigured ? "模型设置" : "接入模型") {
                    model.openSettings()
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            if !model.modelIsConfigured {
                Text("模型尚未配置。当前词会继续实时更新；配置后由你主动点击生成。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.64))
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.65))
    }
}
