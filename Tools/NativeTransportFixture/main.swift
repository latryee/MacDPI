import Foundation
import Darwin

/// Isolated exercise of the actual provider adapters. No NE provider is registered and no
/// NEAppProxyFlow is created: the explicit nil flow uses only ordinary loopback sockets.
final class NativeTransportFixture {
    let queue = DispatchQueue(label: "io.macdpi.fixture.native")
    let done = DispatchGroup()
    private var timer: DispatchSourceTimer?
    private var stream: NativeOutboundStream?
    private var datagrams: DatagramTransport?
    private var finished = false
    private(set) var result: [String: Any] = [:]
    private let mode: String
    private let host: String
    private let port: UInt16
    private var sentBytes = 0
    private var received = Data()
    private var longestSend: Double = 0
    private var sendIndex = 0
    private var replyIndex = 0
    private var tcpWriteClosed = false
    private lazy var tcpPayload = Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let tcpTrailer = Data([0, 255, 17, 42, 0, 98, 121, 101])
    private let udpPayloads = [Data(), Data([0, 1, 2, 0, 255]), Data(), Data(repeating: 97, count: 4096),
                               Data(repeating: 123, count: 65_507), Data(), Data([9, 0])]

    init(mode: String, host: String, port: UInt16) {
        self.mode = mode; self.host = host; self.port = port
    }
    func run() -> Bool {
        done.enter()
        queue.async { [self] in
            let deadline = DispatchSource.makeTimerSource(queue: self.queue)
            self.timer = deadline
            deadline.setEventHandler { [weak self] in self?.finish("native fixture timed out") }
            deadline.schedule(deadline: .now() + 12); deadline.resume()
            if self.mode == "tcp" { self.startTCP() } else { self.startUDP() }
        }
        guard done.wait(timeout: .now() + 15) == .success else { return false }
        return result["passed"] as? Bool == true
    }
    private func startTCP() {
        let connection = NativeOutboundStream(host: host, port: port, flow: nil)
        stream = connection
        connection.start(queue: queue) { outcome in
            guard !self.finished else { return }
            switch outcome {
            case .failure(let error): self.finish("TCP start: \(error)")
            case .success: self.readTCP(); self.sendTCP()
            }
        }
    }
    private func sendTCP() {
        guard !finished, let stream else { return }
        if sentBytes == tcpPayload.count {
            stream.send(Data(), final: true) { error in
                guard !self.finished else { return }
                if let error { self.finish("TCP half-close: \(error)") }
                else { self.tcpWriteClosed = true }
            }
            return
        }
        let end = min(sentBytes + 65_536, tcpPayload.count)
        let data = tcpPayload.subdata(in: sentBytes..<end), began = DispatchTime.now().uptimeNanoseconds
        // Only the prior send's content-processed callback can schedule the next chunk.
        stream.send(data, final: false) { error in
            guard !self.finished else { return }
            if let error { self.finish("TCP send: \(error)"); return }
            self.longestSend = max(self.longestSend, Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9)
            self.sentBytes = end; self.sendIndex += 1; self.sendTCP()
        }
    }
    private func readTCP() {
        stream?.receive { data, eof, error in
            guard !self.finished else { return }
            if let error { self.finish("TCP receive: \(error)"); return }
            if let data { self.received.append(data) }
            guard self.received.count <= self.tcpPayload.count + self.tcpTrailer.count else { self.finish("TCP reply exceeded bound"); return }
            if eof {
                guard self.tcpWriteClosed, self.received == self.tcpPayload + self.tcpTrailer else {
                    self.finish("TCP byte integrity or half-close failed"); return
                }
                guard self.longestSend >= 0.05 else { self.finish("TCP delayed-reader backpressure was not observed"); return }
                self.finish(nil)
            } else { self.readTCP() }
        }
    }
    private func startUDP() {
        // This is the generic transparent provider's production UDP path. The public
        // Network.framework C bridge is used for TCP; its empty-UDP regression is documented.
        let index = if_nametoindex("lo0")
        guard index != 0 else { finish("Loopback interface is unavailable"); return }
        let connection = UDPTransport(endpoint: .init(host: host, port: port), interfaceIndex: index)
        datagrams = connection
        connection.start(queue: queue) { outcome in
            guard !self.finished else { return }
            switch outcome {
            case .failure(let error): self.finish("UDP start: \(error)")
            case .success: self.sendUDP()
            }
        }
    }
    private func sendUDP() {
        guard !finished, sendIndex < udpPayloads.count else { return }
        let data = udpPayloads[sendIndex]
        datagrams?.send(data) { error in
            guard !self.finished else { return }
            if let error { self.finish("UDP send \(self.sendIndex) (\(data.count) bytes): \(error)"); return }
            self.sentBytes += data.count; self.sendIndex += 1
            self.datagrams?.receive { bytes, complete, error in
                guard !self.finished else { return }
                if let error { self.finish("UDP receive \(self.replyIndex): \(error)"); return }
                let payload = bytes ?? Data()
                guard complete, payload == self.udpPayloads[self.replyIndex] else {
                    self.finish("UDP datagram \(self.replyIndex) boundary/integrity failed"); return
                }
                self.received.append(payload); self.replyIndex += 1
                if self.replyIndex == self.udpPayloads.count { self.finish(nil) }
                else { self.sendUDP() }
            }
        }
    }
    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        stream?.cancel(); datagrams?.cancel()
        result = ["passed": error == nil, "transport": mode, "host": host, "sentBytes": sentBytes,
                  "receivedBytes": received.count, "sends": sendIndex, "replies": replyIndex,
                  "longestSendSeconds": longestSend]
        if let error { result["error"] = error }
        done.leave()
    }
}

guard CommandLine.arguments.count == 4, ["tcp", "udp"].contains(CommandLine.arguments[1]),
      ["127.0.0.1", "::1"].contains(CommandLine.arguments[2]),
      let port = UInt16(CommandLine.arguments[3]), port != 0 else {
    fputs("Use: native-transport-fixture tcp|udp 127.0.0.1|::1 PORT\n", stderr); exit(2)
}
let fixture = NativeTransportFixture(mode: CommandLine.arguments[1], host: CommandLine.arguments[2], port: port)
let passed = fixture.run()
if let json = try? JSONSerialization.data(withJSONObject: fixture.result, options: [.sortedKeys]),
   let string = String(data: json, encoding: .utf8) { print(string) }
exit(passed ? 0 : 1)
