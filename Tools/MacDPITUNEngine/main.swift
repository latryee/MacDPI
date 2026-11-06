import Darwin
import Foundation
import SystemConfiguration

private struct Options {
    let session: String
    let profile: Int32
    let splitOffset: Int32
    let dnsOverHTTPS: Int32
    let originRepair: Int32
    let domains: [UInt8]

    init?(arguments: [String]) {
        guard (6...7).contains(arguments.count), getuid() > 0, geteuid() == getuid(),
              arguments[1].withCString({ macdpi_tun_session_valid($0) }) == 1,
              let profile = Int32(arguments[2]), (0...2).contains(profile),
              let offset = Int32(arguments[3]), (1...16_000).contains(offset),
              let doh = Int32(arguments[4]), (0...1).contains(doh),
              let repair = Int32(arguments.count == 7 ? arguments[6] : "0"),
              repair == 0 || (repair == 1 && doh == 1 && profile != 0),
              let domains = Self.domains(explicit: arguments[5], encrypted: doh == 1) else { return nil }
        self.session = arguments[1]
        self.profile = profile
        self.splitOffset = offset
        self.dnsOverHTTPS = doh
        self.originRepair = repair
        self.domains = domains
    }

    private static func domains(explicit: String, encrypted: Bool) -> [UInt8]? {
        guard encrypted else { return [] }
        guard explicit.utf8.count <= 128 * 255 - 1 else { return nil }
        var names = Set<String>()
        func add(_ name: String) -> Bool {
            guard validTUNSplitDomain(name[...]) else { return false }
            let canonical = name.hasSuffix(".") ? String(name.dropLast()) : name
            names.insert(canonical.lowercased())
            return names.count <= 128
        }
        if !explicit.isEmpty {
            for name in explicit.split(separator: "\n", omittingEmptySubsequences: false) where !add(String(name)) { return nil }
        }
        // Keep only domain routing information in memory. Reading Dynamic Store
        // avoids changing any system resolver or per-service DNS preference.
        guard let store = SCDynamicStoreCreate(nil, "MacDPI TUN" as CFString, nil, nil),
              let snapshot = SCDynamicStoreCopyMultiple(store, ["State:/Network/Global/DNS"] as CFArray,
                                                        ["State:/Network/Service/[^/]+/DNS"] as CFArray) as? [String: [String: Any]] else { return nil }
        for service in snapshot.values {
            for key in [kSCPropNetDNSSearchDomains as String, kSCPropNetDNSSupplementalMatchDomains as String] {
                guard let value = service[key] else { continue }
                guard let domains = value as? [String], domains.count <= 128 else { return nil }
                // An empty supplemental match domain is an all-domain policy.
                // A local DoH override cannot safely honor it, so refuse start.
                for domain in domains where !add(domain) { return nil }
            }
            if let value = service[kSCPropNetDNSDomainName as String] {
                guard let domain = value as? String, add(domain) else { return nil }
            }
        }
        return Array(names.sorted().joined(separator: "\n").utf8)
    }
}

private enum Outcome: Int32 {
    case disabled = 0
    case failed = 1
    case recoveryRequired = 2
    case cancelled = 3
    case failedClean = 4
    case authorizationTimeout = 5
    case helperConnectionFailed = 6

    var status: String {
        switch self {
        case .disabled: return "DISABLED"
        case .failed: return "FAILED"
        case .recoveryRequired: return "RECOVERY_REQUIRED"
        case .cancelled: return "CANCELLED"
        case .failedClean: return "FAILED_CLEAN"
        case .authorizationTimeout: return "AUTHORIZATION_TIMEOUT"
        case .helperConnectionFailed: return "HELPER_CONNECTION_FAILED"
        }
    }
}

private enum Event {
    case broker(UInt8?)
    case engine(UInt8?)
    case parentStop
    case timeout
    case failure
}

private let stop = UInt8(ascii: "S")
private let ready = UInt8(ascii: "R")
private let active = UInt8(ascii: "A")
private let done = UInt8(ascii: "D")
private let failedAfterCleanup = UInt8(ascii: "X")
private let recovery = UInt8(ascii: "F")

@discardableResult private func report(_ status: String) -> Bool {
    let bytes = Array((status + "\n").utf8)
    return bytes.withUnsafeBytes { data in
        guard let address = data.baseAddress else { return false }
        var sent = 0
        while sent < data.count {
            let length = Darwin.write(STDOUT_FILENO, address.advanced(by: sent), data.count - sent)
            if length < 0 && errno == EINTR { continue }
            guard length > 0 else { return false }
            sent += length
        }
        return true
    }
}

private func awaitEvent(broker: Int32, engine: Int32, timeout: Int32) -> Event {
    let descriptors = [STDIN_FILENO, broker, engine]
    var fds = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
    let deadline = timeout >= 0 ? DispatchTime.now() + .milliseconds(Int(timeout)) : nil
    while true {
        let remaining: Int32
        if let deadline {
            let now = DispatchTime.now().uptimeNanoseconds
            remaining = deadline.uptimeNanoseconds <= now ? 0 : Int32((deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
        } else {
            remaining = -1
        }
        let count = poll(&fds, nfds_t(descriptors.count), remaining)
        if count < 0 && errno == EINTR { continue }
        if count < 0 { return .failure }
        if count == 0 { return .timeout }
        if fds[0].revents != 0 { return .parentStop }
        func byte(_ fd: Int32) -> UInt8? {
            var value: UInt8 = 0
            return macdpi_tun_control_receive(fd, &value, 0) == 1 ? value : nil
        }
        if fds[1].revents != 0 { return .broker(byte(broker)) }
        if fds[2].revents != 0 { return .engine(byte(engine)) }
    }
}

private func confirmRestoration(_ broker: Int32, then outcome: Outcome) -> Outcome {
    // The broker can send its final acknowledgement and close before our stop reaches it.
    _ = macdpi_tun_control_send(broker, stop)
    report("RESTORING")
    let deadline = DispatchTime.now() + .seconds(20)
    while DispatchTime.now() < deadline {
        let now = DispatchTime.now().uptimeNanoseconds
        let left = deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0
        var message: UInt8 = 0
        guard macdpi_tun_control_receive(broker, &message, Int32((left + 999_999) / 1_000_000)) == 1 else { return .recoveryRequired }
        switch message {
        case done: return outcome == .failed ? .failedClean : outcome
        case failedAfterCleanup: return .failedClean
        case recovery: return .recoveryRequired
        case stop, active: continue // A queued activation acknowledgement may cross Disable.
        default: return .recoveryRequired
        }
    }
    return .recoveryRequired
}

private func run(_ options: Options) -> Outcome {
    let broker = options.session.withCString { macdpi_tun_broker_connect($0, STDIN_FILENO, 90_000) }
    guard broker >= 0 else {
        switch errno {
        case ECANCELED: return .cancelled
        case ETIMEDOUT: return .authorizationTimeout
        default: return .helperConnectionFailed
        }
    }
    defer { close(broker) }
    // The helper may already be opening the interface before it sends the packet descriptor.
    let parentListening = report("CONFIGURING")

    var packet: Int32 = -1
    var ipv4: UInt32 = 0
    var ipv6: UInt32 = 0
    guard macdpi_tun_broker_receive_fd(broker, &packet, &ipv4, &ipv6, 10_000) == 0 else {
        if errno == ECANCELED { return .failedClean }
        if errno == ESTALE { return .recoveryRequired }
        return confirmRestoration(broker, then: .failed)
    }
    guard macdpi_tun_validate_packet_fd(packet) == 0 else {
        close(packet)
        return confirmRestoration(broker, then: .failed)
    }
    guard parentListening else {
        close(packet)
        return confirmRestoration(broker, then: .disabled)
    }
    var pair: [Int32] = [-1, -1]
    guard macdpi_tun_lease_pair(&pair) == 0, pair[0] >= 3, pair[1] >= 3 else {
        for fd in pair where fd >= 3 { close(fd) }
        close(packet)
        return confirmRestoration(broker, then: .failed)
    }
    let engineDone = DispatchGroup()
    let workerLease = pair[1]
    let controllerLease = pair[0]
    let workerPacket = packet
    let ipv4Index = Int32(ipv4), ipv6Index = Int32(ipv6)
    engineDone.enter()
    DispatchQueue(label: "io.github.latryee.MacDPI.tun-worker", qos: .userInitiated).async {
        defer { engineDone.leave() }
        var domains = options.domains
        domains.withUnsafeMutableBufferPointer { buffer in
            _ = macdpi_tun_run(workerPacket, workerLease, ipv4Index, ipv6Index, options.profile, options.splitOffset,
                               options.dnsOverHTTPS, options.originRepair, buffer.baseAddress, Int32(buffer.count))
        }
    }

    func stopEngine(_ outcome: Outcome, brokerOutcome: Outcome? = nil) -> Outcome {
        _ = macdpi_tun_control_send(controllerLease, stop)
        close(controllerLease)
        // The engine owns the packet fd. Wait for its return before telling
        // the broker to detach. If it hangs, process exit closes descriptors
        // and the broker independently sees EOF and rolls back.
        guard engineDone.wait(timeout: .now() + .seconds(5)) == .success else { return .recoveryRequired }
        return brokerOutcome ?? confirmRestoration(broker, then: outcome)
    }

    func stopForEvent(_ event: Event) -> Outcome {
        switch event {
        case .parentStop, .broker(stop): return stopEngine(.disabled)
        case .broker(done): return stopEngine(.disabled, brokerOutcome: .disabled)
        case .broker(failedAfterCleanup): return stopEngine(.failed, brokerOutcome: .failedClean)
        case .broker(nil), .broker(recovery): return stopEngine(.failed, brokerOutcome: .recoveryRequired)
        default: return stopEngine(.failed)
        }
    }

    let readyEvent = awaitEvent(broker: broker, engine: controllerLease, timeout: 12_000)
    guard case .engine(ready) = readyEvent else { return stopForEvent(readyEvent) }
    guard macdpi_tun_control_send(broker, ready) == 0 else { return stopEngine(.failed) }

    let activeEvent = awaitEvent(broker: broker, engine: controllerLease, timeout: 20_000)
    guard case .broker(active) = activeEvent else { return stopForEvent(activeEvent) }
    guard report("ACTIVE") else { return stopEngine(.disabled) }
    return stopForEvent(awaitEvent(broker: broker, engine: controllerLease, timeout: -1))
}

signal(SIGPIPE, SIG_IGN)
private let outcome = Options(arguments: CommandLine.arguments).map(run) ?? .failed
report(outcome.status)
exit(outcome.rawValue)
