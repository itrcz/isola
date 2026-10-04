import Foundation
import Darwin

// Held for the entire VM session, including restore and asynchronous startup.
final class VMDirectoryLock {
    private let fd: Int32
    init(folder: URL) throws {
        let path = folder.appendingPathComponent(".session.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AppError.message(L("Не удалось заблокировать папку VM.", "Could not lock the VM folder.")) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AppError.message(L("Эта VM уже открыта в другом экземпляре Isola. Сначала выключи её там.", "This VM is open in another Isola instance. Shut it down there first."))
        }
        fd = descriptor
    }
    deinit { Darwin.close(fd) }
}
