// SPDX-License-Identifier: GPL-2.0-or-later
import Darwin
import Foundation
import Synchronization

/// An exclusive BSD `flock(2)` on a lock file: the library lock of docs/game-manager-engine.md,
/// "Lock contract", which the engine takes with Go's `syscall.Flock` on the same file.
/// The lock belongs to the open file description, so it also excludes another `FileLock` on the
/// same file in this process. Closing the descriptor (`release()` or `deinit`) releases it.
public final class FileLock: Sendable {
    /// How often `acquire` retries a lock held elsewhere.
    static let pollInterval = Duration.milliseconds(100)

    /// The locked descriptor; -1 once released.
    private let fd: Mutex<Int32>

    private init(fd: Int32) { self.fd = Mutex(fd) }

    deinit { release() }

    /// Takes the lock on `url`, creating the file with mode 0644 if it is missing (its directory
    /// must exist). While another holder has it, retries every 100 ms without blocking a thread.
    /// Throws `CancellationError` when the task is cancelled before the lock is taken.
    public static func acquire(_ url: URL) async throws -> FileLock {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { errno = EINVAL; return -1 }
            return open(path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o644))
        }
        guard fd >= 0 else { throw POSIXError.current() }
        do {
            while true {
                try Task.checkCancellation()
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { return FileLock(fd: fd) }
                switch errno {
                case EINTR: continue
                case EWOULDBLOCK: try await Task.sleep(for: pollInterval)
                default: throw POSIXError.current()
                }
            }
        } catch {
            close(fd)
            throw error
        }
    }

    /// Releases the lock. Calling it again does nothing.
    public func release() {
        let old = fd.withLock { fd in
            defer { fd = -1 }
            return fd
        }
        if old >= 0 { close(old) }
    }
}

extension POSIXError {
    /// The error for the current `errno`.
    static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
