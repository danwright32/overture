import Foundation
import Network

// Binds an IPv4 loopback TCP listener on an OS-assigned port for the OAuth redirect
// catch. Two things have to be right or the live Gmail connect hangs (#51):
//   1. IPv4: Google redirects the browser to http://127.0.0.1; without forcing IPv4
//      NWListener can bind IPv6 and the redirect never arrives.
//   2. The real port is only valid once the listener reaches .ready. Reading it before
//      then returns 0, which produced redirect_uri=http://127.0.0.1:0, an address the
//      browser can't connect to, so the consent page never redirects back.
enum LoopbackListener {
    enum LoopbackError: LocalizedError {
        case noPort, failed(String), timedOut
        var errorDescription: String? {
            switch self {
            case .noPort: return "Local login listener never reported a port."
            case .failed(let m): return "Local login listener failed: \(m)"
            case .timedOut: return "Couldn't open the local login listener (timed out)."
            }
        }
    }

    /// How long the bind is given before Connect Gmail gives up (#54).
    ///
    /// Named rather than written inline so the shipped value has a reader. It is short on purpose: a
    /// PERSON is waiting on this, having just pressed Connect Gmail, and a wedged bind that is not
    /// refused leaves them looking at a control that did nothing (L110, L148). The tests deliberately do
    /// NOT run at this value, because under parallel testing a saturated machine can delay the readiness
    /// callback by tens of seconds and the test would then be measuring the machine rather than the
    /// listener (#3266, L290); they pass their own far larger ceiling and assert this one separately.
    static let defaultTimeout: TimeInterval = 10

    /// How many times the bind is attempted before the failure is the answer (#3409).
    ///
    /// A full parallel test run on 2026-08-31 failed three binds with
    /// `POSIXErrorCode(rawValue: 49): Can't assign requested address`, and the next run of the same tree
    /// passed all three. EADDRNOTAVAIL is not a port already taken (that is 48) and 127.0.0.1 does not
    /// stop being a local address, so what it reports is a bind refused at that instant.
    ///
    /// Both of the causes that suggested themselves were measured and ruled out: 400 concurrent binds
    /// with these exact parameters, and 400 more with `allowLocalEndpointReuse` off, all 800 reached
    /// `.ready` on this Mac. So the parameters are not it and neither is the count of listeners. A
    /// transient refusal is answered by another attempt, not by a different address.
    ///
    /// Small on purpose. The attempts share the caller's deadline rather than each getting their own, so
    /// this is a number of tries inside one wait, not a multiplier on how long a person waits.
    static let bindAttempts = 3

    /// How long to wait before trying again. Short, because the condition being waited out is momentary
    /// and the waiting comes out of the caller's own budget.
    static let bindRetryDelay: TimeInterval = 0.1

    /// Whether a bind failure is one that could plausibly clear on its own.
    ///
    /// Only these two. A permanent failure (no permission, no route) has to be reported at once: retrying
    /// it spends the person's whole timeout to arrive at the same answer more slowly (L110).
    ///
    /// Matched as a whole number rather than as a substring, or `rawValue: 490` would read as 49.
    static func isTransientBindFailure(_ message: String) -> Bool {
        [48, 49].contains { code in
            guard let range = message.range(of: "rawValue: \(code)") else { return false }
            let next = message[range.upperBound...].first
            return next == nil || !next!.isNumber
        }
    }

    /// What is left of the caller's wait, never negative: a negative budget handed to a sleep or a
    /// timeout reads as no limit at all, which is the one failure a deadline exists to prevent.
    static func remainingBudget(deadline: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, deadline - now)
    }

    static func start(
        queue: DispatchQueue,
        timeout: TimeInterval = LoopbackListener.defaultTimeout,
        log: (@Sendable (String) -> Void)? = nil,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        let deadline = Date().timeIntervalSince1970 + timeout
        var lastError: Error = LoopbackError.timedOut

        for attempt in 1...bindAttempts {
            let budget = remainingBudget(deadline: deadline, now: Date().timeIntervalSince1970)
            // Out of time is the caller's own answer, whatever the last attempt said: another attempt
            // here would be waiting past the moment the person was promised.
            guard budget > 0 else { break }
            do {
                return try await startOnce(queue: queue, timeout: budget, log: log, onConnection: onConnection)
            } catch let error as LoopbackError {
                guard case .failed(let message) = error,
                      isTransientBindFailure(message),
                      attempt < bindAttempts
                else { throw error }
                lastError = error
                // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
                log?("bind refused (\(message)); attempt \(attempt) of \(bindAttempts), trying again")
                // copy-inventory:ignore-end
                try? await Task.sleep(nanoseconds: UInt64(bindRetryDelay * 1_000_000_000))
            }
        }
        throw lastError
    }

    private static func startOnce(
        queue: DispatchQueue,
        timeout: TimeInterval,
        log: (@Sendable (String) -> Void)?,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to the IPv4 loopback only (#53): the OAuth redirect always comes from this
        // machine's browser to http://127.0.0.1, so there's no reason to accept connections
        // on any other interface. Pinning 127.0.0.1 also forces IPv4. The real port is read
        // after .ready below, so this no longer races to a 0 port (the #51 bug).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = onConnection

        return try await withCheckedThrowingContinuation { cont in
            let box = ContinuationBox(cont)
            // Give up if the listener never reaches .ready, so Connect Gmail can't hang on a
            // wedged bind (#54). The box resumes once, so whichever fires first wins.
            //
            // CRITICAL: the sleep MUST propagate cancellation. When .ready fires it calls
            // timeoutTask.cancel(); a `try?` there would SWALLOW the CancellationError and fall through to
            // listener.cancel(), tearing down the just-ready listener so the browser's redirect hits a dead
            // port ("Safari can't connect to 127.0.0.1"). The `catch { return }` leaves a live, ready
            // listener alone; only a genuine 10s timeout reaches cancel().
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                box.resume(throwing: LoopbackError.timedOut)
                listener.cancel()
            }
            listener.stateUpdateHandler = { state in
                // Logged so a listener that reports .ready and then quietly drops its socket (the bug
                // where the browser hits a dead port) is visible as a state transition after .ready.
                // copy-inventory:ignore-start  developer diagnostic log, not the app's voice (#915)
                log?("listener state: \(state)")
                // copy-inventory:ignore-end
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    if let port = listener.port?.rawValue, port != 0 {
                        box.resume(returning: (listener, port))
                    } else {
                        box.resume(throwing: LoopbackError.noPort)
                    }
                case .failed(let error):
                    timeoutTask.cancel()
                    // #3409: released here, because a failed attempt may be followed by another one and a
                    // listener left behind per attempt is a leak the retry would introduce.
                    listener.cancel()
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
