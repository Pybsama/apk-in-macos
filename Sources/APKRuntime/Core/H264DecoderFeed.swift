import AVFoundation
import CoreMedia
import Foundation

public enum AnnexBScanner {
    public static func splitNALUs(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 4 else { return [] }

        var starts: [(prefix: Int, body: Int)] = []
        var i = 0
        while i + 2 < n {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((3, i + 3))
                    i += 3
                    continue
                } else if i + 3 < n && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((4, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        guard !starts.isEmpty else { return [] }

        var result: [Data] = []
        result.reserveCapacity(starts.count)
        for idx in 0..<starts.count {
            let s = starts[idx].body
            let e = (idx + 1 < starts.count) ? (starts[idx + 1].body - starts[idx + 1].prefix) : n
            if e > s { result.append(Data(bytes[s..<e])) }
        }
        return result
    }

    public static func unitType(_ nalu: Data) -> UInt8 {
        (nalu.first ?? 0) & 0x1F
    }
}

public final class H264DecoderFeed: @unchecked Sendable {
    private let lock = NSLock()
    private weak var layer: AVSampleBufferDisplayLayer?
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMVideoFormatDescription?
    private var awaitingIDR = true

    public var onNeedSyncFrame: (() -> Void)?

    public init(displayLayer: AVSampleBufferDisplayLayer) {
        self.layer = displayLayer
    }

    public func prepareForResize() {
        lock.lock()
        sps = nil
        pps = nil
        formatDesc = nil
        awaitingIDR = true
        let target = layer
        lock.unlock()

        DispatchQueue.main.async {
            target?.sampleBufferRenderer.flush()
        }
    }

    public func pushConfig(_ annexB: Data) {
        let units = AnnexBScanner.splitNALUs(annexB)
        lock.lock()
        var changed = false
        for u in units {
            let t = AnnexBScanner.unitType(u)
            if t == 7 && u != sps { sps = u; changed = true }
            else if t == 8 && u != pps { pps = u; changed = true }
        }
        if changed {
            rebuildFormatLocked()
            awaitingIDR = true
        }
        lock.unlock()
    }

    public func pushFrame(_ annexB: Data, ptsUs: Int64, isKeyframe: Bool) {
        let units = AnnexBScanner.splitNALUs(annexB)
        guard !units.isEmpty else { return }

        lock.lock()
        var slices: [Data] = []
        var configChanged = false
        var hasIDR = isKeyframe

        for u in units {
            switch AnnexBScanner.unitType(u) {
            case 7:
                if u != sps { sps = u; configChanged = true }
            case 8:
                if u != pps { pps = u; configChanged = true }
            case 5:
                hasIDR = true
                slices.append(u)
            case 1, 6:
                slices.append(u)
            default:
                break
            }
        }
        if configChanged { rebuildFormatLocked() }

        guard let fmt = formatDesc, !slices.isEmpty else {
            lock.unlock()
            return
        }
        if awaitingIDR {
            if hasIDR { awaitingIDR = false }
            else { lock.unlock(); return }
        }
        let target = layer
        lock.unlock()

        guard let sb = makeSampleBuffer(slices: slices, format: fmt, ptsUs: ptsUs, keyframe: hasIDR) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let target else { return }
            let renderer = target.sampleBufferRenderer
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
                self?.flagNeedsIDR()
                self?.onNeedSyncFrame?()
                return
            }
            if renderer.isReadyForMoreMediaData {
                renderer.enqueue(sb)
            }
        }
    }

    private func flagNeedsIDR() {
        lock.lock()
        awaitingIDR = true
        lock.unlock()
    }

    private func rebuildFormatLocked() {
        guard let sps, let pps else { return }
        var created: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { sBuf in
            pps.withUnsafeBytes { pBuf in
                guard let sPtr = sBuf.bindMemory(to: UInt8.self).baseAddress,
                      let pPtr = pBuf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: [sPtr, pPtr],
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &created
                )
            }
        }
        if status == noErr, let created {
            self.formatDesc = created
        }
    }

    private func makeSampleBuffer(slices: [Data], format: CMVideoFormatDescription, ptsUs: Int64, keyframe: Bool) -> CMSampleBuffer? {
        var total = 0
        for s in slices { total += 4 + s.count }
        var avcc = Data(capacity: total)
        for s in slices {
            var lenBE = UInt32(s.count).bigEndian
            withUnsafeBytes(of: &lenBE) { avcc.append(contentsOf: $0) }
            avcc.append(s)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb
        ) == noErr, let sb else { return nil }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary],
           let dict = arr.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately as String] = true
            dict[kCMSampleAttachmentKey_NotSync as String] = !keyframe
        }
        return sb
    }
}
