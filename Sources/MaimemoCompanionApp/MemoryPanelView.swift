import SwiftUI
import WordMemoryCore

struct MemoryPanelView: View {
    @ObservedObject var model: CompanionViewModel
    @State private var forgetReason: ForgetReason = .core

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            if !model.isMemoryRevealed {
                recallFirstState
            } else {
                if let card = model.memoryCard {
                    cardContents(card)
                } else {
                    emptyState
                }
                generationControls
                if let error = model.memoryError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
        .onChange(of: model.snapshot.word) { _ in
            forgetReason = .core
        }
    }

    private var titleRow: some View {
        HStack {
            Text("记住这个词")
                .font(.custom("Songti SC", size: 22))
            Spacer()
            if model.memoryCard != nil && model.isMemoryRevealed {
                Text("本地已保存")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private var recallFirstState: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(model.snapshot.word == nil ? "等待墨墨显示当前词" : "先给自己几秒钟，回忆它的意思。")
                .font(.custom("Songti SC", size: 17))
            Text("需要线索时，再看核心关系、语境和联想。")
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(.white.opacity(0.68))
            Button("查看速记方法") {
                model.revealMemoryHelp()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.snapshot.word == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.snapshot.word == nil ? "先等待墨墨显示当前词" : "还没有这个词的记忆卡")
                .font(.subheadline.weight(.semibold))
            Text("生成后先看一个通性的核心关系，再看它怎样进入不同句子。记法可选，只有你的反馈才会成为个人记录。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cardContents(_ card: MemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("一个核心关系")
                Text(card.coreConcept)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(card.coreImage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
            }

            Divider().overlay(.white.opacity(0.15))

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("放进句子，意思怎样变")
                ForEach(card.branches) { branch in
                    Button { model.selectBranch(branch) } label: {
                        branchRow(branch, isSelected: model.selectedBranch?.id == branch.id)
                    }
                    .buttonStyle(.plain)
                }
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
