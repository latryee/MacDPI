import Darwin
import Foundation

public enum TUNJournalStoreError: Error, Equatable {
    case unsafeDirectory, unsafeFile, anotherSession, invalidRecord, io(Int32)
}

/// A single journal in an already securely opened private directory. The privileged caller must
/// open that directory without following symlinks or traversing attacker-controlled parents.
/// The persistent lock file serializes helpers without trusting a stale process ID.
public final class TUNFileRouteJournalStore: TUNRouteJournalStore {
    private let directory: Int32
    private let lock: Int32
    private let owner: uid_t
    private static let record = "route-journal.json"
    private static let maximumSize = 128 * 1_024

    public init(directoryDescriptor: Int32, owner: uid_t = 0) throws {
        let directory = fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else { throw TUNJournalStoreError.io(errno) }
        do {
            var attributes = stat()
            guard fstat(directory, &attributes) == 0 else { throw TUNJournalStoreError.io(errno) }
            guard attributes.st_uid == owner, attributes.st_mode & mode_t(S_IFMT) == S_IFDIR,
                  attributes.st_mode & 0o777 == 0o700, geteuid() == owner else { throw TUNJournalStoreError.unsafeDirectory }
            let lock = openat(directory, "route-journal.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lock >= 0 else { throw TUNJournalStoreError.io(errno) }
            do {
                _ = try Self.fileAttributes(lock, owner: owner)
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK { throw TUNJournalStoreError.anotherSession }
                    throw TUNJournalStoreError.io(errno)
                }
            } catch {
                close(lock)
                throw error
            }
            self.directory = directory
            self.lock = lock
            self.owner = owner
        } catch {
            close(directory)
            throw error
        }
    }

    deinit {
        close(lock)
        close(directory)
    }

    public func load() throws -> TUNRouteJournal? {
        let file = openat(directory, Self.record, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if file < 0 {
            if errno == ENOENT { return nil }
            throw TUNJournalStoreError.io(errno)
        }
        defer { close(file) }
        let attributes = try Self.fileAttributes(file, owner: owner)
        guard attributes.st_size > 0, attributes.st_size <= Self.maximumSize else { throw TUNJournalStoreError.invalidRecord }
        var bytes = Data(count: Int(attributes.st_size))
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let address = buffer.baseAddress else { throw TUNJournalStoreError.invalidRecord }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(file, address.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    if count == 0 { throw TUNJournalStoreError.invalidRecord }
                    throw TUNJournalStoreError.io(errno)
                }
                offset += count
            }
        }
        var extra: UInt8 = 0
        var count: Int
        repeat { count = Darwin.read(file, &extra, 1) } while count < 0 && errno == EINTR
        guard count == 0, let record = try? JSONDecoder().decode(TUNRouteJournal.self, from: bytes), record.isValid else {
            throw TUNJournalStoreError.invalidRecord
        }
        return record
    }

    public func save(_ journal: TUNRouteJournal) throws {
        guard journal.isValid else { throw TUNJournalStoreError.invalidRecord }
        let bytes = try JSONEncoder().encode(journal)
        guard bytes.count <= Self.maximumSize else { throw TUNJournalStoreError.invalidRecord }
        let temporary = ".route-journal-\(UUID().uuidString)"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw TUNJournalStoreError.io(errno) }
        defer {
            close(file)
            _ = unlinkat(directory, temporary, 0)
        }
        guard fchmod(file, 0o600) == 0 else { throw TUNJournalStoreError.io(errno) }
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let address = buffer.baseAddress else { throw TUNJournalStoreError.invalidRecord }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(file, address.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TUNJournalStoreError.io(count == 0 ? EIO : errno) }
                offset += count
            }
        }
        try Self.sync(file)
        guard renameat(directory, temporary, directory, Self.record) == 0 else { throw TUNJournalStoreError.io(errno) }
        try Self.sync(directory)
    }

    public func clear() throws {
        if unlinkat(directory, Self.record, 0) != 0 && errno != ENOENT { throw TUNJournalStoreError.io(errno) }
        try Self.sync(directory)
    }

    private static func sync(_ file: Int32) throws {
        var result: Int32
        repeat { result = fsync(file) } while result != 0 && errno == EINTR
        guard result == 0 else { throw TUNJournalStoreError.io(errno) }
    }

    private static func fileAttributes(_ descriptor: Int32, owner: uid_t) throws -> stat {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw TUNJournalStoreError.io(errno) }
        guard attributes.st_uid == owner, attributes.st_mode & mode_t(S_IFMT) == S_IFREG,
              attributes.st_mode & 0o777 == 0o600, attributes.st_nlink == 1 else { throw TUNJournalStoreError.unsafeFile }
        return attributes
    }
}
