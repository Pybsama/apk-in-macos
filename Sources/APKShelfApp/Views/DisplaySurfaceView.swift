import APKRuntime
import AVFoundation
import AppKit
import Foundation

public final class DisplaySurfaceView: NSView {
    public let videoLayer = AVSampleBufferDisplayLayer()

    public var onTouch: ((UInt8, Float, Float) -> Void)?
    public var onScroll: ((Float, Float, Float, Float) -> Void)?
    public var onKey: ((UInt8, Int32, Int32) -> Void)?
    public var onText: ((String) -> Void)?
    public var onPaste: ((String) -> Void)?
    public var onDropFiles: (([URL]) -> Void)?

    private var pointerPressed = false
    private var streamSize = CGSize(width: 784, height: 1440)
    private var dragHighlight = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = IvoryTheme.nsCanvas.cgColor
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = IvoryTheme.nsCanvas.cgColor
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
        registerForDraggedTypes([.fileURL])
    }

    public func setStreamDimensions(width: Int32, height: Int32) {
        guard width > 0 && height > 0 else { return }
        streamSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func videoRect() -> CGRect {
        guard bounds.width > 0, bounds.height > 0, streamSize.width > 0, streamSize.height > 0 else {
            return bounds
        }
        let viewAR = bounds.width / bounds.height
        let vidAR = streamSize.width / streamSize.height
        if abs(viewAR - vidAR) < 0.01 { return bounds }
        if viewAR > vidAR {
            let w = bounds.height * vidAR
            return CGRect(x: (bounds.width - w) * 0.5, y: 0, width: w, height: bounds.height)
        } else {
            let h = bounds.width / vidAR
            return CGRect(x: 0, y: (bounds.height - h) * 0.5, width: bounds.width, height: h)
        }
    }

    private func normalized(_ event: NSEvent) -> (Float, Float)? {
        let pt = convert(event.locationInWindow, from: nil)
        let r = videoRect()
        guard r.width > 0, r.height > 0 else { return nil }
        let nx = Float((pt.x - r.minX) / r.width)
        let ny = Float(1.0 - (pt.y - r.minY) / r.height)
        return (max(0, min(1, nx)), max(0, min(1, ny)))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (nx, ny) = normalized(event) else { return }
        pointerPressed = true
        onTouch?(0, nx, ny)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard pointerPressed, let (nx, ny) = normalized(event) else { return }
        onTouch?(2, nx, ny)
    }

    public override func mouseUp(with event: NSEvent) {
        guard pointerPressed else { return }
        pointerPressed = false
        guard let (nx, ny) = normalized(event) else { return }
        onTouch?(1, nx, ny)
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onKey?(0, AndroidKey.back, 0)
        onKey?(1, AndroidKey.back, 0)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let (nx, ny) = normalized(event) else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.12 : 1.0
        let dx = Float(event.scrollingDeltaX * scale)
        let dy = Float(event.scrollingDeltaY * scale)
        if abs(dx) > 0.001 || abs(dy) > 0.001 {
            onScroll?(nx, ny, dx, dy)
        }
    }

    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch c {
            case "v":
                if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                    onPaste?(str)
                }
                return
            case "c":
                onKey?(0, AndroidKey.copy, 0)
                onKey?(1, AndroidKey.copy, 0)
                return
            case "x":
                onKey?(0, AndroidKey.cut, 0)
                onKey?(1, AndroidKey.cut, 0)
                return
            case "a":
                onKey?(0, AndroidKey.keyA, AndroidKey.metaCtrl)
                onKey?(1, AndroidKey.keyA, AndroidKey.metaCtrl)
                return
            case "w", "q", "m", "h", "1":
                super.keyDown(with: event)
                return
            default:
                break
            }
        }

        if let special = KeyMap.specialKey(forMacCode: event.keyCode) {
            onKey?(0, special, mods.contains(.shift) ? AndroidKey.metaShift : 0)
            return
        }

        if let chars = event.characters, !chars.isEmpty {
            let clean = chars.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
            if !clean.isEmpty {
                onText?(String(String.UnicodeScalarView(clean)))
            }
        }
    }

    public override func keyUp(with event: NSEvent) {
        if let special = KeyMap.specialKey(forMacCode: event.keyCode) {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onKey?(1, special, mods.contains(.shift) ? AndroidKey.metaShift : 0)
        }
    }

    // MARK: - Drag & Drop Files into /sdcard/Download

    private func droppedRegularFiles(from sender: NSDraggingInfo) -> [URL] {
        guard let objs = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else { return [] }
        return objs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    private func setDragBorder(_ active: Bool) {
        dragHighlight = active
        layer?.borderColor = active ? NSColor(srgbRed: 0.769, green: 0.427, blue: 0.282, alpha: 0.9).cgColor : nil
        layer?.borderWidth = active ? 2.5 : 0
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = droppedRegularFiles(from: sender)
        guard !files.isEmpty else { return [] }
        setDragBorder(true)
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragBorder(false)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragBorder(false)
        let files = droppedRegularFiles(from: sender)
        guard !files.isEmpty else { return false }
        onDropFiles?(files)
        return true
    }
}
