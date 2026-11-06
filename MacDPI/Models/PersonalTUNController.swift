import Darwin
import Foundation

enum PersonalTUNPhase: String {
    case disabled = "Disabled"
    case starting = "Starting"
    case authorization = "Awaiting authorization"
    case configuring = "Configuring network"
    case active = "Active"
    case stopping = "Stopping"
    case restoring = "Restoring network"
    case failed = "Failed"
    case recovery = "Recovery required"

    var busy: Bool { [.starting, .authorization, .configuring, .stopping, .restoring].contains(self) }
}

@MainActor
final class PersonalTUNController {
    static var bundled: Bool { Bundle.main.object(forInfoDictionaryKey: "MacDPIPersonalTUN") as? Bool == true }

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    private var statusVerified = false
    private var mayHaveRoutes = false
    private var completions: [(Bool) -> Void] = []
    private var stopTimeout: Task<Void, Never>?
    private let allowed: Bool
    private(set) var phase: PersonalTUNPhase = .disabled
    private(set) var detail = "Enable prepares a local tunnel session. Start the session helper in Terminal after reviewing the administrator command."
    private(set) var authorizationCommand: String?
    var changed: (() -> Void)?

    init(allowed: Bool) { self.allowed = allowed }

    private var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true) }
    var recoveryCommand: String? {
        guard allowed else { return nil }
        return "/usr/bin/sudo -- \(quoted(helpers.appendingPathComponent("MacDPITUNHelper").path)) recover"
    }

    func start(_ configuration: Configuration) {
        guard process == nil else { return }
        guard allowed, Self.bundled, getuid() != 0 else {
            publish(.failed, "Personal TUN requires the local personal-use build and a normal user account."); return
        }
        let engine = helpers.appendingPathComponent("MacDPITUNEngine")
        let helper = helpers.appendingPathComponent("MacDPITUNHelper")
        guard [engine, helper].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            publish(.failed, "This application bundle is missing its TUN components."); return
        }
        let session = UUID().uuidString.lowercased()
        // Keep the numeric contract in IntegrationSupport/TUNWireBridge.h.
        let profile = configuration.profile == .compatibility ? 0 : configuration.profile == .advanced ? 2 : 1
        let child = Process(), commands = Pipe(), statuses = Pipe()
        child.executableURL = engine
        child.arguments = [session, String(profile), String(configuration.splitOffset), configuration.dnsMode == .cloudflare ? "1" : "0",
                           configuration.dnsBypassDomains.joined(separator: "\n")]
        child.standardInput = commands
        child.standardOutput = statuses
        child.standardError = FileHandle.nullDevice
        process = child; input = commands; output = statuses
        pending.removeAll(keepingCapacity: true)
        statusVerified = false; mayHaveRoutes = false
        publish(.starting, "Starting the unprivileged traffic engine.")
        // A single serial reader preserves status ordering through EOF. The child reports only
        // bounded fixed vocabulary and closes this pipe on every exit.
        statuses.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.consume(bytes, from: child) }
        }
        do {
            try child.run()
            try? statuses.fileHandleForWriting.close()
            try? commands.fileHandleForReading.close()
            authorizationCommand = "/usr/bin/sudo -- \(quoted(helper.path)) run \(session)"
            publish(.authorization, "Run the session command in Terminal within 90 seconds. macOS handles the administrator password.")
        } catch {
            finish(.failed, "The TUN engine could not start.")
        }
    }

    func stop(completion: ((Bool) -> Void)? = nil) {
        guard process != nil else { completion?(phase != .recovery); return }
        if let completion { completions.append(completion) }
        guard phase != .stopping && phase != .restoring else { return }
        authorizationCommand = nil
        publish(.stopping, "Closing TCP and UDP sessions.")
        // EOF is the authenticated stop signal. It also handles a UI process crash.
        try? input?.fileHandleForWriting.close()
        stopTimeout?.cancel()
        stopTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 28_000_000_000)
            guard !Task.isCancelled, let self, self.process != nil else { return }
            self.process?.terminate()
            self.finish(.recovery, "No cleanup acknowledgement arrived. Run the recovery check before enabling again.")
        }
    }

    private func consume(_ bytes: Data, from child: Process) {
        guard process === child else { return }
        if bytes.isEmpty {
            if !statusVerified {
                finish(mayHaveRoutes ? .recovery : .failed, mayHaveRoutes
                    ? "The engine disconnected before route cleanup was verified. Run the recovery check."
                    : "The engine exited before the tunnel was ready.")
            } else { finish(phase, detail) }
            return
        }
        guard pending.count + bytes.count <= 4096 else {
            stop(); return
        }
        pending.append(bytes)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending.prefix(upTo: end), as: UTF8.self)
            pending.removeSubrange(...end)
            switch line {
            case "CONFIGURING":
                mayHaveRoutes = true; authorizationCommand = nil
                if phase != .stopping { publish(.configuring, "The engine is starting and the helper is checking routing.") }
            case "ACTIVE":
                mayHaveRoutes = true; authorizationCommand = nil
                if phase != .stopping { publish(.active, "The engine is running and the helper verified the installed TUN routes.") }
            case "RESTORING": publish(.restoring, "Waiting for macOS to detach the tunnel and release its routes.")
            case "DISABLED": statusVerified = true; publish(.disabled, "The helper verified that its interface and routes are gone.")
            case "CANCELLED": statusVerified = true; publish(.disabled, "The authorization request was cancelled before routing started.")
            case "FAILED": statusVerified = !mayHaveRoutes; publish(.failed, "The tunnel could not start or the network changed.")
            case "FAILED_CLEAN": statusVerified = true; publish(.failed, "The tunnel could not continue. The helper verified that its routes are gone.")
            case "RECOVERY_REQUIRED": statusVerified = true; publish(.recovery, "Route cleanup could not be verified. Run the recovery check.")
            default: stop(); return
            }
        }
    }

    private func finish(_ phase: PersonalTUNPhase, _ detail: String) {
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close(); try? input?.fileHandleForWriting.close()
        process = nil; input = nil; output = nil; authorizationCommand = nil
        stopTimeout?.cancel(); stopTimeout = nil
        let callbacks = completions
        completions.removeAll()
        publish(phase, detail)
        callbacks.forEach { $0(phase != .recovery) }
    }

    private func publish(_ phase: PersonalTUNPhase, _ detail: String) {
        self.phase = phase; self.detail = detail; changed?()
    }

    private func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
