import AppKit
import CoreGraphics
import Foundation

public enum SquircleIconMaker {
    public static func buildICNS(from imagePath: String?, fallbackName: String, to icnsURL: URL) async throws {
        let master: NSImage
        if let path = imagePath, let img = NSImage(contentsOfFile: path) {
            master = drawSquircle(source: img, size: 1024)
        } else {
            master = drawWarmMonogram(name: fallbackName, size: 1024)
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("shelf-icon-\(UUID().uuidString)")
        let iconset = tmp.appendingPathComponent("AppIcon.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let sizes: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]

        for (file, px) in sizes {
            let png = try encodePNG(image: master, size: px)
            try png.write(to: iconset.appendingPathComponent(file))
        }

        try fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let res = try await ShellCommand.run("/usr/bin/iconutil", args: ["-c", "icns", iconset.path, "-o", icnsURL.path], timeout: 20)
        guard res.ok else {
            throw NSError(domain: "SquircleIconMaker", code: Int(res.exitCode), userInfo: [NSLocalizedDescriptionKey: res.stderr])
        }
    }

    private static func drawSquircle(source: NSImage, size: CGFloat) -> NSImage {
        let canvas = NSImage(size: NSSize(width: size, height: size))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return source }
        ctx.interpolationQuality = .high

        let inset = size * 0.09
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = rect.width * 0.23
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.032, color: NSColor.black.withAlphaComponent(0.24).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(srgbRed: 0.996, green: 0.990, blue: 0.974, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(NSColor(srgbRed: 0.996, green: 0.990, blue: 0.974, alpha: 1).cgColor)
        ctx.fill(rect)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        ctx.restoreGState()

        return canvas
    }

    private static func drawWarmMonogram(name: String, size: CGFloat) -> NSImage {
        let canvas = NSImage(size: NSSize(width: size, height: size))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return canvas }

        let inset = size * 0.09
        let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = rect.width * 0.23
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        let tones: [(NSColor, NSColor)] = [
            (NSColor(srgbRed: 0.78, green: 0.58, blue: 0.28, alpha: 1), NSColor(srgbRed: 0.88, green: 0.72, blue: 0.44, alpha: 1)),
            (NSColor(srgbRed: 0.34, green: 0.56, blue: 0.44, alpha: 1), NSColor(srgbRed: 0.50, green: 0.72, blue: 0.58, alpha: 1)),
            (NSColor(srgbRed: 0.32, green: 0.46, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.48, green: 0.63, blue: 0.80, alpha: 1)),
            (NSColor(srgbRed: 0.68, green: 0.42, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.82, green: 0.58, blue: 0.52, alpha: 1))
        ]
        let pair = tones[abs(name.hashValue) % tones.count]
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [pair.0.cgColor, pair.1.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        ctx.restoreGState()

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ch = trimmed.isEmpty ? "A" : String(trimmed.prefix(1)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.width * 0.46, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.992, blue: 0.976, alpha: 1)
        ]
        let s = NSAttributedString(string: ch, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        return canvas
    }

    private static func encodePNG(image: NSImage, size: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw NSError(domain: "SquircleIconMaker", code: 1)
        }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SquircleIconMaker", code: 2)
        }
        return data
    }
}
