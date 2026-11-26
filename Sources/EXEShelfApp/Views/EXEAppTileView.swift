import AppKit
import ShelfKit
import SwiftUI
import WineRuntime

struct EXEAppTileView: View {
    let item: WindowsAppItem
    let isRunning: Bool
    let onOpen: () -> Void
    let onToggleBackend: (() -> Void)?
    let onSelectLocale: (WindowsAppLocale) -> Void
    let onRename: () -> Void
    let onViewLog: () -> Void
    let onRevealExecutable: () -> Void
    let onRevealShortcut: () -> Void
    let onCopyToDesktop: () -> Void
    let onRemove: () -> Void

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
            if let onToggleBackend {
                Button(
                    item.backend == .nativeNWJS
                        ? tr("改用 Wine 兼容层运行", "Switch to Wine Engine")
                        : tr("改用原生引擎运行 (NW.js)", "Switch to Native Engine (NW.js)"),
                    action: onToggleBackend
                )
            }
            if item.backend == .wine {
                Menu(tr("运行区域 (Locale)", "App Locale")) {
                    ForEach(WindowsAppLocale.allCases) { loc in
                        Button {
                            onSelectLocale(loc)
                        } label: {
                            if item.locale == loc {
                                Label(loc.label, systemImage: "checkmark")
                            } else {
                                Text(loc.label)
                            }
                        }
                    }
                }
            }
            Button(tr("在访达中显示程序文件", "Show Executable in Finder"), action: onRevealExecutable)
            Button(tr("重命名…", "Rename…"), action: onRename)
            Button(tr("查看运行日志", "View Run Log"), action: onViewLog)
            Divider()
            Button(tr("在访达中显示快捷方式", "Show Shortcut in Finder"), action: onRevealShortcut)
            Button(tr("复制快捷方式到桌面", "Copy Shortcut to Desktop"), action: onCopyToDesktop)
            Divider()
            Button(tr("移除", "Remove"), role: .destructive, action: onRemove)
        }
        .help(tr("\(item.appName) — 点击直接运行，右键更多操作", "\(item.appName) — Click to run, right-click for more"))
    }
}
