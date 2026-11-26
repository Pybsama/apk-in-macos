import AppKit
import SwiftUI

public struct InstallingTile: Identifiable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public var appName: String
    public var iconPath: String?
    public var stageText: String

    public init(id: UUID = UUID(), sourcePath: String, appName: String, iconPath: String? = nil, stageText: String) {
        self.id = id
        self.sourcePath = sourcePath
        self.appName = appName
        self.iconPath = iconPath
        self.stageText = stageText
    }
}

public struct InlineNotice: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

public struct SquircleIconView: View {
    public let path: String?
    public let name: String
    public let size: CGFloat

    public init(path: String?, name: String, size: CGFloat) {
        self.path = path
        self.name = name
        self.size = size
    }

    public var body: some View {
        Group {
            if let path, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [IvoryTheme.warmGold, IvoryTheme.warmGold.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(IvoryTheme.paper)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(IvoryTheme.hairline, lineWidth: 0.8)
        )
        .shadow(color: Color(red: 0.30, green: 0.24, blue: 0.14).opacity(0.10), radius: 7, y: 3)
    }
}

/// Live in-place installing tile shown directly on the shelf with zero popups.
public struct InstallingTileView: View {
    public let tile: InstallingTile

    public init(tile: InstallingTile) {
        self.tile = tile
    }

    public var body: some View {
        VStack(spacing: 9) {
            ZStack {
                SquircleIconView(path: tile.iconPath, name: tile.appName, size: 64)
                    .opacity(0.45)

                ProgressView()
                    .controlSize(.small)
                    .tint(IvoryTheme.warmGold)
            }

            VStack(spacing: 2) {
                Text(tile.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IvoryTheme.inkMuted)
                    .lineLimit(1)
                Text(tile.stageText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(IvoryTheme.warmGold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(width: 112, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(IvoryTheme.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(IvoryTheme.hairline, lineWidth: 1)
        )
    }
}

public struct ShelfNoticeBanner: View {
    public let notice: InlineNotice
    public let onDismiss: () -> Void

    public init(notice: InlineNotice, onDismiss: @escaping () -> Void) {
        self.notice = notice
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                if notice.isError {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 13))
                }
                Text(notice.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
            }
            .foregroundStyle(IvoryTheme.paper)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(notice.isError ? IvoryTheme.terracotta : IvoryTheme.pillDark, in: Capsule())
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .padding(.bottom, 24)
            .onTapGesture(perform: onDismiss)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
