import Foundation
import Network

/// Implementations deliver every callback on the owning session's serial queue.
public protocol ByteStream: AnyObject {
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void)
    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void)
    func cancel()
}

public protocol OutboundByteStream: ByteStream {
    func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void)
}

public final class TCPStream: OutboundByteStream {
    public static let maximumRead = 65_536
    public let connection: NWConnection
    public init(_ connection: NWConnection) { self.connection = connection }
    public func start(queue: DispatchQueue, completion: @escaping (Result<Void, CoreError>) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.connection.stateUpdateHandler = nil; completion(.success(()))
            case .failed, .waiting: self.connection.stateUpdateHandler = nil; completion(.failure(.connectionFailed))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    public func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRead) { data, _, eof, error in completion(data, eof, error) }
    }
    public func send(_ data: Data, final: Bool = false, completion: @escaping (Error?) -> Void) {
        connection.send(content: data.isEmpty ? nil : data, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { completion($0) })
    }
    public func cancel() { connection.stateUpdateHandler = nil; connection.cancel() }
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true; tcp.enableKeepalive = true
        return NWParameters(tls: nil, tcp: tcp)
    }
}
