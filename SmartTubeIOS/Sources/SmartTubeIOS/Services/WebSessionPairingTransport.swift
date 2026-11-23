import Foundation
import Network
import Observation
import SmartTubeIOSCore
import os

private let pairingLog = Logger(subsystem: appSubsystem, category: "WebSessionPairing")

/// Largest payload the TV accepts: a web session is a few dozen cookies (~10 KB sealed).
private let maximumPayloadSize = 256 * 1024

// MARK: - Receiver (Apple TV)

/// Listens on the local network for one web session sent from a phone (see `WebSessionPairing`)
/// and adopts it. Stops after the first transfer, successful or not.
@MainActor
@Observable
final class WebSessionPairingReceiver {

    enum State: Equatable {
        case starting
        case waiting(WebSessionPairing.Invitation)
        case received
        case failed(String)
    }

    private(set) var state: State = .starting
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var payload = Data()

    /// Starts listening; `adopt` gets the decrypted session cookies.
    func start(adopt: @escaping @MainActor ([HTTPCookie]) async -> Bool) {
        stop()
        guard let host = Self.localIPv4Address() else {
            state = .failed("This Apple TV has no local network address.")
            return
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            state = .failed("Couldn't open a port: \(error.localizedDescription)")
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.listenerChanged(newState, host: host) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection, adopt: adopt) }
        }
        // NWListener requires a dispatch queue; handlers hop to the main actor.
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listenerChanged(_ newState: NWListener.State, host: String) {
        switch newState {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            state = .waiting(.make(host: host, port: port))
            pairingLog.notice("listening on port \(port)")
        case .failed(let error):
            state = .failed("Listening failed: \(error.localizedDescription)")
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection, adopt: @escaping @MainActor ([HTTPCookie]) async -> Bool) {
        guard case .waiting(let invitation) = state else {
            connection.cancel()
            return
        }
        payload = Data()
        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, invitation: invitation, adopt: adopt)
    }

    private func receive(
        on connection: NWConnection, invitation: WebSessionPairing.Invitation,
        adopt: @escaping @MainActor ([HTTPCookie]) async -> Bool
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.payload.append(data) }
                if self.payload.count > maximumPayloadSize || error != nil {
                    connection.cancel()
                    return
                }
                guard isComplete else {
                    self.receive(on: connection, invitation: invitation, adopt: adopt)
                    return
                }
                connection.cancel()
                await self.finish(invitation: invitation, adopt: adopt)
            }
        }
    }

    private func finish(invitation: WebSessionPairing.Invitation, adopt: @MainActor ([HTTPCookie]) async -> Bool) async {
        defer { stop() }
        guard let cookies = try? WebSessionPairing.open(payload, for: invitation) else {
            state = .failed("The received sign-in couldn't be read. Scan the code again.")
            return
        }
        state = await adopt(cookies) ? .received : .failed("The received sign-in has no YouTube session.")
        pairingLog.notice("received \(cookies.count) cookies")
    }

    /// The first IPv4 address of an active Wi-Fi or Ethernet interface.
    static func localIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                String(cString: entry.ifa_name).hasPrefix("en")
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
            else { continue }
            guard let text = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            else { continue }
            if WebSessionPairing.isLocalNetworkHost(text) { return text }
        }
        return nil
    }
}

// MARK: - Sender (iPhone, iPad, Mac)

public enum WebSessionPairingSender {

    public enum SendError: Error {
        case noSession
        case connection(String)
    }

    /// Sends this device's web session to the TV behind `invitation`.
    public static func send(to invitation: WebSessionPairing.Invitation) async throws {
        let cookies = WebSession.sessionCookies(HTTPCookieStorage.shared.cookies ?? [])
        guard WebSession.sapisid(in: cookies) != nil else { throw SendError.noSession }
        let payload = try WebSessionPairing.seal(cookies, for: invitation)
        guard let port = NWEndpoint.Port(rawValue: invitation.port) else { throw SendError.connection("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(invitation.host), port: port, using: .tcp)
        defer { connection.cancel() }
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            connection.cancel()
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceGuard()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: payload, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
                            guard once.claim() else { return }
                            if let error {
                                continuation.resume(throwing: SendError.connection(error.localizedDescription))
                            } else {
                                continuation.resume()
                            }
                        })
                case .failed(let error):
                    guard once.claim() else { return }
                    continuation.resume(throwing: SendError.connection(error.localizedDescription))
                case .cancelled:
                    guard once.claim() else { return }
                    continuation.resume(throwing: SendError.connection("The Apple TV didn't answer."))
                default:
                    // .waiting covers the local network permission prompt; the timeout ends it.
                    break
                }
            }
            // NWConnection requires a dispatch queue.
            connection.start(queue: .global(qos: .userInitiated))
        }
        pairingLog.notice("sent \(cookies.count) cookies")
    }

    /// Lets exactly one of several callbacks resume a continuation.
    private final class OnceGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
