import APKRuntime
import AppKit
import SwiftUI

/// Pure, tactile warm-ivory app icon tile: single click opens, right-click manages.
struct AppTileView: View {
    let item: AndroidAppItem
    let isRunning: Bool
    let onOpen: () -> Void
    let onOpenMainScreen: () -> Void
    let onRevealShortcut: () -> Void
    let onCopyToDesktop: () -> Void
    let onUninstall: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 9) {
            SquircleIconView(path: item.iconPath, name: item.appName, size: 64)
                .scaleEffect(hovering ? 1.04 : 1.0)

            VStack(spacing: 4) {
                Text(item.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IvoryTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Circle()
                    .fill(isRunning ? IvoryTheme.sage : Color.clear)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 112, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(hovering ? IvoryTheme.hoverWash : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) {
                hovering = inside
            }
        }
        .onTapGesture {
            onOpen()
        }
        .contextMenu {
            Button(tr("打开", "Open"), action: onOpen)
            Button(tr("在主屏幕打开", "Open on Home Screen"), action: onOpenMainScreen)
            Divider()
            Button(tr("在访达中显示快捷方式", "Show Shortcut in Finder"), action: onRevealShortcut)
            Button(tr("复制快捷方式到桌面", "Copy Shortcut to Desktop"), action: onCopyToDesktop)
            Divider()
            Button(tr("卸载", "Uninstall"), role: .destructive, action: onUninstall)
        }
        .help(tr("\(item.appName) — 点击直接打开，右键更多操作", "\(item.appName) — Click to open, right-click for more"))
    }
}
