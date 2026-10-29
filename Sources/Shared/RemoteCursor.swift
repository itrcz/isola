import AppKit

struct RemoteCursor: Codable {
    var png: Data
    var width: Double
    var height: Double
    var hotX: Double
    var hotY: Double
    var valid: Bool {
        !png.isEmpty && png.count <= 64 * 1024 && width.isFinite && height.isFinite && hotX.isFinite && hotY.isFinite &&
        (1...128).contains(width) && (1...128).contains(height) && (0...width).contains(hotX) && (0...height).contains(hotY)
    }
    private var safePNG: Bool {
        guard png.count >= 24, Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              String(data: png[12..<16], encoding: .ascii) == "IHDR" else { return false }
        let w = png[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let h = png[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        return (1...256).contains(w) && (1...256).contains(h)
    }
    @MainActor func cursor() -> NSCursor? {
        guard valid, safePNG, let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide <= 256, bitmap.pixelsHigh <= 256,
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
        let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(bitmap)
        return NSCursor(image: image, hotSpot: NSPoint(x: hotX, y: hotY))
    }
}

// Runs only in the guest agent while a remote controller is present. macOS
// balances per-process cursor hiding on exit; a short lease also restores it if
// the host disappears without closing the virtual serial port.
@MainActor final class GuestRemoteCursor {
    private var timer: Timer?
    private var hidden = false
    private var last: Data?
    private var lastHotSpot = NSPoint.zero
    private var lastSize = NSSize.zero
    private var deadline = 0.0
    private let currentCursor: () -> NSCursor?
    private let hide: () -> Bool
    private let show: () -> Void
    private let clock: () -> Double
    init(currentCursor: @escaping () -> NSCursor? = { NSCursor.currentSystem }, hide: @escaping () -> Bool = { CGDisplayHideCursor(CGMainDisplayID()) == .success }, show: @escaping () -> Void = { CGDisplayShowCursor(CGMainDisplayID()) }, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.currentCursor = currentCursor; self.hide = hide; self.show = show; self.clock = clock
    }
    var send: ((RemoteCursor) -> Void)?
    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); return }
        deadline = clock() + 8
        guard timer == nil else { return }
        publish()
        hidden = hide()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.tick()
        } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func tick() { if clock() > deadline { stop() } else { publish() } }
    private func publish() {
        // Public AppKit API, including cursors belonging to other guest apps.
        guard let cursor = currentCursor() else { return }
        // A system cursor can contain very large accessibility representations.
        // Select a screen-sized CGImage instead of decoding the whole multi-image TIFF.
        var rect = NSRect(origin: .zero, size: cursor.image.size)
        guard let cg = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width <= 256, cg.height <= 256, let bytes = cg.dataProvider?.data else { return }
        let signature = bytes as Data
        guard signature != last || cursor.hotSpot != lastHotSpot || cursor.image.size != lastSize,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let message = RemoteCursor(png: png, width: cursor.image.size.width, height: cursor.image.size.height, hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y)
        guard message.valid else { return }
        last = signature; lastHotSpot = cursor.hotSpot; lastSize = cursor.image.size; send?(message)
    }
    func stop() {
        timer?.invalidate(); timer = nil; last = nil
        if hidden { show(); hidden = false }
    }
}
