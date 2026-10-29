import AppKit
import AVFoundation
import ScreenCaptureKit
import VideoToolbox

// Capture is restricted to a separate, VM-only window. No desktop/display capture.
final class RemoteEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "org.isola.remote.video", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var busy = false, stopped = false
    private var sequence: UInt64 = 0
    private var frames = RemoteFrameWindow()
    private var latest: CVPixelBuffer?
    private var viewport: RemoteViewport?
    private var sessionEpoch: UInt64 = 0
    private var dimensions = CGSize.zero
    private var codec = "h264"
    private var supportedCodecs = ["hevc", "h264"]
    private var started = 0.0, currentEpoch: UInt64 = 0
    private var rate = 0, lastRateChange = 0.0
    var send: ((RemoteVideo, @escaping () -> Void) -> Void)?
    var onError: ((String) -> Void)?
    func configure(_ viewport: RemoteViewport, codecs: [String]) {
        queue.async { self.viewport = viewport; self.supportedCodecs = codecs; self.latest = nil }
    }
    func acknowledge(_ sequence: UInt64) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if let delay = frames.acknowledge(sequence, at: now), let session, let viewport, now - lastRateChange > 1 {
                let ceiling = viewport.bitRate
                let next = delay > 0.080 ? max(6_000_000, rate * 3 / 4) : delay < 0.035 ? min(ceiling, rate + 2_000_000) : rate
                if next != rate { rate = next; VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: rate as CFNumber) }
                lastRateChange = now
            }
            drain()
        }
    }
    func checkHealth() {
        queue.async { [self] in
            if let oldest = frames.oldest, ProcessInfo.processInfo.systemUptime - oldest > 5 {
                fail(L("Клиент не успевает декодировать поток. Переподключись и выбери «Быстрый отклик».", "The client stopped decoding frames. Reconnect and select Responsive quality."))
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let pixel = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        encode(pixel)
    }
    // One latest raw surface + at most two unacknowledged encoded frames.
    func encode(_ pixel: CVPixelBuffer) {
        guard !stopped else { return }
        if let viewport, CVPixelBufferGetWidth(pixel) != viewport.width || CVPixelBufferGetHeight(pixel) != viewport.height { return }
        latest = pixel; drain()
    }
    private func drain() {
        guard !stopped, !busy, frames.available, let pixel = latest else { return }
        latest = nil
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        let epoch = viewport?.epoch ?? 0
        if session == nil || size != dimensions || epoch != sessionEpoch {
            if let session { VTCompressionSessionInvalidate(session) }; session = nil
            guard createSession(size: size) else { return }
            dimensions = size; sessionEpoch = epoch
        }
        guard let session else { return }
        busy = true; started = ProcessInfo.processInfo.systemUptime; currentEpoch = epoch
        sequence += 1
        let result = VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: CMTime(seconds: started, preferredTimescale: 1_000_000), duration: CMTime(value: 1, timescale: 60), frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if result != noErr { busy = false; fail("Video encoding: \(result)") }
    }
    private func createSession(size: CGSize) -> Bool {
        let preferred = viewport?.quality == "responsive" ? ["h264"] : ["hevc", "h264"]
        for candidate in preferred where supportedCodecs.contains(candidate) {
            let specification: [CFString: Any] = candidate == "h264" ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true, kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] : [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            let result = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: candidate == "hevc" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in
                guard let ref else { return }
                let owner = Unmanaged<RemoteEncoder>.fromOpaque(ref).takeUnretainedValue()
                owner.queue.async { owner.encoded(sample, status: status) }
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
            guard result == noErr, let session else { continue }
            codec = candidate; rate = viewport?.bitRate ?? 12_000_000
            let required: [CFString: CFTypeRef] = [
                kVTCompressionPropertyKey_RealTime: kCFBooleanTrue!,
                kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse!,
                kVTCompressionPropertyKey_ProfileLevel: candidate == "hevc" ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
                kVTCompressionPropertyKey_AverageBitRate: rate as CFNumber,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: 120 as CFNumber,
                kVTCompressionPropertyKey_ExpectedFrameRate: 60 as CFNumber
            ]
            let valid = required.allSatisfy { VTSessionSetProperty(session, key: $0.key, value: $0.value) == noErr }
            // Not every OS/encoder implements these optional tuning keys.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
            if valid, VTCompressionSessionPrepareToEncodeFrames(session) == noErr { return true }
            VTCompressionSessionInvalidate(session); self.session = nil
        }
        fail(L("Аппаратный видеокодер недоступен.", "No compatible hardware video encoder is available.")); return false
    }
    private func encoded(_ sample: CMSampleBuffer?, status: OSStatus) {
        guard !stopped else { return }
        guard status == noErr, let sample, let format = sample.formatDescription, let block = sample.dataBuffer else { busy = false; fail("Video encoding: \(status)"); return }
        var sets: [Data] = []
        for index in 0..<(codec == "hevc" ? 3 : 2) {
            var pointer: UnsafePointer<UInt8>?, count = 0
            let result = codec == "hevc" ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard result == noErr, let pointer, (1...4096).contains(count) else { busy = false; fail("Invalid encoder configuration."); return }
            sets.append(Data(bytes: pointer, count: count))
        }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let result = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard result == noErr, data.count <= 8 * 1024 * 1024 else { busy = false; fail("Invalid encoded frame."); return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        let hevc = codec == "hevc"
        let frame = RemoteVideo(bytes: data, sps: sets[hevc ? 1 : 0], pps: sets[hevc ? 2 : 1], width: Int(dimensions.width), height: Int(dimensions.height), keyframe: keyframe, codec: codec, vps: hevc ? sets[0] : Data(), epoch: currentEpoch, sequence: sequence, encodeMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000)
        guard let send else { busy = false; return }
        frames.sent(sequence, at: started)
        send(frame) { [weak self] in self?.queue.async { [weak self] in self?.busy = false; self?.drain() } }
    }
    private func fail(_ message: String) { guard !stopped else { return }; stopped = true; latest = nil; onError?(message) }
    func stop() { queue.async { [self] in stopped = true; latest = nil; if let session { VTCompressionSessionInvalidate(session) }; session = nil; send = nil; onError = nil } }
}

@MainActor final class RemoteCapture {
    private var stream: SCStream?
    private var encoder: RemoteEncoder?
    private var cancelled = false
    private var pending: RemoteViewport?
    private var updating = false
    private var codecs: [String] = []
    private var onError: ((String) -> Void)?
    static func configuration(_ viewport: RemoteViewport) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = viewport.width; config.height = viewport.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
        config.scalesToFit = true; config.preservesAspectRatio = false
        config.ignoreShadowsSingleWindow = true; config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }
    func start(window: NSWindow, viewport: RemoteViewport, codecs: [String], send: @escaping (RemoteVideo, @escaping () -> Void) -> Void, onError: @escaping (String) -> Void) async throws {
        self.codecs = codecs; self.onError = onError
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard !cancelled else { return }
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw RemoteSecurity.failure(L("Окно VM недоступно для трансляции.", "The VM window is unavailable for capture.")) }
        let initial = pending ?? viewport; pending = nil
        let encoder = RemoteEncoder(); encoder.send = send; encoder.onError = onError; encoder.configure(initial, codecs: codecs); self.encoder = encoder
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: Self.configuration(initial), delegate: encoder)
        self.stream = stream; updating = true
        try stream.addStreamOutput(encoder, type: .screen, sampleHandlerQueue: encoder.queue)
        try await stream.startCapture()
        updating = false
        if cancelled { try? await stream.stopCapture() } else { updatePending() }
    }
    func resize(_ viewport: RemoteViewport) { pending = viewport; updatePending() }
    private func updatePending() {
        guard !cancelled, !updating, let stream, let next = pending else { return }
        pending = nil; updating = true
        encoder?.configure(next, codecs: codecs)
        Task { [weak self] in
            do { try await stream.updateConfiguration(Self.configuration(next)) }
            catch { if self?.cancelled == false { self?.onError?(error.localizedDescription) } }
            self?.updating = false; self?.updatePending()
        }
    }
    func acknowledge(_ sequence: UInt64) { encoder?.acknowledge(sequence) }
    func checkHealth() { encoder?.checkHealth() }
    func stop() {
        cancelled = true; pending = nil; onError = nil
        let old = stream; stream = nil; encoder?.stop(); encoder = nil
        if let old { Task { try? await old.stopCapture() } }
    }
}

enum RemoteVideoSample {
    static func format(_ frame: RemoteVideo) -> CMVideoFormatDescription? {
        guard ["h264", "hevc"].contains(frame.codec), (1...4096).contains(frame.width), (1...4096).contains(frame.height),
              frame.width * frame.height <= 8_847_360, (1...4096).contains(frame.sps.count), (1...4096).contains(frame.pps.count),
              frame.codec != "hevc" || (1...4096).contains(frame.vps.count) else { return nil }
        var format: CMFormatDescription?
        let result = frame.vps.withUnsafeBytes { vps in frame.sps.withUnsafeBytes { sps in frame.pps.withUnsafeBytes { pps in
            let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
            if frame.codec == "hevc" {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3, parameterSetPointers: [vps.bindMemory(to: UInt8.self).baseAddress!] + pointers, parameterSetSizes: [vps.count, sps.count, pps.count], nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        } } }
        guard result == noErr, let format else { return nil }
        let actual = CMVideoFormatDescriptionGetDimensions(format)
        guard actual.width == frame.width, actual.height == frame.height else { return nil }
        return format
    }
    static func make(_ frame: RemoteVideo, format cached: CMVideoFormatDescription? = nil) -> CMSampleBuffer? {
        guard !frame.bytes.isEmpty, frame.bytes.count <= 8 * 1024 * 1024, let format = cached ?? format(frame) else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frame.bytes.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        guard frame.bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }) == noErr else { return nil }
        var sample: CMSampleBuffer?, size = frame.bytes.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
    static func immediate(_ sample: CMSampleBuffer) {
        if let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }
}

// Decode off the main thread, acknowledge after decoding, then display an
// uncompressed surface. The display layer cannot build up a compressed GOP queue.
final class RemoteDecoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.isola.remote.decode", qos: .userInteractive)
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var configuration = Data()
    private var stopped = false
    static var codecs: [String] { ["hevc", "h264"].filter { VTIsHardwareDecodeSupported($0 == "hevc" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264) } }
    func decode(_ frame: RemoteVideo, completion: @escaping (CMSampleBuffer?) -> Void) {
        queue.async { [self] in
            guard !stopped else { completion(nil); return }
            let key = Data(frame.codec.utf8) + frame.vps + frame.sps + frame.pps
            if configuration != key {
                if let session { VTDecompressionSessionInvalidate(session) }; session = nil; format = nil
                guard frame.keyframe, let description = RemoteVideoSample.format(frame) else { completion(nil); return }
                let result = VTDecompressionSessionCreate(allocator: nil, formatDescription: description, decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary, imageBufferAttributes: [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
                guard result == noErr else { completion(nil); return }
                format = description; configuration = key
                if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
            }
            guard let session, let format, CMVideoFormatDescriptionGetDimensions(format).width == frame.width,
                  CMVideoFormatDescriptionGetDimensions(format).height == frame.height,
                  let sample = RemoteVideoSample.make(frame, format: format) else { completion(nil); return }
            let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, pixel, _, _ in
                guard status == noErr, let pixel else { completion(nil); return }
                var description: CMVideoFormatDescription?, output: CMSampleBuffer?
                guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &description) == noErr, let description else { completion(nil); return }
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &output) == noErr, let output else { completion(nil); return }
                RemoteVideoSample.immediate(output); completion(output)
            }
            if result != noErr { completion(nil) }
        }
    }
    func stop() { queue.async { [self] in stopped = true; if let session { VTDecompressionSessionInvalidate(session) }; session = nil } }
}
