import Darwin
import Foundation

/// A per-user advisory lock. The file intentionally remains on disk; deleting
/// a locked inode would allow a second process to lock a replacement file.
final class SingleInstanceLock {
    enum LockError: Error {
        case storageUnavailable
        case unsafeLockFile
        case lockFailed(Int32)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() throws -> SingleInstanceLock? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RebornQuota", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw LockError.storageUnavailable
        }

        let path = directory.appendingPathComponent("reborn-quota.lock").path
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw LockError.lockFailed(errno) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw LockError.unsafeLockFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw LockError.lockFailed(lockError)
        }

        _ = ftruncate(descriptor, 0)
        let pidText = "\(getpid())\n"
        pidText.withCString { bytes in
            _ = Darwin.write(descriptor, bytes, strlen(bytes))
        }
        return SingleInstanceLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
