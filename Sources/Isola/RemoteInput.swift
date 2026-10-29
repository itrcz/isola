import AppKit
import AVFoundation
import Virtualization
import SwiftUI

@MainActor final class RemoteInputTarget {
    weak var view: VZVirtualMachineView?
    var epoch: UInt64 = 0
    private var keys: [UInt16: RemoteInput] = [:]
    private var buttons: [UInt16: RemoteInput] = [:]
    init(view: VZVirtualMachineView) { self.view = view }
    func receive(_ input: RemoteInput) {
        guard input.x.isFinite, input.y.isFinite, input.deltaX.isFinite, input.deltaY.isFinite,
              (0...1).contains(input.x), (0...1).contains(input.y), input.text.utf8.count < 512,
              input.code < 256, abs(input.deltaX) <= 10_000, abs(input.deltaY) <= 10_000,
              let view, let window = view.window else { return }
        if !["keyDown", "keyUp", "flags", "up"].contains(input.kind), input.epoch != epoch { return }
        let local = RemoteGeometry.point(x: input.x, y: input.y, in: view.bounds, flipped: view.isFlipped)
        let point = view.convert(local, to: nil)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(input.flags)).intersection(.deviceIndependentFlagsMask)
        let time = ProcessInfo.processInfo.systemUptime
        if ["keyDown", "keyUp", "flags"].contains(input.kind) {
            let type: NSEvent.EventType = input.kind == "keyDown" ? .keyDown : input.kind == "keyUp" ? .keyUp : .flagsChanged
            guard let event = NSEvent.keyEvent(with: type, location: point, modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber, context: nil, characters: input.text, charactersIgnoringModifiers: input.text, isARepeat: keys[input.code] != nil, keyCode: input.code) else { return }
            if type == .keyDown { keys[input.code] = input; view.keyDown(with: event) }
            else if type == .keyUp { keys.removeValue(forKey: input.code); view.keyUp(with: event) }
            else { if flags.isEmpty { keys.removeValue(forKey: input.code) } else { keys[input.code] = input }; view.flagsChanged(with: event) }
            return
        }
        if input.kind == "scroll" {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(input.deltaY), wheel2: Int32(input.deltaX), wheel3: 0) else { return }
            cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            let screenPoint = window.convertPoint(toScreen: point)
            cg.location = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: input.deltaY)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: input.deltaX)
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: input.precise ? 1 : 0)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: RemoteGeometry.scrollPhase(input.phase))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: RemoteGeometry.momentumPhase(input.momentum))
            // VZ routes scroll to its current pointer, even for synthetic events.
            var move = input; move.kind = "move"; receive(move)
            guard let event = NSEvent(cgEvent: cg) else { return }
            view.scrollWheel(with: event); return
        }
        guard input.code <= 2 else { return }
        let type: NSEvent.EventType
        switch input.kind {
        case "down": type = input.code == 0 ? .leftMouseDown : input.code == 1 ? .rightMouseDown : .otherMouseDown; buttons[input.code] = input
        case "up":
            guard buttons[input.code] != nil else { return }
            type = input.code == 0 ? .leftMouseUp : input.code == 1 ? .rightMouseUp : .otherMouseUp; buttons.removeValue(forKey: input.code)
        case "move": type = .mouseMoved
        case "drag": type = input.code == 0 ? .leftMouseDragged : input.code == 1 ? .rightMouseDragged : .otherMouseDragged
        default: return
        }
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: min(3, max(1, input.clicks)), pressure: input.kind == "up" ? 0 : 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        case .otherMouseUp: view.otherMouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDragged: view.rightMouseDragged(with: event)
        case .otherMouseDragged: view.otherMouseDragged(with: event)
        default: view.mouseMoved(with: event)
        }
    }
    func releaseAll() {
        let oldKeys = keys, oldButtons = buttons
        for (_, var input) in oldKeys { input.kind = input.kind == "flags" ? "flags" : "keyUp"; input.flags = 0; receive(input) }
        for (_, var input) in oldButtons { input.kind = "up"; input.flags = 0; receive(input) }
        keys.removeAll(); buttons.removeAll()
    }
}

enum RemoteGeometry {
    static func scrollPhase(_ value: UInt64) -> Int64 {
        let phase = NSEvent.Phase(rawValue: UInt(value))
        var result: Int64 = 0
        for (source, target) in [(NSEvent.Phase.began, 1), (.changed, 2), (.ended, 4), (.cancelled, 8), (.mayBegin, 128)] where phase.contains(source) { result |= Int64(target) }
        return result
    }
    static func momentumPhase(_ value: UInt64) -> Int64 {
        let phase = NSEvent.Phase(rawValue: UInt(value))
        if phase.contains(.began) { return 1 }; if phase.contains(.changed) { return 2 }; if phase.contains(.ended) { return 3 }; return 0
    }
    static func point(x: Double, y: Double, in bounds: CGRect, flipped: Bool) -> CGPoint {
        CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + (flipped ? 1 - y : y) * bounds.height)
    }
    static func normalized(_ point: CGPoint, frame: CGSize, bounds: CGRect, clamp: Bool) -> CGPoint? {
        let rect = AVMakeRect(aspectRatio: frame, insideRect: bounds)
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
}

@MainActor final class RemoteScreenView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    var send: ((RemoteInput) -> Void)?
    var release: (() -> Void)?
    var switchKeyboard: (() -> Bool)?
    var viewportChanged: ((CGSize, CGFloat) -> Void)?
    private var tracking: NSTrackingArea?
    private var consumedSpace = false
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var resizeWork: DispatchWorkItem?
    private var size = CGSize(width: 1920, height: 1200)
    private var epoch: UInt64 = 0
    private var cursor = NSCursor.arrow
    private var dragging = Set<Int>()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect; layer?.addSublayer(videoLayer)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window?.firstResponder === self, event.window === self.window else { return event }
            if event.keyCode == 49 && event.type == .keyUp && self.consumedSpace { self.consumedSpace = false; return nil }
            if event.keyCode == 49 && event.type == .keyDown && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command] {
                if event.isARepeat && self.consumedSpace { return nil }
                if self.switchKeyboard?() == true { self.consumedSpace = true; return nil }
            }
            if event.modifierFlags.contains(.command) { self.key(event); return nil }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in MainActor.assumeIsolated {
            guard let self, note.object as? NSWindow === self.window else { return }; self.releaseInput()
        } }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { resizeWork?.cancel(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func releaseInput() { dragging.removeAll(); consumedSpace = false; release?() }
    override func resignFirstResponder() -> Bool { releaseInput(); return true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true; resized() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resized() }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit(); resized()
    }
    private func resized() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window != nil, self.bounds.width >= 160, self.bounds.height >= 100 else { return }
            self.viewportChanged?(self.bounds.size, self.window?.backingScaleFactor ?? 1)
        }
        resizeWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { addCursorRect(AVMakeRect(aspectRatio: size, insideRect: bounds), cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { pointer(event, kind: "move") }
    func setCursor(_ message: RemoteCursor) {
        guard let cursor = message.cursor() else { return }
        self.cursor = cursor; window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow,
           RemoteGeometry.normalized(convert(window.mouseLocationOutsideOfEventStream, from: nil), frame: size, bounds: bounds, clamp: false) != nil { cursor.set() }
    }
    func display(_ sample: CMSampleBuffer, frame: RemoteVideo) {
        if epoch != frame.epoch || videoLayer.status == .failed || !videoLayer.isReadyForMoreMediaData { videoLayer.flush() }
        let nextSize = CGSize(width: frame.width, height: frame.height)
        if size != nextSize { size = nextSize; window?.invalidateCursorRects(for: self) }
        epoch = frame.epoch; videoLayer.enqueue(sample)
    }
    private func pointer(_ event: NSEvent, kind: String) {
        let point = convert(event.locationInWindow, from: nil)
        let clamp = (kind == "drag" || kind == "up") && dragging.contains(event.buttonNumber)
        guard let normalized = RemoteGeometry.normalized(point, frame: size, bounds: bounds, clamp: clamp) else { return }
        if kind == "down" { window?.makeFirstResponder(self); dragging.insert(event.buttonNumber) }
        if kind == "up" { dragging.remove(event.buttonNumber) }
        send?(RemoteInput(kind: kind, x: normalized.x, y: normalized.y, code: ["down", "up", "drag"].contains(kind) ? UInt16(min(2, max(0, event.buttonNumber))) : 0, flags: UInt64(event.modifierFlags.rawValue), deltaX: kind == "scroll" ? Double(event.scrollingDeltaX) : 0, deltaY: kind == "scroll" ? Double(event.scrollingDeltaY) : 0, clicks: ["down", "up"].contains(kind) ? event.clickCount : 1, epoch: epoch, phase: kind == "scroll" ? UInt64(event.phase.rawValue) : 0, momentum: kind == "scroll" ? UInt64(event.momentumPhase.rawValue) : 0, precise: kind == "scroll" && event.hasPreciseScrollingDeltas))
    }
    private func key(_ event: NSEvent) { send?(RemoteInput(kind: event.type == .keyDown ? "keyDown" : event.type == .keyUp ? "keyUp" : "flags", code: event.keyCode, flags: UInt64(event.modifierFlags.rawValue), text: event.type == .flagsChanged ? "" : event.characters ?? "")) }
    override func keyDown(with event: NSEvent) { key(event) }
    override func keyUp(with event: NSEvent) { key(event) }
    override func flagsChanged(with event: NSEvent) { key(event) }
    override func mouseDown(with event: NSEvent) { pointer(event, kind: "down") }
    override func mouseUp(with event: NSEvent) { pointer(event, kind: "up") }
    override func rightMouseDown(with event: NSEvent) { pointer(event, kind: "down") }
    override func rightMouseUp(with event: NSEvent) { pointer(event, kind: "up") }
    override func otherMouseDown(with event: NSEvent) { pointer(event, kind: "down") }
    override func otherMouseUp(with event: NSEvent) { pointer(event, kind: "up") }
    override func mouseMoved(with event: NSEvent) { pointer(event, kind: "move") }
    override func mouseDragged(with event: NSEvent) { pointer(event, kind: "drag") }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, kind: "drag") }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, kind: "drag") }
    override func scrollWheel(with event: NSEvent) { pointer(event, kind: "scroll") }
}

struct RemoteScreen: NSViewRepresentable {
    let client: RemoteClient
    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        client.screen.frame = wrapper.bounds; client.screen.autoresizingMask = [.width, .height]
        wrapper.addSubview(client.screen); return wrapper
    }
    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { CGSize(width: proposal.width ?? 640, height: proposal.height ?? 400) }
}
