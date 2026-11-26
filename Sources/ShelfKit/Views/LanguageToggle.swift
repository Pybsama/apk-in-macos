import SwiftUI

/// Refined one-click language switch.
/// A parchment capsule cut by a diagonal crease. The active language sits on a wider ink
/// "page"; clicking turns that page over the crease like a leaf of a book, and a new page
/// settles down on the other side.
public struct LanguageToggle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// Current turn of the ink page around its crease, in degrees (0 = lying flat).
    @State private var pageAngle: Double = 0
    @State private var turning = false

    private let width: CGFloat = 68
    private let height: CGFloat = 24
    /// Width of the active (ink) side — deliberately larger than half.
    private let activeWidth: CGFloat = 41
    /// Horizontal run of the diagonal crease from top to bottom.
    private let slant: CGFloat = 7
    private let inset: CGFloat = 2

    public init() {}

    public var body: some View {
        let isEnglish = LanguageSettings.shared.selection.resolvedIsEnglish

        // Crease position (mid-height) and the ink page's extent.
        let crease: CGFloat = isEnglish ? width - activeWidth : activeWidth
        let inkLeft: CGFloat = isEnglish ? crease : -slant * 2
        let inkRight: CGFloat = isEnglish ? width + slant * 2 : crease
        let zhCenter: CGFloat = isEnglish ? crease / 2 : crease / 2 - 1
        let enCenter: CGFloat = isEnglish ? crease + activeWidth / 2 + 1 : crease + (width - crease) / 2
        let lift = min(abs(pageAngle) / 90, 1)

        Button {
            turn(toEnglish: !isEnglish)
        } label: {
            ZStack {
                track

                // The paper underneath: both labels in quiet ink, revealed while the page turns.
                paperLabel("中").position(x: zhCenter, y: height / 2)
                paperLabel("EN", tracking: 0.6).position(x: enCenter, y: height / 2)

                // The ink page, carrying the active label.
                ZStack {
                    SlantedBlock(left: inkLeft, right: inkRight, slant: slant, inset: inset)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.235, green: 0.212, blue: 0.188), IvoryTheme.pillDark],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    SlantedBlock(left: inkLeft, right: inkRight, slant: slant, inset: inset)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
                    // Light catches the leaf as it lifts.
                    SlantedBlock(left: inkLeft, right: inkRight, slant: slant, inset: inset)
                        .fill(Color(red: 1, green: 0.96, blue: 0.88).opacity(0.22 * lift))

                    inkLabel(isEnglish ? "EN" : "中", tracking: isEnglish ? 0.6 : 0)
                        .position(x: isEnglish ? enCenter : zhCenter, y: height / 2)
                }
                .clipShape(Capsule().inset(by: inset))
                .shadow(color: Color(red: 0.20, green: 0.15, blue: 0.10).opacity(0.18 + 0.12 * lift),
                        radius: 2 + 2 * lift, y: 1)
                .rotation3DEffect(
                    .degrees(pageAngle),
                    axis: (x: -slant, y: height - inset * 2, z: 0),
                    anchor: UnitPoint(x: crease / width, y: 0.5),
                    perspective: 0.55
                )
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(TogglePressStyle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .help(isEnglish ? "切换到中文" : "Switch to English")
        .accessibilityLabel(isEnglish ? "Language: English" : "语言：中文")
    }

    /// Turn the current page over the crease, swap language while it stands on edge,
    /// then lay the new page down on the opposite side.
    private func turn(toEnglish english: Bool) {
        let settings = LanguageSettings.shared
        let target: AppLanguage = english ? .english : .chinese
        guard !turning else { return }
        guard !reduceMotion else {
            settings.selection = target
            return
        }
        turning = true
        // Positive angles lift the left edge toward the viewer.
        let direction: Double = english ? 1 : -1

        withAnimation(.easeIn(duration: 0.14)) {
            pageAngle = 88 * direction
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                settings.selection = target
                pageAngle = -88 * direction
            }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                    pageAngle = 0
                } completion: {
                    turning = false
                }
            }
        }
    }

    private var track: some View {
        Capsule()
            .fill(IvoryTheme.paper)
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.05), lineWidth: 2)
                    .blur(radius: 1.2)
                    .offset(y: 0.8)
                    .mask(Capsule())
            )
            .overlay(
                Capsule().strokeBorder(hovering ? IvoryTheme.hairlineStrong : IvoryTheme.hairline, lineWidth: 1)
            )
    }

    private func paperLabel(_ text: String, tracking: CGFloat = 0) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .tracking(tracking)
            .foregroundStyle(hovering ? IvoryTheme.ink : IvoryTheme.inkMuted)
            .fixedSize()
    }

    private func inkLabel(_ text: String, tracking: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .tracking(tracking)
            .foregroundStyle(IvoryTheme.paper)
            .fixedSize()
    }
}

private struct SlantedBlock: Shape {
    var left: CGFloat
    var right: CGFloat
    var slant: CGFloat
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let k = slant / 2
        let top = rect.minY + inset, bottom = rect.maxY - inset
        var p = Path()
        p.move(to: CGPoint(x: left + k, y: top))
        p.addLine(to: CGPoint(x: right + k, y: top))
        p.addLine(to: CGPoint(x: right - k, y: bottom))
        p.addLine(to: CGPoint(x: left - k, y: bottom))
        p.closeSubpath()
        return p
    }
}

private struct TogglePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
