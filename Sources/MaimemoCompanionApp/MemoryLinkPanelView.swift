import AppKit
import SwiftUI
import WordMemoryCore

struct MemoryLinkPanelView: View {
    @ObservedObject var model: CompanionViewModel
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.isMemoryRevealed {
                Text("先自己想一想").font(.custom("Songti SC", size: 18))
                Text("轻触学习区域，查看线索").font(.caption).foregroundStyle(.secondary)
            } else if let card = model.memoryCard {
                cardContent(card)
                revisionControls
                illustrationArea
            } else if let hint = model.quickHint {
                Text("临时线索 · 完整卡片尚未校验保存").font(.caption2).foregroundStyle(.secondary)
                anchorContent(hint.anchor)
                coreMeaning(hint.coreConcept)
                if let branch = hint.branch { contextLine(branch) }
                if model.isGenerating { progressLine }
            } else if model.isGenerating {
                progressLine
            } else {
                Text(model.modelIsConfigured ? "线索尚未准备好" : "先接入记忆模型")
                if model.memoryError == nil {
                    Button(model.modelIsConfigured ? "生成线索 · 可能计费" : "配置模型") {
                        if model.modelIsConfigured { model.generateMemoryCard() } else { model.openSettings() }
                    }.buttonStyle(.bordered)
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
                                .buttonStyle(.bordered).font(.caption)
                        }
                    }
                    Button(model.currentFailedResponse == nil ? "重新生成 · 可能计费" : "按上次请求重新生成 · 可能计费") {
                        model.retrySelectedAnchor()
                    }.buttonStyle(.bordered).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder private func cardContent(_ card: MemoryCard) -> some View {
        if let anchor = card.anchor { anchorContent(anchor) }
        coreMeaning(card.coreConcept)
        if let analysis = card.analysis {
            if !analysis.parts.isEmpty {
                Text(analysis.parts.map(\.text).joined(separator: " + "))
                    .font(.system(size: 19, design: .serif)).textSelection(.enabled)
                ForEach(Array(analysis.parts.enumerated()), id: \.offset) { _, part in
                    HStack(alignment: .top, spacing: 8) {
                        Text(part.text).font(.system(size: 14, design: .serif))
                        Text(part.meaning ?? "剩余字母，无需另背含义").font(.custom("Songti SC", size: 12))
                        Spacer(minLength: 0)
                        Text(part.evidence == .mnemonic ? "助记" : "结构")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let change = analysis.change { Text(change).font(.custom("Songti SC", size: 13)) }
            if let reason = analysis.notSuitableReason {
                Text("这次不适合：\(reason)").font(.custom("Songti SC", size: 13)).foregroundStyle(.orange)
                if let suggestion = analysis.alternativeSuggestion {
                    Text("可尝试：\(suggestion)").font(.custom("Songti SC", size: 12)).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("为什么这样拆／相关词") {
                VStack(alignment: .leading, spacing: 9) {
                    Text(analysis.relations.map(\.label).joined(separator: " · "))
                    if let lemma = analysis.lemma { Text("原形参考：\(lemma)") }
                    Text(analysis.explanation)
                    ForEach(Array(analysis.relatedWords.enumerated()), id: \.offset) { _, related in
                        Text("\(related.word) · \(related.partOfSpeech) · \(related.meaning)（\(related.relation.label)）")
                    }
                    Text("语言分析由模型提供，尚未经词典核验；相关词不计入掌握记录")
                        .font(.caption2).foregroundStyle(.secondary)
                }.font(.custom("Songti SC", size: 12)).padding(.top, 8)
            }.font(.custom("Songti SC", size: 12))
        }
        if let caveat = card.caveat { Text(caveat).font(.caption).foregroundStyle(.secondary) }
        if card.branches.count > 1 {
            Menu("当前用法：\(model.selectedBranch?.partOfSpeech ?? "选择")") {
                ForEach(card.branches) { branch in
                    Button("\(branch.partOfSpeech) · \(branch.chineseMeaning)") { model.selectBranch(branch) }
                }
            }.font(.caption)
        }
        if let branch = model.selectedBranch { contextLine(branch) }
        DisclosureGroup("用一个新句试试") {
            VStack(alignment: .leading, spacing: 9) {
                Text(card.transferCheck.sentence).font(.system(size: 14, design: .serif))
                Button(model.showAnswer ? "隐藏答案" : "查看答案") { model.showAnswer.toggle() }
                if model.showAnswer {
                    Text(card.transferCheck.answer)
                    Text(card.transferCheck.clue).foregroundStyle(.secondary)
                }
            }.font(.custom("Songti SC", size: 12)).padding(.top, 7)
        }.font(.custom("Songti SC", size: 12))
        if model.isGenerating { progressLine }
    }

    private func anchorContent(_ anchor: MemoryAnchor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(anchor.kind.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(anchor.cue).font(.custom("Songti SC", size: 21)).fixedSize(horizontal: false, vertical: true)
            Text(anchor.explanation).font(.custom("Songti SC", size: 14)).foregroundStyle(.white.opacity(0.72))
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
            Text("换记法").font(.custom("Songti SC", size: 14))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(MemoryPreset.common) { preset in
                    Button(preset.label) { model.regenerate(preset) }
                        .font(.custom("Songti SC", size: 12)).frame(maxWidth: .infinity, minHeight: 28)
                        .buttonStyle(.bordered).disabled(model.isGenerating)
                }
            }
            Text("点击即重新生成一次，可能消耗模型用量").font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("更多调整", isExpanded: $showMore) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(MemoryPreset.allCases.filter { !MemoryPreset.common.contains($0) }) { preset in
                        Button(preset.label) { model.regenerate(preset) }.disabled(model.isGenerating)
                    }
                    Menu("切回已有记法 · 不生成") {
                        ForEach(MemoryAnchorKind.allCases.filter { model.memoryCard?.anchor(for: $0) != nil }, id: \.self) { kind in
                            Button(kind.label) { model.chooseAnchor(kind, generateImage: false) }
                        }
                    }.disabled(model.isGenerating)
                    Button("字母插画 · 准备并生图，可能计费") { model.chooseAnchor(.letterIllustration) }
                        .disabled(model.isGenerating)
                }.font(.custom("Songti SC", size: 12)).padding(.top, 8)
            }.font(.custom("Songti SC", size: 12))
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
        }
    }

    private var illustrationArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let url = model.memoryImageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityLabel("当前版本的记忆插画")
            } else if let task = model.currentImageTask {
                HStack {
                    if task.state.isActive { ProgressView().controlSize(.small) }
                    Text(task.state.label).font(.custom("Songti SC", size: 12))
                }
                if let failure = task.failure {
                    Text(failure.message).font(.caption).foregroundStyle(.orange)
                    if model.imageTasks.canResume(task) {
                        Button("继续下载／保存原结果") { model.resumeImageResult(task) }.buttonStyle(.bordered)
                    } else if !task.state.isActive {
                        Button("重新生成一张 · 可能再次计费") { model.generateCurrentIllustration(newGeneration: true) }
                            .buttonStyle(.bordered).font(.caption)
                    }
                }
            } else {
                Button("生成插画 · 可能计费") { model.generateCurrentIllustration() }
                    .buttonStyle(.bordered).font(.custom("Songti SC", size: 12))
            }
            if model.imageGenerator == nil {
                Button("配置图片服务") { model.openSettings() }.font(.caption)
            }
            if model.currentImageTask == nil, let error = model.imageError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("切词、收起或切应用后继续；文字仍可阅读与重做")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func coreMeaning(_ concept: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("抓住这个意思").font(.caption).foregroundStyle(.secondary)
            Text(concept).font(.custom("Songti SC", size: 17)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func contextLine(_ branch: MeaningBranch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(branch.context).font(.system(size: 15, design: .serif)).textSelection(.enabled)
            Text("\(branch.partOfSpeech) · 在这句里：\(branch.chineseMeaning)。\(branch.explanation)")
                .font(.custom("Songti SC", size: 13)).foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
    private var progressLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在准备线索…").font(.custom("Songti SC", size: 12)).foregroundStyle(.secondary)
        }
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
                            if let failure = task.failure { Text(failure.message).font(.caption).foregroundStyle(.orange) }
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
