import Foundation
import Network
import NetworkExtension

/// Only the OS-supplied original DNS endpoint can be used by an intentional local/split-DNS exception.
/// A query body never supplies a relay destination and a failed DoH request never reaches this path.
final class DNSOriginalExchange {
    private let queue: DispatchQueue
    private let endpoint: DatagramEndpoint
    private let flow: NEAppProxyFlow
    private let tcp: Bool
    private var stream: NativeOutboundStream?
    private var datagram: NativeDatagramTransport?
    private var timer: DispatchSourceTimer?
    private var framer = DNSStreamFramer()
    private var completion: ((Result<Data, CoreError>) -> Void)?
    init(queue: DispatchQueue, endpoint: DatagramEndpoint, flow: NEAppProxyFlow, tcp: Bool) {
        self.queue = queue; self.endpoint = endpoint; self.flow = flow; self.tcp = tcp
    }
    func start(_ query: Data, completion: @escaping (Result<Data, CoreError>) -> Void) -> ResolutionTicket {
        let ticket = ResolutionTicket()
        let numeric = String(endpoint.host.split(separator: "%", maxSplits: 1).first ?? "")
        guard endpoint.port == 53, IPv4Address(numeric) != nil || IPv6Address(numeric) != nil,
              (try? DNSPacket(query, response: false)) != nil else { completion(.failure(.forbiddenDestination)); return ticket }
        self.completion = completion
        let source = DispatchSource.makeTimerSource(queue: queue); timer = source
        source.setEventHandler { [weak self] in self?.finish(.failure(.timedOut)) }; source.schedule(deadline: .now() + 6); source.resume()
        ticket.onCancel { self.queue.async { self.finish(.failure(.stopped)) } }
        if tcp {
            let channel = NativeOutboundStream(host: endpoint.host, port: endpoint.port, flow: flow); stream = channel
            channel.start(queue: queue) { [weak self] result in
                guard let self, self.completion != nil else { return }
                guard case .success = result, let frame = try? DNSStreamFramer.frame(query) else { self.finish(.failure(.connectionFailed)); return }
                channel.send(frame, final: false) { [weak self] error in
                    if error != nil { self?.finish(.failure(.connectionFailed)) } else { self?.readStream() }
                }
            }
        } else {
            let channel = NativeDatagramTransport(endpoint: endpoint, flow: flow); datagram = channel
            channel.start(queue: queue) { [weak self] result in
                guard let self, self.completion != nil else { return }
                guard case .success = result else { self.finish(.failure(.connectionFailed)); return }
                channel.send(query) { [weak self] error in
                    guard let self, self.completion != nil else { return }
                    guard error == nil else { self.finish(.failure(.connectionFailed)); return }
                    channel.receive { [weak self] data, complete, error in
                        guard let self, self.completion != nil else { return }
                        if error == nil, complete, let data, data.count <= DNSPacket.maximumSize { self.finish(.success(data)) }
                        else { self.finish(.failure(.resolutionFailed)) }
                    }
                }
            }
        }
        return ticket
    }
    private func readStream() {
        stream?.receive { [weak self] bytes, eof, error in
            guard let self, self.completion != nil else { return }
            guard error == nil else { self.finish(.failure(.connectionFailed)); return }
            do {
                try self.framer.append(bytes ?? Data())
                if let response = try self.framer.next() { self.finish(.success(response)) }
                else if eof { self.finish(.failure(.resolutionFailed)) }
                else { self.readStream() }
            } catch { self.finish(.failure(.invalidRequest)) }
        }
    }
    private func finish(_ result: Result<Data, CoreError>) {
        guard let callback = completion else { return }; completion = nil
        timer?.cancel(); timer = nil; stream?.cancel(); datagram?.cancel(); stream = nil; datagram = nil
        callback(result)
    }
    deinit { timer?.cancel(); stream?.cancel(); datagram?.cancel() }
}
