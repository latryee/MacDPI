import Darwin
import Dispatch
import Foundation

/// A single process-lifetime bridge from parent input and termination signals to poll().
/// Consumers keep this object alive and poll readDescriptor without draining it.
final class TUNStopChannel: @unchecked Sendable {
    let readDescriptor: Int32

    private let writeDescriptor: Int32
    private let lock = NSLock()
    private var requested = false
    private var parentSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    init?(parentDescriptor: Int32 = STDIN_FILENO) {
        // Keep every descriptor local until all setup that can fail has passed.
        // A failed initializer must not let deinit close descriptors a second time.
        let parent = fcntl(parentDescriptor, F_DUPFD_CLOEXEC, 3)
        guard parent >= 0 else { return nil }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            let error = errno
            close(parent)
            errno = error
            return nil
        }
        let reader = descriptors[0], writer = descriptors[1]
        let readerFlags = fcntl(reader, F_GETFD)
        let writerFlags = fcntl(writer, F_GETFD)
        let statusFlags = fcntl(writer, F_GETFL)
        guard reader >= 3, writer >= 3,
              readerFlags >= 0, writerFlags >= 0, statusFlags >= 0,
              fcntl(reader, F_SETFD, readerFlags | FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFD, writerFlags | FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            let error = errno
            close(reader)
            close(writer)
            close(parent)
            errno = error
            return nil
        }
        self.readDescriptor = reader
        self.writeDescriptor = writer

        let queue = DispatchQueue(label: "io.github.latryee.MacDPI.tun-stop", qos: .userInitiated)
        let parentSource = DispatchSource.makeReadSource(fileDescriptor: parent, queue: queue)
        parentSource.setEventHandler { [weak self] in self?.request() }
        // Dispatch must finish using its descriptor before it is closed. The
        // duplicate also leaves ownership of the caller's input unchanged.
        parentSource.setCancelHandler { close(parent) }
        self.parentSource = parentSource
        parentSource.resume()

        // Match the helper's signal handling pattern. The instance lasts until
        // process exit, so these dispositions are intentionally process-wide.
        self.signalSources = [SIGTERM, SIGINT].map { value in
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: queue)
            source.setEventHandler { [weak self] in self?.request() }
            source.resume()
            return source
        }
    }

    private func request() {
        lock.lock()
        guard !requested else { lock.unlock(); return }
        requested = true
        var byte: UInt8 = 1
        // The writer is nonblocking and only this first request writes a byte.
        // EINTR is the only retry; readiness remains latched for every waiter.
        while Darwin.write(writeDescriptor, &byte, 1) < 0 && errno == EINTR {}
        lock.unlock()
        parentSource?.cancel()
    }

    deinit {
        parentSource?.cancel()
        signalSources.forEach { $0.cancel() }
        // Event handlers hold self strongly only while request() is running;
        // weak captures prevent a source cycle and exclude concurrent writes here.
        close(writeDescriptor)
        close(readDescriptor)
    }
}
