import Foundation
import Network

// Binds an IPv4 loopback TCP listener on an OS-assigned port for the OAuth redirect
// catch. Two things have to be right or the live Gmail connect hangs (#51):
//   1. IPv4: Google redirects the browser to http://127.0.0.1; without forcing IPv4
//      NWListener can bind IPv6 and the redirect never arrives.
//   2. The real port is only valid once the listener reaches .ready. Reading it before
//      then returns 0, which produced redirect_uri=http://127.0.0.1:0 — an address the
//      browser can't connect to, so the consent page never redirects back.
enum LoopbackListener {
    enum LoopbackError: LocalizedError {
        case noPort, failed(String)
        var errorDescription: String? {
            switch self {
            case .noPort: return "Local login listener never reported a port."
            case .failed(let m): return "Local login listener failed: \(m)"
            }
        }
    }

    static func start(
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = onConnection

        return try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, port != 0 {
                        box.resume(returning: (listener, port))
                    } else {
                        box.resume(throwing: LoopbackError.noPort)
                    }
                case .failed(let error):
                    box.resume(throwing: LoopbackError.failed("\(error)"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

// One-shot resume guard: the listener's state handler can fire more than once, but a
// CheckedContinuation must resume exactly once (it traps otherwise).
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    func resume(returning value: sending T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}
