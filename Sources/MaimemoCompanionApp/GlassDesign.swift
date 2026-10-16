import SwiftUI

/// Small, readable accents that retain the dark blue glass theme.
enum MemoryPalette {
    static let cue = Color(red: 0.68, green: 0.82, blue: 0.97)
    static let meaning = Color(red: 0.96, green: 0.84, blue: 0.65)
    static let body = Color(red: 0.83, green: 0.87, blue: 0.92)
    static let context = Color(red: 0.65, green: 0.87, blue: 0.83)
    static let secondary = Color(red: 0.61, green: 0.69, blue: 0.78)
}

enum MemoryGlassProminence {
    case subtle, regular, raised
}

enum MemoryMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9)
    }
}

/// macOS's default disclosure only toggles its small triangle. Make the entire
/// heading one quiet button, including its label and trailing space.
struct MemoryDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(MemoryMotion.animation(reduceMotion: reduceMotion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 16).transition(.identity)
            }
        }
    }
}

/// A quiet, stationary glass surface; movement is reserved for deliberate interaction.
private struct MemoryGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let prominence: MemoryGlassProminence

    private var highlight: Double {
        switch prominence { case .subtle: 0.045; case .regular: 0.075; case .raised: 0.11 }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(red: 0.105, green: 0.14, blue: 0.19))
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .background(shape.fill(Color(red: 0.07, green: 0.105, blue: 0.16).opacity(0.6)))
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(highlight), .clear, Color(red: 0.48, green: 0.65, blue: 0.85).opacity(highlight * 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(highlight + 0.13), .white.opacity(0.045), .white.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(prominence == .subtle ? 0.08 : 0.16), radius: prominence == .raised ? 20 : 12, x: 0, y: 7)
    }
}

private struct MemoryGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Songti SC", size: 12))
            .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.35))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(reduceTransparency ? 0.13 : configuration.isPressed ? 0.16 : prominent ? 0.115 : 0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.24 : prominent ? 0.18 : 0.085), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(MemoryMotion.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    func memoryGlass(cornerRadius: CGFloat = 24, prominence: MemoryGlassProminence = .regular) -> some View {
        modifier(MemoryGlassSurface(cornerRadius: cornerRadius, prominence: prominence))
    }

    func memoryGlassButtonStyle(prominent: Bool = false) -> some View {
        buttonStyle(MemoryGlassButtonStyle(prominent: prominent))
    }
}
