import AppKit
import SwiftUI
import WordMemoryCore

/// V2 keeps one word-to-meaning hook and one context, leaving dictionary work to the host app.
struct MemoryLinkPanelView: View {
    @ObservedObject var model: CompanionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.isMemoryRevealed {
                recallFirstState
            } else if let card = model.memoryCard {
                cardContent(card)
            } else if let hint = model.quickHint {
                anchorContent(hint.anchor, word: hint.word, imageURL: nil)
                coreMeaning(hint.coreConcept)
                if let branch = hint.branch { contextLine(branch) }
                progressLine
            } else if model.isGenerating {
                progressLine
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
    }

    private var recallFirstState: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.snapshot.word == nil ? "等待墨墨显示当前词" : "先自己想一想")
                    .font(.custom("Songti SC", size: 18))
                Text(model.snapshot.word == nil ? "捕获到单词后即可查看联想" : "轻触学习区域，记住这个词")
                    .font(.custom("Songti SC", size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 8)
            if model.snapshot.word != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.07), in: Circle())
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func cardContent(_ card: MemoryCard) -> some View {
        if let anchor = card.anchor {
            anchorContent(anchor, word: card.word, imageURL: model.memoryImageURL)
        } else {
            Text("这张旧卡还没有词形联想")
                .font(.custom("Songti SC", size: 16))
            Button("按新方式重做") { model.generateMemoryCard() }
                .buttonStyle(.bordered)
                .disabled(model.isGenerating)
        }
        coreMeaning(card.coreConcept)
        if let branch = card.branches.first { contextLine(branch) }
    }

    @ViewBuilder
    private func anchorContent(_ anchor: MemoryAnchor, word: String, imageURL: URL?) -> some View {
        Text(anchor.kind == .sound ? "声音联想" : "字母插画")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.57))
        if anchor.kind == .letterIllustration {
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("\(word) 的字母联想插画")
            } else {
                Text(word)
                    .font(.system(size: 38, weight: .regular, design: .serif))
                    .tracking(2)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                if model.isCheckingImageAPIKey {
                    Text("正在确认图片服务…")
                        .font(.custom("Songti SC", size: 11))
                        .foregroundStyle(.white.opacity(0.53))
                } else if model.isGeneratingCurrentImage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在绘制字母插画…")
                    }
                    .font(.custom("Songti SC", size: 11))
                } else if let error = model.imageError {
                    Text("插画未完成：\(error)")
                        .font(.custom("Songti SC", size: 11))
                        .foregroundStyle(.orange)
                    Button("重试插画") { model.retryMemoryImage() }
                        .buttonStyle(.bordered)
                } else if model.imageGenerator == nil {
                    Text("未配置图片生成 Key，先看构图联想")
                        .font(.custom("Songti SC", size: 11))
                        .foregroundStyle(.white.opacity(0.53))
                    Button("配置图片服务") { model.openSettings() }
                        .buttonStyle(.bordered)
                } else {
                    Text("插画将在联想确认后生成")
                        .font(.custom("Songti SC", size: 11))
                        .foregroundStyle(.white.opacity(0.53))
                }
            }
        }
        Text(anchor.cue)
            .font(.custom("Songti SC", size: 21))
            .fixedSize(horizontal: false, vertical: true)
        Text(anchor.explanation)
            .font(.custom("Songti SC", size: 14))
            .foregroundStyle(.white.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
        if anchor.kind == .sound {
            Text("辅助谐音，不是标准发音或词源")
                .font(.custom("Songti SC", size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func coreMeaning(_ concept: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(.white.opacity(0.12))
            Text("抓住这个意思")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.57))
            Text(concept)
                .font(.custom("Songti SC", size: 17))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contextLine(_ branch: MeaningBranch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(branch.context)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .textSelection(.enabled)
            Text("在这句里：\(branch.chineseMeaning)。\(branch.explanation)")
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private var progressLine: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在补全这条联想…")
                .font(.custom("Songti SC", size: 13))
                .foregroundStyle(.white.opacity(0.68))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.isCheckingStoredAPIKey ? "正在确认模型设置…" :
                 model.modelIsConfigured ? "联想暂时没有准备好" : "先接入记忆模型")
                .font(.custom("Songti SC", size: 17))
            if model.isCheckingStoredAPIKey {
                ProgressView().controlSize(.small)
            } else {
                Button(model.modelIsConfigured ? "重试生成" : "配置模型") {
                    if model.modelIsConfigured { model.generateMemoryCard() }
                    else { model.openSettings() }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
