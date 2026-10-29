import Foundation
import Darwin

// All descriptor access, framing and encoding live on one queue. Readiness
// notifications replace the old 2 MiB / 100 ms polling budget.
final class ClipboardTransport: @unchecked Sendable {
    static let maximumFrame = 90 * 1024 * 1024
    private let queue = DispatchQueue(label: "org.isola.clipboard.transport", qos: .userInitiated)
    private let fd: Int32
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var writerResumed = false
    private var readerPaused = false
    private var stopped = false
    private var incoming = Data()
    private var outgoing = Data()
    private var written = 0
    private var pending: [String: (ClipboardMessage, Bool)] = [:]
    private let receive: (ClipboardMessage, @escaping () -> Void) -> Void
    private let onClose: () -> Void

    init(fd: Int32, receive: @escaping (ClipboardMessage, @escaping () -> Void) -> Void, onClose: @escaping () -> Void) {
        self.fd = fd; self.receive = receive; self.onClose = onClose
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    func start() {
        queue.async { [self] in
            guard !stopped, reader == nil else { return }
            let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            // Close only after both sources have drained their event handlers.
            let group = DispatchGroup()
            group.enter(); group.enter()
            read.setCancelHandler { group.leave() }
            write.setCancelHandler { group.leave() }
            let descriptor = fd
            group.notify(queue: queue) { Darwin.close(descriptor) }
            read.setEventHandler { [weak self] in self?.readAvailable() }
            write.setEventHandler { [weak self] in self?.flush() }
            reader = read; writer = write
            read.resume()
        }
    }
    func stop() { queue.async { [self] in close() } }
    private func close() {
        guard !stopped else { return }
        stopped = true
        if let reader {
            reader.cancel(); writer?.cancel()
            if readerPaused { reader.resume(); readerPaused = false }
            if !writerResumed { writer?.resume() }
        } else { Darwin.close(fd) }
        reader = nil; writer = nil
        incoming = Data(); outgoing = Data(); pending.removeAll()
        onClose()
    }
    func send(_ message: ClipboardMessage, binary: Bool) {
        queue.async { [self] in
            guard !stopped else { return }
            // At most one queued update per kind, so a slow guest cannot build
            // an unbounded backlog. A partially written frame is never replaced.
            pending[message.kind] = (message, binary)
            flush()
        }
    }
    static func encode(_ message: ClipboardMessage, binary: Bool) throws -> Data {
        if binary {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            return try encoder.encode(message)
        }
        return try JSONEncoder().encode(message)
    }
    private func flush() {
        guard !stopped else { return }
        for _ in 0..<64 {
            if outgoing.isEmpty {
                // Keyboard and control updates precede the next file transfer.
                guard let key = pending.keys.sorted(by: {
                    ($0 == "clipboard" ? 1 : 0, $0) < ($1 == "clipboard" ? 1 : 0, $1)
                }).first, let (message, binary) = pending.removeValue(forKey: key) else {
                    if writerResumed { writer?.suspend(); writerResumed = false }
                    return
                }
                guard let payload = try? Self.encode(message, binary: binary),
                      payload.count <= Self.maximumFrame else { continue }
                let length = UInt32(payload.count)
                outgoing = Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
                outgoing.append(payload); written = 0
            }
            if !writerResumed { writer?.resume(); writerResumed = true }
            let count = outgoing.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: written), min(outgoing.count - written, 256 * 1024))
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
            if count == 0 { return }
            written += count
            if written == outgoing.count { outgoing = Data(); written = 0 }
        }
    }
    private func deliverIncoming() -> Bool {
        guard incoming.count >= 4 else { return false }
        let length = incoming.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= Self.maximumFrame else { close(); return true }
        guard incoming.count >= length + 4 else { return false }
        let start = incoming.startIndex + 4
        let payload = incoming.subdata(in: start..<(start + length))
        incoming.removeFirst(length + 4)
        let message: ClipboardMessage?
        if payload.starts(with: Data("bplist00".utf8)) {
            message = try? PropertyListDecoder().decode(ClipboardMessage.self, from: payload)
        } else { message = try? JSONDecoder().decode(ClipboardMessage.self, from: payload) }
        guard let message else { close(); return true }
        // Only one decoded message may wait for the main actor at a time.
        reader?.suspend(); readerPaused = true
        receive(message) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.reader?.resume(); self.readerPaused = false
                self.readAvailable()
            }
        }
        return true
    }
    private func readAvailable() {
        guard !stopped, !readerPaused else { return }
        if deliverIncoming() { return }
        var scratch = [UInt8](repeating: 0, count: 256 * 1024)
        for _ in 0..<64 {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count == 0 { close(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { close() }
                return
            }
            incoming.append(contentsOf: scratch.prefix(count))
            if deliverIncoming() { return }
        }
    }
}
