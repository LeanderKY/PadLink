import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures one display with ScreenCaptureKit and hands NV12 frames straight to the encoder
/// (no colour conversion, no copies). Only changed frames are delivered.
final class ScreenSource: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "padlink.capture", qos: .userInteractive)
    /// picture, encoder timestamp, capture time (host clock, ns — same clock as DispatchTime.uptimeNanoseconds)
    var onFrame: ((CVPixelBuffer, CMTime, UInt64) -> Void)?
    var onStopped: ((String) -> Void)?

    /// Last delivered frame — re-encoded as a keyframe when the screen is still but the pad needs a fresh picture.
    private(set) var lastFrame: CVPixelBuffer?
    private var lastCaptureNs: UInt64 = 0
    /// When the screen last changed (any thread may read; a stale value is harmless).
    private(set) var lastChangeNs: UInt64 = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "PadLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bildschirm nicht gefunden"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.capturesAudio = false
        cfg.scalesToFit = true
        cfg.colorSpaceName = CGColorSpace.sRGB
        if #available(macOS 14.0, *) { cfg.captureResolution = .best }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        lastFrame = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ns = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000_000) : DispatchTime.now().uptimeNanoseconds
        lastFrame = pb
        lastCaptureNs = ns
        lastChangeNs = ns
        onFrame?(pb, pts, ns)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }

    /// Re-send the current picture (runs on the capture queue so it never races new frames).
    func repeatLastFrame() {
        queue.async { [weak self] in
            guard let self, let pb = self.lastFrame else { return }
            self.onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()), self.lastCaptureNs)
        }
    }
}

/// "Zweiter Bildschirm": a virtual display shaped exactly like the pad.
final class PadVirtualDisplay {
    private var display: CGVirtualDisplay?
    var displayID: CGDirectDisplayID? { display.map { CGDirectDisplayID($0.displayID) } }

    func create(pixelWidth: Int, pixelHeight: Int) -> Bool {
        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = "Zeichen-Pad"
        desc.maxPixelsWide = UInt32(pixelWidth)
        desc.maxPixelsHigh = UInt32(pixelHeight)
        // 14" 16:10 panel
        desc.sizeInMillimeters = CGSize(width: 302, height: 189)
        desc.productID = 0x1414
        desc.vendorID = 0x5041 // "PA"
        desc.serialNum = 1
        desc.terminationHandler = { _, _ in }

        guard let d = CGVirtualDisplay(descriptor: desc) else { return false }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Points = pixels / 2 with hiDPI → sharp Retina text on the pad.
        guard let mode = CGVirtualDisplayMode(width: UInt32(pixelWidth / 2), height: UInt32(pixelHeight / 2), refreshRate: 60) else { return false }
        settings.modes = [mode]
        guard d.apply(settings) else { return false }
        display = d
        return true
    }

    func destroy() { display = nil }
}

private extension CGVirtualDisplayDescriptor {
    func setDispatchQueue(_ q: DispatchQueue) { self.queue = q }
}
