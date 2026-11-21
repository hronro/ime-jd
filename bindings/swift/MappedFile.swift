// A file mapped read-only into memory, for the user dictionary's text and
// cached blob. Shared source, compiled into both the macOS and iOS frontends.

import Foundation

/// A file's bytes, mapped read-only: at a fixed, page-aligned address until
/// the last reference goes, read without a copy. Pages a file backs and
/// nobody writes are clean — the kernel can drop and re-read them at will —
/// so they count against no process memory limit, an iOS extension's
/// included, and cost nothing until touched. The file must be replaced (an
/// atomic write: a new file renamed over it) and never rewritten in place
/// while it is mapped; a mapping keeps the file it was made from.
final class MappedFile {
    /// The file's bytes; empty for an empty file.
    let bytes: UnsafeRawBufferPointer

    private init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    deinit {
        if let base = bytes.baseAddress {
            munmap(UnsafeMutableRawPointer(mutating: base), bytes.count)
        }
    }

    /// The file at `url`, mapped; nil when there is no such file.
    static func open(_ url: URL) throws -> MappedFile? {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.posixError()
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.posixError() }
        let size = Int(info.st_size)
        guard size > 0 else {
            return MappedFile(bytes: UnsafeRawBufferPointer(start: nil, count: 0))
        }
        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              base != UnsafeMutableRawPointer(bitPattern: -1) // MAP_FAILED
        else { throw Self.posixError() }
        return MappedFile(bytes: UnsafeRawBufferPointer(start: base, count: size))
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
