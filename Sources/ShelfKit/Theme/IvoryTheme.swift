import AppKit
import SwiftUI

/// Restrained European parchment off-white palette ("白色带一点点黄色，些许 Claude 欧洲古卷感")
public enum IvoryTheme {
    // Primary parchment canvas: luminous off-white with a delicate antique-yellow undertone (#F6F3EB)
    public static let canvas = Color(red: 0.965, green: 0.953, blue: 0.922)           // #F6F3EB
    public static let canvasHighlight = Color(red: 0.984, green: 0.976, blue: 0.953)  // #FBF9F3
    public static let canvasEdge = Color(red: 0.945, green: 0.929, blue: 0.890)       // #F1EDE3
    public static let nsCanvas = NSColor(srgbRed: 0.965, green: 0.953, blue: 0.922, alpha: 1.0)

    // Crisp warm cotton-paper surface (#FCFBF7)
    public static let paper = Color(red: 0.988, green: 0.984, blue: 0.969)            // #FCFBF7
    public static let hoverWash = Color(red: 0.929, green: 0.910, blue: 0.863)        // #EDE8DC
    public static let hairline = Color(red: 0.894, green: 0.867, blue: 0.816)         // #E4DDD0
    public static let hairlineStrong = Color(red: 0.835, green: 0.804, blue: 0.745)   // #D5CDBE

    // Warm archival ink typography
    public static let ink = Color(red: 0.149, green: 0.137, blue: 0.122)              // #26231F
    public static let inkMuted = Color(red: 0.431, green: 0.408, blue: 0.369)         // #6E685E
    public static let inkFaint = Color(red: 0.620, green: 0.588, blue: 0.537)         // #9E9689

    // Minimalist ink pill & understated Claude-style warm sienna accent
    public static let pillDark = Color(red: 0.165, green: 0.149, blue: 0.133)         // #2A2622
    public static let pillDarkPressed = Color(red: 0.243, green: 0.220, blue: 0.196)

    public static let warmGold = Color(red: 0.769, green: 0.427, blue: 0.282)         // #C46D48 subtle terracotta-ochre
    public static let warmGoldSoft = Color(red: 0.769, green: 0.427, blue: 0.282).opacity(0.11)

    public static let sage = Color(red: 0.306, green: 0.510, blue: 0.369)             // #4E825E
    public static let terracotta = Color(red: 0.722, green: 0.298, blue: 0.231)       // #B84C3B
}

/// Ultra-subtle European vellum/parchment backdrop: luminous near-white center softly warming at the edges,
/// plus an almost imperceptible fine paper grain so it feels tactile without ever looking heavy.
public struct ParchmentBackdrop: View {
    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [IvoryTheme.canvasHighlight, IvoryTheme.canvas, IvoryTheme.canvasEdge],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.994, blue: 0.976).opacity(0.55),
                    Color.clear,
                    Color(red: 0.875, green: 0.835, blue: 0.755).opacity(0.18)
                ],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 40,
                endRadius: 560
            )

            // Whisper-fine paper fiber texture (barely perceptible)
            Canvas { ctx, size in
                let step: CGFloat = 6
                var seed: UInt64 = 0x5EED_CAFE
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        let v = Double((seed >> 33) & 0xFF) / 255.0
                        if v > 0.82 {
                            let rect = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                            ctx.fill(
                                Path(rect),
                                with: .color(Color(red: 0.62, green: 0.56, blue: 0.45).opacity(0.028))
                            )
                        }
                        x += step
                    }
                    y += step
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

public struct IvoryPillButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(IvoryTheme.paper)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? IvoryTheme.pillDarkPressed : IvoryTheme.pillDark)
            )
    }
}

/// Hosting view that lets the very first click on an inactive window reach controls
/// (e.g. the language toggle), instead of only activating the window.
public final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shared factory for the signature 820×540 warm parchment shelf window.
public enum ShelfWindowBuilder {
    @MainActor
    public static func makeShelfWindow<Content: View>(title: String, rootView: Content) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.appearance = NSAppearance(named: .aqua)
        win.title = title
        win.minSize = NSSize(width: 480, height: 340)
        win.backgroundColor = IvoryTheme.nsCanvas
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()

        let hosting = FirstClickHostingView(rootView: rootView)
        // Keep the window at its designed size; content must not resize the window.
        hosting.sizingOptions = []
        win.contentView = hosting
        win.setContentSize(NSSize(width: 820, height: 540))
        win.center()
        return win
    }
}
