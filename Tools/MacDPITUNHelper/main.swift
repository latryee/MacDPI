import Darwin
import Dispatch
import Foundation

private let journalDirectory = "/var/db/io.github.latryee.macdpi"

private func journal() throws -> TUNFileRouteJournalStore {
    if mkdir(journalDirectory, 0o700) < 0 && errno != EEXIST { throw POSIXError(.EACCES) }
    let fd = open(journalDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(.EACCES) }
    defer { close(fd) }
    return try TUNFileRouteJournalStore(directoryDescriptor: fd)
}

private final class SignalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func stop() { lock.lock(); value = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func session(_ identifier: String, uid: uid_t, worker: URL) throws {
    let backend = DarwinRouteBackend()
    let transaction = TUNRouteTransaction(backend: backend, store: try journal())
    try transaction.auditRecovery()
    let listener = identifier.withCString { macdpi_tun_broker_listen($0, uid) }
    guard listener >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(listener); _ = identifier.withCString { macdpi_tun_broker_unlink($0, uid) } }
    let peer = worker.path.withCString { macdpi_tun_broker_accept(listener, uid, $0, 12_000) }
    guard peer >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES) }
    defer { close(peer) }
    _ = identifier.withCString { macdpi_tun_broker_unlink($0, uid) }

    let interrupt = SignalLatch()
    let signals = [SIGINT, SIGTERM, SIGHUP].map { value in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: .global(qos: .utility))
        source.setEventHandler { interrupt.stop() }
        source.resume()
        return source
    }
    defer { signals.forEach { $0.cancel() } }
    var drained = false
    var transferred = false
    var lease: TUNRouteLease?
    var final: UInt8 = 70 // F means the broker could not verify cleanup.
    defer { _ = macdpi_tun_control_send(peer, final) }

    func engineIsReady() -> Bool {
        guard !interrupt.isStopped, !drained else { return false }
        var byte: UInt8 = 0
        let result = recv(peer, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
    }

    backend.beforeRelease = {
        guard transferred, !drained else { return }
        _ = macdpi_tun_control_send(peer, 83) // S requests the worker to close its duplicate.
        var byte: UInt8 = 0
        let result = macdpi_tun_control_receive(peer, &byte, 3_500)
        drained = (result == 1 && byte == 83) || result == 0
    }

    func restore() throws {
        if let lease, backend.owns(lease), transaction.phase == .disabled {
            try backend.release(lease)
            let observed = try backend.snapshot(excluding: nil)
            guard !observed.interfaces.contains(lease.interfaceIndex),
                  !observed.routes.contains(where: { $0.isAssociated(with: lease) }) else {
                throw TUNRouteError.restorationUnverified
            }
        } else {
            try transaction.disable()
        }
        final = 68 // D is sent only after the broker has checked that owned state is gone.
    }

    do {
        let original = try backend.snapshot(excluding: nil)
        let (ownedLease, packetFD) = try backend.open(baseline: original)
        lease = ownedLease
        let plan = try TUNRoutePlan.make(snapshot: backend.snapshot(excluding: ownedLease), lease: ownedLease)
        guard plan.baseline == original.baseline else { throw TUNRouteError.baselineChanged }
        let v4 = plan.baseline.defaults.first(where: { $0.family == .ipv4 })?.interfaceIndex ?? 0
        let v6 = plan.baseline.defaults.first(where: { $0.family == .ipv6 })?.interfaceIndex ?? 0
        // A failed send may have delivered the descriptor before failing on the payload.
        transferred = true
        guard macdpi_tun_broker_send_fd(peer, packetFD, v4, v6) == 0 else { throw TUNRouteError.engineNotReady }
        var byte: UInt8 = 0
        guard macdpi_tun_control_receive(peer, &byte, 12_000) == 1, byte == 82 else { // R
            throw TUNRouteError.engineNotReady
        }
        try transaction.activate(plan, engineIsReady: engineIsReady)
        guard macdpi_tun_control_send(peer, 65) == 0 else { throw TUNRouteError.engineNotReady } // A
        while !interrupt.isStopped {
            let result = macdpi_tun_control_receive(peer, &byte, 4_000)
            if result == 0 || (result == 1 && byte == 83) { drained = true; break }
            guard result < 0 && errno == ETIMEDOUT else { break }
            try transaction.checkHealth(engineIsReady: engineIsReady)
        }
    } catch {
        // No payloads, addresses, or configuration content are logged by the broker.
        let detail = (error as? TUNRouteError).map(String.init(describing:)) ?? "operating-system error"
        fputs("MacDPI TUN stopped: \(detail).\n", stderr)
        try restore()
        throw error
    }
    try restore()
}

do {
    guard geteuid() == 0, let caller = ProcessInfo.processInfo.environment["SUDO_UID"],
          let uid = uid_t(caller), uid > 0 else { throw POSIXError(.EPERM) }
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["recover"] {
        let transaction = TUNRouteTransaction(backend: DarwinRouteBackend(), store: try journal())
        try transaction.auditRecovery()
        print("MacDPI recovery check passed. No recorded tunnel remains.")
    } else if arguments.count == 2, arguments[0] == "run", let identifier = UUID(uuidString: arguments[1]),
              identifier.uuidString.lowercased() == arguments[1] {
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let worker = ownPath.deletingLastPathComponent().appendingPathComponent("MacDPITUNEngine")
        try session(arguments[1], uid: uid, worker: worker)
    } else { throw POSIXError(.EINVAL) }
} catch {
    fputs("MacDPI helper did not complete. Check the application status or run the documented recovery check.\n", stderr)
    exit(1)
}
