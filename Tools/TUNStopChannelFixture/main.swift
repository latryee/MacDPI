import Darwin
import Dispatch
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func pollStop(_ descriptor: Int32, timeout: Int32) -> (Int32, Int16) {
    let deadline = DispatchTime.now() + .milliseconds(Int(timeout))
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = deadline.uptimeNanoseconds > now ? deadline.uptimeNanoseconds - now : 0
        var fd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&fd, 1, Int32((remaining + 999_999) / 1_000_000))
        if result < 0 && errno == EINTR { continue }
        return (result, fd.revents)
    }
}

private func verifyInitializationAndLifetime() {
    let descriptors = Set((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 })
    let invalidParent = Int32((3..<256).first { !descriptors.contains($0) }!)
    require(TUNStopChannel(parentDescriptor: invalidParent) == nil,
            "a closed positive parent descriptor must fail initialization")
    require(TUNStopChannel(parentDescriptor: -1) == nil, "negative parent descriptor must fail initialization")
    let remaining = Set((0..<256).filter { fcntl(Int32($0), F_GETFD) >= 0 })
    require(remaining == descriptors, "failed initialization must not change descriptor ownership")

    var parent: [Int32] = [-1, -1]
    require(pipe(&parent) == 0, "create isolated parent pipe")
    defer { close(parent[0]); close(parent[1]) }
    var channel = TUNStopChannel(parentDescriptor: parent[0])
    require(channel != nil, "initialize isolated channel")
    let reader = channel!.readDescriptor
    channel = nil
    require(fcntl(reader, F_GETFD) == -1 && errno == EBADF, "weak source handlers must allow deinitialization")
    require(fcntl(parent[0], F_GETFD) >= 0 && fcntl(parent[1], F_GETFD) >= 0,
            "channel must retain caller ownership of the parent pipe")

    // A deliberately closed standard descriptor must not become a stop pipe.
    require(close(STDIN_FILENO) == 0, "close only this fixture's standard input")
    require(TUNStopChannel(parentDescriptor: parent[0]) == nil,
            "stop endpoints below descriptor three must fail initialization")
    require(fcntl(STDIN_FILENO, F_GETFD) == -1 && errno == EBADF,
            "failed setup must not retain an endpoint as standard input")
}

require(getuid() != 0 && geteuid() == getuid(), "run the fixture as a normal user")
require(CommandLine.arguments.count == 2, "expected one fixture mode")
let mode = CommandLine.arguments[1]
if mode == "lifetime" {
    verifyInitializationAndLifetime()
    print("PASS lifetime")
    exit(0)
}
require(["poll-stop", "poll-idle", "broker-cancel", "broker-timeout"].contains(mode), "unknown fixture mode")
guard let channel = TUNStopChannel() else {
    fputs("FAIL: stop channel setup, errno=\(errno)\n", stderr)
    exit(1)
}
require(fcntl(channel.readDescriptor, F_GETFD) & FD_CLOEXEC != 0, "stop reader must close on exec")
require(!channel.isRequested, "channel should start unrequested")

let session = UUID().uuidString.lowercased()
print("READY \(session)")
fflush(stdout)
let started = DispatchTime.now().uptimeNanoseconds
switch mode {
case "poll-stop":
    let (result, events) = pollStop(channel.readDescriptor, timeout: 4_000)
    require(result == 1 && events == Int16(POLLIN), "stop must wake poll with readable data")
    require(channel.isRequested, "readiness must publish the requested latch")
    // Production consumers leave this byte unread. Drain it only to prove that
    // a signal burst and a still-readable parent cannot append another byte.
    var bytes = [UInt8](repeating: 0, count: 8)
    require(read(channel.readDescriptor, &bytes, bytes.count) == 1 && bytes[0] == 1,
            "stop must write exactly one byte")
    let (again, _) = pollStop(channel.readDescriptor, timeout: 150)
    require(again == 0 && channel.isRequested, "stop must remain one latched request")
case "poll-idle":
    let (result, events) = pollStop(channel.readDescriptor, timeout: 250)
    require(result == 0 && events == 0 && !channel.isRequested, "idle parent must not request stop")
case "broker-cancel", "broker-timeout":
    // The random UUID has no broker. This invokes the real normal-user connect
    // retry loop, without making a listener, a TUN interface, or a route change.
    let result = session.withCString {
        macdpi_tun_broker_connect($0, channel.readDescriptor, mode == "broker-timeout" ? 250 : 4_000)
    }
    let error = errno
    require(result == -1, "absent broker must not connect")
    if mode == "broker-timeout" {
        require(error == ETIMEDOUT && !channel.isRequested, "uncancelled connect must time out")
    } else {
        require(error == ECANCELED && channel.isRequested, "stop FD must cancel real broker connect")
    }
default:
    fatalError("validated mode")
}
let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
print("PASS \(mode) \(elapsed)ms")
withExtendedLifetime(channel) {}
