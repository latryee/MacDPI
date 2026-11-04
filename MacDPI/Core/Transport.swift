import Foundation
import Network

/// Implementations deliver every callback on the owning session's serial queue.
public protocol ByteStream: AnyObject {
    func receive(_ completion: @escaping (Data?, Bool, Error?) -> Void)
    func send(_ data: Data, final: Bool, completion: @escaping (Error?) -> Void)
    func cancel()
}

public final class TCPStream: ByteStream {
    public static let maximumRead = 65_536
    public let connection: NWConnection
    public init(_ connection: NWConnection) { self.connection = connection }
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
