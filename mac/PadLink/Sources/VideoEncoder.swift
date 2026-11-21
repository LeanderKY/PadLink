import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264 encoder tuned for latency: real-time, no B-frames, low-latency rate control,
/// one frame in → one frame out. Emits Annex-B with SPS/PPS on every keyframe.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let width: Int32, height: Int32
    private var forceKey = true
    var onFrame: ((Data, Bool) -> Void)?
    /// Called once per submitted frame, whether it produced output or was dropped by the encoder.
    var onDone: (() -> Void)?

    init?(width: Int, height: Int, bitrate: Int, fps: Int) {
        self.width = Int32(width); self.height = Int32(height)
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: self.width, height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { return nil }
        session = s

        func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 10)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        // Allow short bursts (e.g. a whole canvas changing) without long stalls.
        let bytesPerSec = bitrate / 8
        set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerSec * 2, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            session = nil
        }
    }

    func requestKeyframe() { forceKey = true }

    /// Change the target bitrate on the fly (e.g. lower while the pen draws over Wi‑Fi).
    func setBitrate(_ bitrate: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 * 2, 1] as CFArray)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKey {
            forceKey = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self else { return }
            if status == noErr, let sample { self.emit(sample) }
            self.onDone?()
        }
    }

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private func emit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: Self.startCode)
                    out.append(ptr, count: size)
                }
            }
        }

        // AVCC (4-byte length prefixes) → Annex-B (start codes)
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLen, dataPointerOut: &dataPtr) == noErr,
              let dataPtr else { return }
        dataPtr.withMemoryRebound(to: UInt8.self, capacity: totalLen) { p in
            var offset = 0
            while offset + 4 <= totalLen {
                let nalLen = Int(p[offset]) << 24 | Int(p[offset+1]) << 16 | Int(p[offset+2]) << 8 | Int(p[offset+3])
                offset += 4
                guard nalLen > 0, offset + nalLen <= totalLen else { break }
                out.append(contentsOf: Self.startCode)
                out.append(p + offset, count: nalLen)
                offset += nalLen
            }
        }
        onFrame?(out, isKey)
    }
}
