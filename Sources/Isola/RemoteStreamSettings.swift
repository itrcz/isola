import Foundation

// Pixel dimensions travel with a revision. Inputs from a frame preceding a
// display reconfiguration must never click a different control in the new UI.
struct RemoteViewport: Codable, Equatable {
    var width: Int
    var height: Int
    var scale: Double
    var quality: String = "retina"
    var epoch: UInt64 = 1
    var valid: Bool {
        (320...4096).contains(width) && (200...4096).contains(height) &&
        width % 2 == 0 && height % 2 == 0 && width * height <= 8_847_360 &&
        scale.isFinite && (1...2).contains(scale) &&
        ["retina", "balanced", "responsive"].contains(quality) && epoch > 0
    }
    static func fitting(width: Double, height: Double, backingScale: Double, quality: String, epoch: UInt64) -> Self {
        let scale = quality == "retina" ? min(2, max(1, backingScale)) : 1
        var w = max(320, width * scale), h = max(200, height * scale)
        let factor = min(1, 4096 / max(w, h), sqrt(8_847_360 / (w * h)))
        w *= factor; h *= factor
        return Self(width: max(320, Int(w) / 2 * 2), height: max(200, Int(h) / 2 * 2), scale: scale, quality: quality, epoch: epoch)
    }
    var bitRate: Int {
        // Desktop text needs more bits than a camera image, especially at Retina.
        min(80_000_000, max(12_000_000, width * height * (quality == "retina" ? 12 : 8)))
    }
}

// A bounded sliding window, rather than "send completed" (only a TCP-buffer
// acknowledgement). Dropping raw frames is safe; dropping encoded P frames isn't.
struct RemoteFrameWindow {
    private(set) var outstanding: [UInt64: Double] = [:]
    let capacity = 2
    var available: Bool { outstanding.count < capacity }
    mutating func sent(_ sequence: UInt64, at time: Double) { outstanding[sequence] = time }
    mutating func acknowledge(_ sequence: UInt64, at time: Double) -> Double? {
        guard let sent = outstanding.removeValue(forKey: sequence) else { return nil }
        return max(0, time - sent)
    }
    var oldest: Double? { outstanding.values.min() }
}
