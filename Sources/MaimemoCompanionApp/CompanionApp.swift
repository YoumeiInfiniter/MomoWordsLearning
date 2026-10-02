import AppKit
import SwiftUI
import MaimemoAXCore

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published private(set) var snapshot: MaimemoAXSnapshot
    @Published private(set) var lastChangeAt: Date?

    let reader: MaimemoAccessibilityReader
    private var previousWord: String?

    init(reader: MaimemoAccessibilityReader = MaimemoAccessibilityReader()) {
        self.reader = reader
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
        }
        previousWord = next.word
        snapshot = next
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

    private let blue = Color(red: 0.05, green: 0.24, blue: 0.55)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [blue, Color(red: 0.10, green: 0.40, blue: 0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectionCard
                    wordCard
                    debugCard
                    permissionCard
                }
                .padding(22)
            }
        }
        .frame(minWidth: 330, idealWidth: 360, maxWidth: 390, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Maimemo Companion")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("第一里程碑 · 只读跟词探针")
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
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
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
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
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
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
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
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
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
        let contentRect = NSRect(x: 0, y: 0, width: 360, height: 700)
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
        window.minSize = NSSize(width: 330, height: 560)
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
