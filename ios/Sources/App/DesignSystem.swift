import SwiftUI

// MARK: - Color Palette
// Derived from OKLCH tokens in DESIGN.md. Warm undertone throughout; no pure white or black.

extension Color {
    static let filmWhite     = Color(red: 0.976, green: 0.961, blue: 0.945)
    static let grainPaper    = Color(red: 0.929, green: 0.910, blue: 0.878)
    static let ink           = Color(red: 0.157, green: 0.141, blue: 0.098)
    static let secondaryText = Color(red: 0.514, green: 0.494, blue: 0.467)
    static let divider       = Color(red: 0.855, green: 0.835, blue: 0.804)
    static let terracotta    = Color(red: 0.647, green: 0.325, blue: 0.212)
    static let photoOverlay  = Color(red: 0.098, green: 0.094, blue: 0.071).opacity(0.55)

    // Status badges
    static let badgeCompleteFill = Color(red: 0.200, green: 0.588, blue: 0.294).opacity(0.15)
    static let badgeCompleteText = Color(red: 0.100, green: 0.310, blue: 0.149)
    static let badgeActiveFill   = Color(red: 0.627, green: 0.490, blue: 0.118).opacity(0.15)
    static let badgeActiveText   = Color(red: 0.380, green: 0.302, blue: 0.067)
}

// MARK: - Typography
// Fraunces at every level. Weight contrast carries hierarchy — size is secondary.

extension Font {
    static let displaySerif  = Font.custom("Fraunces-SemiBold", size: 36)
    static let headlineSerif = Font.custom("Fraunces-SemiBold", size: 22)
    static let titleSerif    = Font.custom("Fraunces-Medium",   size: 17)
    static let bodySerif     = Font.custom("Fraunces-Regular",  size: 16)
    static let labelSerif    = Font.custom("Fraunces-Medium",   size: 14)
    static let captionSerif  = Font.custom("Fraunces-Regular",  size: 11)
}

// MARK: - Corner Radii

extension CGFloat {
    static let photoRadius: CGFloat = 4
    static let interactiveRadius: CGFloat = 8
}

// MARK: - Animation

extension Animation {
    // 60ms: tap feedback on photo cell (scale pulse)
    static let tapFeedback = Animation.easeOut(duration: 0.06)
    // 120ms: new pair arrives
    static let pairTransition = Animation.easeOut(duration: 0.12)
    // 220ms: full-screen state changes
    static let screenTransition = Animation.easeInOut(duration: 0.22)
    // 80ms: button press
    static let buttonPress = Animation.easeOut(duration: 0.08)
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelSerif)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: .interactiveRadius)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .foregroundStyle(isEnabled ? Color.filmWhite : Color.secondaryText)
            .animation(.buttonPress, value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return .divider }
        return isPressed ? Color(red: 0.549, green: 0.251, blue: 0.157) : .terracotta
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.labelSerif)
            .foregroundStyle(Color.secondaryText)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .animation(.buttonPress, value: configuration.isPressed)
    }
}

// 96% scale-down on press — tactile confirmation that a choice landed
struct PhotoTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.tapFeedback, value: configuration.isPressed)
    }
}

// MARK: - Stage Badge

struct StageBadge: View {
    let stage: String
    var isComplete: Bool = false

    var body: some View {
        Text(label)
            .font(.captionSerif)
            .foregroundStyle(isComplete ? Color.badgeCompleteText : Color.badgeActiveText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isComplete ? Color.badgeCompleteFill : Color.badgeActiveFill)
            )
    }

    private var label: String {
        if isComplete { return "Complete" }
        switch stage {
        case "stage1": return "Broad discovery"
        case "stage2": return "Refining top photos"
        case "stage3": return "Final choices"
        default:       return stage
        }
    }
}
