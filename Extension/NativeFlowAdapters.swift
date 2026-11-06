import Foundation
import Network
import NetworkExtension

final class FlowStream: ByteStream {
    let flow: NEAppProxyTCPFlow
    let queue: DispatchQueue
    private var closed = false
    init(flow: NEAppProxyTCPFlow, queue: DispatchQueue) { self.flow = flow; self.queue = queue }
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                guard (data?.count ?? 0) <= TCPStream.maximumRead else { completion(nil, false, CoreError.capacity); return }
                completion(data, data?.isEmpty ?? true, error)
            }
        }
    }
    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void) {
        guard !closed else { completion(CoreError.stopped); return }
        if data.isEmpty { if final { flow.closeWriteWithError(nil) }; completion(nil); return }
        flow.write(data) { [weak self] error in
            guard let self else { return }
            self.queue.async { guard !self.closed else { return }; if final { self.flow.closeWriteWithError(error) }; completion(error) }
        }
    }
    func cancel() { guard !closed else { return }; closed = true; flow.closeReadWithError(nil); flow.closeWriteWithError(nil) }
}

final class FlowDatagrams: DatagramFlow {
    let flow: NEAppProxyUDPFlow
    let queue: DispatchQueue
    private var closed = false
    init(flow: NEAppProxyUDPFlow, queue: DispatchQueue) { self.flow = flow; self.queue = queue }
    func receive(_ completion: @escaping (Result<[Datagram], CoreError>) -> Void) {
        flow.readDatagrams { [weak self] data, endpoints, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                guard error == nil else { completion(.failure(.connectionFailed)); return }
                let bytes = data ?? [], endpoints = endpoints ?? []
                guard bytes.count == endpoints.count, bytes.count <= 32,
                      bytes.reduce(0, { $0 + $1.count }) <= 262_144 else { completion(.failure(.capacity)); return }
                var datagrams = [Datagram]()
                for index in bytes.indices {
                    guard let endpoint = endpoints[index] as? NWHostEndpoint,
                          let port = UInt16(endpoint.port), port != 0 else { completion(.failure(.forbiddenDestination)); return }
                    datagrams.append(Datagram(data: bytes[index], endpoint: .init(host: endpoint.hostname, port: port)))
                }
                completion(.success(datagrams))
            }
        }
    }
    func send(_ datagram: Datagram, completion: @escaping (Error?) -> Void) {
        guard !closed else { completion(CoreError.stopped); return }
        flow.writeDatagrams([datagram.data], sentBy: [NWHostEndpoint(hostname: datagram.endpoint.host, port: String(datagram.endpoint.port))]) { [weak self] error in
            guard let self else { return }; self.queue.async { guard !self.closed else { return }; completion(error) }
        }
    }
    func cancel() { guard !closed else { return }; closed = true; flow.closeReadWithError(nil); flow.closeWriteWithError(nil) }
}

/// Public C Network.framework adapter carries the original flow's identity and interface even
/// where Swift's corresponding metadata convenience APIs are not available until macOS 15.
final class NativeOutboundStream: OutboundByteStream {
    private let connection: MDPINetworkConnection?
    init(host: String, port: UInt16, flow: NEAppProxyFlow? = nil) { connection = MDPINetworkConnection(host: host, port: port, datagram: false, flow: flow) }
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void) {
        guard let connection else { completion(.failure(.connectionFailed)); return }
        connection.start(queue: queue) { completion($0 == nil ? .success(()) : .failure(.connectionFailed)) }
    }
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) { connection?.receive(completion: completion) }
    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void) { connection?.send(data, final: final, completion: completion) }
    func cancel() { connection?.cancel() }
}

final class NativeDatagramTransport: DatagramTransport {
    private let connection: MDPINetworkConnection?
    init(endpoint: DatagramEndpoint, flow: NEAppProxyFlow? = nil) { connection = MDPINetworkConnection(host: endpoint.host, port: endpoint.port, datagram: true, flow: flow) }
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void) {
        guard let connection else { completion(.failure(.connectionFailed)); return }
        connection.start(queue: queue) { completion($0 == nil ? .success(()) : .failure(.connectionFailed)) }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) { connection?.send(data, final: false, completion: completion) }
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) { connection?.receive(completion: completion) }
    func cancel() { connection?.cancel() }
}
