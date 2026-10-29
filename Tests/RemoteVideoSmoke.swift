import AppKit
import VideoToolbox
import Virtualization

@MainActor final class InputProbe: VZVirtualMachineView {
    var events: [String] = []
    var lastPoint = NSPoint.zero
    var scrollPhase: NSEvent.Phase = [], momentum: NSEvent.Phase = []
    override func keyDown(with event: NSEvent) { events.append("keyDown") }
    override func keyUp(with event: NSEvent) { events.append("keyUp") }
    override func flagsChanged(with event: NSEvent) { events.append("flags") }
    override func mouseDown(with event: NSEvent) { events.append("down"); lastPoint = event.locationInWindow }
    override func mouseMoved(with event: NSEvent) { lastPoint = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { events.append("up") }
    override func scrollWheel(with event: NSEvent) { events.append("scroll"); scrollPhase = event.phase; momentum = event.momentumPhase }
}

@main struct RemoteVideoSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        func until(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(8)
            while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "video test timed out")
        }
        func pixel(_ w: Int, _ h: Int) -> CVPixelBuffer {
            var pixel: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(pixel!, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel!)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixel!)
            for y in 0..<h { for x in 0..<w {
                let value: UInt8 = x % 20 == 0 || y % 20 == 0 ? 32 : 224
                let i = y * stride + x * 4; bytes[i] = value; bytes[i+1] = value; bytes[i+2] = value; bytes[i+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel!, [])
            return pixel!
        }
        for codec in ["hevc", "h264"] {
            let encoder = RemoteEncoder(), decoder = RemoteDecoder()
            var frames: [RemoteVideo] = [], failure: String?
            encoder.configure(RemoteViewport(width: 1920, height: 1200, scale: 2, quality: codec == "h264" ? "responsive" : "retina"), codecs: [codec])
            encoder.send = { value, sent in DispatchQueue.main.async { frames.append(value); sent() } }
            encoder.onError = { error in DispatchQueue.main.async { failure = error } }
            let image = pixel(1920, 1200)
            encoder.queue.sync { encoder.encode(image) }
            until { !frames.isEmpty || failure != nil }
            precondition(failure == nil, failure ?? "")
            let first = frames[0]
            precondition(first.keyframe && first.width == 1920 && first.height == 1200 && first.codec == codec)
            var decoded: CMSampleBuffer?
            decoder.decode(first) { output in DispatchQueue.main.async { decoded = output } }
            until { decoded != nil }
            precondition(CVPixelBufferGetWidth(decoded!.imageBuffer!) == 1920)
            // No ACK: subsequent captures must stop at two frames, never enqueue
            // hundreds of P frames. Resume must keep a decodable reference chain.
            encoder.queue.sync { for _ in 0..<200 { encoder.encode(image) } }
            until { frames.count == 2 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15)); precondition(frames.count == 2)
            encoder.acknowledge(first.sequence)
            until { frames.count == 3 }
            for frame in frames.dropFirst() {
                decoded = nil
                decoder.decode(frame) { output in DispatchQueue.main.async { decoded = output } }
                until { decoded != nil }
                encoder.acknowledge(frame.sequence)
            }
            // Live size change creates a new IDR + format, never stretches an old
            // compression session or loses the frame revision used for input.
            encoder.configure(RemoteViewport(width: 960, height: 540, scale: 1, quality: codec == "h264" ? "responsive" : "retina", epoch: 2), codecs: [codec])
            let resized = pixel(960, 540)
            encoder.queue.sync { encoder.encode(resized) }
            until { frames.count == 4 }
            precondition(frames[3].keyframe && frames[3].epoch == 2 && frames[3].width == 960)
            decoded = nil; decoder.decode(frames[3]) { output in DispatchQueue.main.async { decoded = output } }; until { decoded != nil }
            var malformed = first; malformed.width = 5000; precondition(RemoteVideoSample.make(malformed) == nil)
            malformed = first; malformed.sps = Data(); precondition(RemoteVideoSample.make(malformed) == nil)
            malformed = first; malformed.codec = "av1"; precondition(RemoteVideoSample.make(malformed) == nil)
            print(String(format: "PASS: %@ hardware 1920×1200 encode/decode, first encode %.1f ms, bounded frames and live resize", codec, first.encodeMilliseconds))
            encoder.stop(); decoder.stop()
        }
        let view = InputProbe(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        let input = RemoteInputTarget(view: view)
        input.receive(RemoteInput(kind: "keyDown", code: 0, text: "a"))
        input.receive(RemoteInput(kind: "down", x: 0.25, y: 0.8))
        precondition(view.lastPoint == NSPoint(x: 200, y: 400))
        input.receive(RemoteInput(kind: "scroll", deltaY: 40.25, phase: UInt64(NSEvent.Phase.changed.rawValue)))
        precondition(view.scrollPhase == .changed)
        input.releaseAll()
        precondition(view.events == ["keyDown", "down", "scroll", "keyUp", "up"])
        let count = view.events.count
        input.epoch = 4
        input.receive(RemoteInput(kind: "down", x: .nan)); input.receive(RemoteInput(kind: "keyDown", code: 256))
        input.receive(RemoteInput(kind: "down", x: 0.1, y: 0.1, epoch: 3))
        precondition(view.events.count == count, "old frame clicked new display")
        let screen = RemoteScreenView(frame: view.frame)
        var outgoing: [RemoteInput] = []
        screen.send = { outgoing.append($0) }; window.contentView = screen
        func click(_ point: CGPoint, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        }
        screen.mouseDown(with: click(NSPoint(x: 400, y: 250)))
        precondition(outgoing.count == 1 && outgoing[0].clicks == 2)
        screen.mouseUp(with: click(NSPoint(x: -100, y: 250), type: .leftMouseUp))
        precondition(outgoing.last?.kind == "up" && outgoing.last?.x == 0)
        let wide = CGRect(x: 0, y: 0, width: 1200, height: 500), frame = CGSize(width: 1920, height: 1200)
        precondition(RemoteGeometry.normalized(CGPoint(x: 10, y: 250), frame: frame, bounds: wide, clamp: false) == nil)
        let normalized = RemoteGeometry.normalized(CGPoint(x: 400, y: 400), frame: frame, bounds: wide, clamp: false)!
        precondition(normalized == CGPoint(x: 0.25, y: 0.8))
        precondition(RemoteGeometry.point(x: 0.25, y: 0.8, in: view.bounds, flipped: true).y.rounded() == 100)
        let retina = RemoteViewport.fitting(width: 1440, height: 900, backingScale: 2, quality: "retina", epoch: 1)
        precondition(retina.valid && retina.width == 2880 && retina.height == 1800)
        let huge = RemoteViewport.fitting(width: 6000, height: 4000, backingScale: 2, quality: "retina", epoch: 1)
        precondition(huge.valid && huge.width <= 4096)
        precondition(RemoteCapture.configuration(retina).showsCursor == false)
        precondition(RemoteCapture.configuration(retina).minimumFrameInterval == CMTime(value: 1, timescale: 60))
        window.close()
        print("PASS: Retina limits, letterbox corners, drag release, scroll phases, stale resize input and malformed input rejected")
    }
}
