import AppKit
import Carbon

@MainActor enum InputSources {
    static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
    static var current: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }
    static func select(_ identifier: String) -> Bool {
        guard let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: identifier] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource] else { return false }
        for source in sources {
            // Already-enabled sources do not need enabling again (some IMEs reject it).
            if TISSelectInputSource(source) == noErr { return true }
            if TISEnableInputSource(source) == noErr && TISSelectInputSource(source) == noErr { return true }
        }
        return false
    }
    @discardableResult static func cycle() -> Bool {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as [String: Any]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource], sources.count > 1 else { return false }
        let index = sources.firstIndex { string($0, kTISPropertyInputSourceID) == current } ?? -1
        return TISSelectInputSource(sources[(index + 1) % sources.count]) == noErr
    }
}
