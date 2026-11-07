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
    private var authorization: Process?
    private var authorizationError: String?
    private var input: Pipe?
    private var output: Pipe?
    private var pending = Data()
    private var statusVerified = false
    private var mayHaveRoutes = false
    private var wasActive = false
    private var completions: [(Bool) -> Void] = []
    private var stopTimeout: Task<Void, Never>?
    private let allowed: Bool
    private(set) var phase: PersonalTUNPhase = .disabled
    private(set) var detail = "Enable starts a local tunnel after macOS administrator authorization."
    var changed: (() -> Void)?

    init(allowed: Bool) { self.allowed = allowed }

    var resourceProcessIDs: [Int32] {
        guard phase == .active, let process, process.isRunning else { return [] }
        return [getpid(), process.processIdentifier]
    }

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
        let launcher: Process
        do {
            launcher = try PersonalTUNAuthorization.launcher(helper: helper, engine: engine, session: session)
        } catch {
            publish(.failed, "The app could not verify its signed tunnel components. Rebuild or replace this copy of MacDPI.")
            return
        }
        // Keep the numeric contract in IntegrationSupport/TUNWireBridge.h.
        let profile = configuration.profile == .compatibility ? 0 : configuration.profile == .advanced ? 2 : 1
        let child = Process(), commands = Pipe(), statuses = Pipe()
        let repair = configuration.tunTLSOriginRepair && profile != 0
        child.executableURL = engine
        child.arguments = [session, String(profile), String(configuration.splitOffset), configuration.dnsMode == .cloudflare ? "1" : "0",
                           configuration.dnsBypassDomains.joined(separator: "\n"), repair ? "1" : "0"]
        child.standardInput = commands
        child.standardOutput = statuses
        child.standardError = FileHandle.nullDevice
        process = child; input = commands; output = statuses
        pending.removeAll(keepingCapacity: true)
        statusVerified = false; mayHaveRoutes = false; wasActive = false; authorizationError = nil
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
            publish(.authorization, "Approve the MacDPI request in the macOS administrator dialog.")
            launchAuthorization(launcher)
        } catch {
            finish(.failed, "The TUN engine could not start.")
        }
    }

    func stop(completion: ((Bool) -> Void)? = nil) {
        guard process != nil else { completion?(phase != .recovery); return }
        if let completion { completions.append(completion) }
        guard phase != .stopping && phase != .restoring else { return }
        if !mayHaveRoutes, authorization?.isRunning == true { authorization?.terminate() }
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

    private func launchAuthorization(_ launcher: Process) {
        let result = Pipe()
        launcher.standardOutput = result
        authorization = launcher
        launcher.terminationHandler = { [weak self] task in
            DispatchQueue.main.async { [weak self] in
                let output = result.fileHandleForReading.readDataToEndOfFile()
                let cancelled = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "CANCELLED"
                self?.authorizationFinished(task, cancelled: cancelled)
            }
        }
        do {
            try launcher.run()
            try? result.fileHandleForWriting.close()
        } catch {
            authorizationFinished(launcher, cancelled: false)
        }
    }

    private func authorizationFinished(_ launcher: Process, cancelled: Bool) {
        guard authorization === launcher else { return }
        authorization = nil
        guard phase == .authorization else { return }
        if !cancelled {
            authorizationError = "macOS did not start the verified tunnel helper. Check administrator access and retry."
        }
        stop()
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
                mayHaveRoutes = true
                if phase != .stopping { publish(.configuring, "The engine is starting and the helper is checking routing.") }
            case "ACTIVE":
                mayHaveRoutes = true; wasActive = true
                if phase != .stopping { publish(.active, "The engine is running and the helper verified the installed TUN routes.") }
            case "RESTORING": publish(.restoring, "Waiting for macOS to detach the tunnel and release its routes.")
            case "DISABLED": statusVerified = true; publish(.disabled, "The helper verified that its interface and routes are gone.")
            case "CANCELLED":
                statusVerified = true
                if let authorizationError { publish(.failed, authorizationError) }
                else { publish(.disabled, "The authorization request was cancelled before routing started.") }
            case "AUTHORIZATION_TIMEOUT":
                statusVerified = true
                publish(.failed, "No authorized helper connected within 90 seconds. Press Enable and approve the new macOS dialog.")
            case "HELPER_CONNECTION_FAILED":
                statusVerified = true
                publish(.failed, "The traffic engine could not connect to the session helper. Retry the authorization request.")
            case "FAILED": statusVerified = !mayHaveRoutes; publish(.failed, "The traffic engine could not start. Review the selected DNS settings and retry.")
            case "FAILED_CLEAN":
                statusVerified = true
                let failure = wasActive ? "The active tunnel stopped." : "Tunnel setup did not complete."
                publish(.failed, failure + " Route cleanup was verified.")
            case "RECOVERY_REQUIRED": statusVerified = true; publish(.recovery, "Route cleanup could not be verified. Run the recovery check.")
            default: stop(); return
            }
        }
    }

    private func finish(_ phase: PersonalTUNPhase, _ detail: String) {
        output?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close(); try? input?.fileHandleForWriting.close()
        if !mayHaveRoutes, authorization?.isRunning == true { authorization?.terminate() }
        process = nil; input = nil; output = nil; authorization = nil; authorizationError = nil
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
