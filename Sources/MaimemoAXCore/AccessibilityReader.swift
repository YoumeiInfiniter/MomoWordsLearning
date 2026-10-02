import AppKit
import ApplicationServices

public struct AXTextCandidate: Sendable {
    public let text: String
    public let role: String
    public let sourceAttribute: String
    public let score: Double
    public let frame: CGRect

    public init(text: String, role: String, sourceAttribute: String, score: Double, frame: CGRect) {
        self.text = text
        self.role = role
        self.sourceAttribute = sourceAttribute
        self.score = score
        self.frame = frame
    }
}

public struct MaimemoAXSnapshot: Sendable {
    public let appFound: Bool
    public let appName: String
    public let isTrusted: Bool
    public let word: String?
    public let windowFrame: CGRect?
    public let nodeCount: Int
    public let candidates: [AXTextCandidate]
    public let scannedAt: Date
    public let diagnostic: String

    public init(
        appFound: Bool,
        appName: String,
        isTrusted: Bool,
        word: String?,
        windowFrame: CGRect?,
        nodeCount: Int,
        candidates: [AXTextCandidate],
        scannedAt: Date,
        diagnostic: String
    ) {
        self.appFound = appFound
        self.appName = appName
        self.isTrusted = isTrusted
        self.word = word
        self.windowFrame = windowFrame
        self.nodeCount = nodeCount
        self.candidates = candidates
        self.scannedAt = scannedAt
        self.diagnostic = diagnostic
    }
}

/// Read-only bridge to the running Maimemo Mac wrapper.
///
/// This type never writes an AX attribute and never performs a click or key event.
@MainActor
public final class MaimemoAccessibilityReader {
    public static let maimemoBundleIdentifier = "com.maimemo.ios.momo"
    public static let maimemoPath = "/Applications/Maimemo.app"

    private let workspace: NSWorkspace
    private let excludedWords: Set<String> = [
        "back", "cancel", "close", "confirm", "continue", "delete", "done", "edit",
        "enter", "exit", "finish", "forward", "history", "home", "more", "next",
        "no", "pause", "play", "previous", "reset", "review", "save", "search",
        "settings", "skip", "start", "stop", "submit", "today", "yes"
    ]

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func requestPermissionPrompt() {
        // The public constant is an imported mutable CF global in the current SDK,
        // which Swift 6 treats as non-concurrency-safe. Its documented key is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        workspace.open(url)
    }

    public func scan() -> MaimemoAXSnapshot {
        let trusted = AXIsProcessTrusted()
        let runningApp = workspace.runningApplications.first {
            $0.bundleIdentifier == Self.maimemoBundleIdentifier
        }

        guard let runningApp else {
            return MaimemoAXSnapshot(
                appFound: false,
                appName: "墨墨",
                isTrusted: trusted,
                word: nil,
                windowFrame: nil,
                nodeCount: 0,
                candidates: [],
                scannedAt: Date(),
                diagnostic: "未找到运行中的墨墨（bundle id: \(Self.maimemoBundleIdentifier)）"
            )
        }

        guard trusted else {
            return MaimemoAXSnapshot(
                appFound: true,
                appName: runningApp.localizedName ?? "墨墨",
                isTrusted: false,
                word: nil,
                windowFrame: nil,
                nodeCount: 0,
                candidates: [],
                scannedAt: Date(),
                diagnostic: "已找到墨墨，但当前进程没有辅助功能权限"
            )
        }

        let application = AXUIElementCreateApplication(runningApp.processIdentifier)
        let window = focusedWindow(in: application) ?? firstWindow(in: application)
        let root = window ?? application
        var context = ScanContext()
        visit(root, context: &context, depth: 0, windowFrame: nil)

        let ranked = context.candidates
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.text < rhs.text }
                return lhs.score > rhs.score
            }
            .prefix(8)

        let candidates = Array(ranked)
        let word = candidates.first?.text
        let frame = context.windowFrame
        let diagnostic: String
        if let word {
            diagnostic = "读取 \(context.nodeCount) 个节点，最佳候选：\(word)"
        } else {
            diagnostic = "读取 \(context.nodeCount) 个节点，未找到单个英文单词候选"
        }

        return MaimemoAXSnapshot(
            appFound: true,
            appName: runningApp.localizedName ?? "墨墨",
            isTrusted: true,
            word: word,
            windowFrame: frame,
            nodeCount: context.nodeCount,
            candidates: candidates,
            scannedAt: Date(),
            diagnostic: diagnostic
        )
    }

    private struct ScanContext {
        var nodeCount = 0
        var sequence = 0
        var candidates: [AXTextCandidate] = []
        var windowFrame: CGRect?
        var seenTexts = Set<String>()
    }

    private func focusedWindow(in application: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(application, kAXFocusedWindowAttribute as String) else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func firstWindow(in application: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(application, kAXWindowsAttribute as String),
              let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows.first
    }

    private func visit(
        _ element: AXUIElement,
        context: inout ScanContext,
        depth: Int,
        windowFrame: CGRect?
    ) {
        guard depth < 40, context.nodeCount < 2_000 else { return }
        context.nodeCount += 1
        context.sequence += 1

        let role = stringValue(copyAttribute(element, kAXRoleAttribute as String)) ?? ""
        let frame = axFrame(of: element) ?? windowFrame
        if role == kAXWindowRole as String, let frame {
            context.windowFrame = frame
        } else if context.windowFrame == nil, let frame = windowFrame {
            context.windowFrame = frame
        }

        let attributes = [
            kAXTitleAttribute as String,
            kAXValueAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String
        ]
        for attribute in attributes {
            guard let raw = copyAttribute(element, attribute),
                  let text = stringValue(raw),
                  let normalized = normalizedWord(text),
                  !context.seenTexts.contains(normalized) else {
                continue
            }
            context.seenTexts.insert(normalized)
            let score = score(
                text: normalized,
                role: role,
                sourceAttribute: attribute,
                frame: frame,
                sequence: context.sequence,
                windowFrame: context.windowFrame
            )
            context.candidates.append(
                AXTextCandidate(
                    text: normalized,
                    role: role,
                    sourceAttribute: attribute,
                    score: score,
                    frame: frame ?? .zero
                )
            )
        }

        guard let childrenValue = copyAttribute(element, kAXChildrenAttribute as String),
              let children = childrenValue as? [AXUIElement] else {
            return
        }
        for child in children {
            visit(child, context: &context, depth: depth + 1, windowFrame: frame ?? windowFrame)
        }
    }

    private func normalizedWord(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({
            CharacterSet.letters.contains($0) || $0 == "-" || $0 == "'"
        }) else {
            return nil
        }
        let lowercase = trimmed.lowercased()
        guard lowercase.range(of: "^[a-z][a-z'-]*$", options: .regularExpression) != nil else {
            return nil
        }
        guard !excludedWords.contains(lowercase) else { return nil }
        return lowercase
    }

    private func score(
        text: String,
        role: String,
        sourceAttribute: String,
        frame: CGRect?,
        sequence: Int,
        windowFrame: CGRect?
    ) -> Double {
        var value = 25.0
        if role == kAXStaticTextRole as String { value += 45 }
        if role == kAXHeadingRole as String { value += 30 }
        if sourceAttribute == kAXValueAttribute as String { value += 8 }
        if let frame {
            value += min(frame.height, 80) * 1.6
            value += min(frame.width, 300) * 0.04
            if let windowFrame {
                let relativeY = max(0, frame.midY - windowFrame.minY)
                let relativeHeight = max(windowFrame.height, 1)
                if relativeY < relativeHeight * 0.42 { value += 35 }
            }
        }
        value -= Double(sequence) * 0.012
        if text.count > 20 { value -= 10 }
        return value
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func stringValue(_ value: CFTypeRef?) -> String? {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute as String),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as String),
              let position = cgPoint(from: positionValue),
              let size = cgSize(from: sizeValue) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func cgPoint(from value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func cgSize(from value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
