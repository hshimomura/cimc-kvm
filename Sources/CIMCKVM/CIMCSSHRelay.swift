import Network

@MainActor
final class CIMCSSHRelay {
    private let listener: NWListener
    private let target: NWEndpoint
    private let parameters: NWParameters
    private var local: NWConnection?
    private var upstream: NWConnection?
    private var failed = false
    private var ready = false

    init(host: String, proxy: ProxyConfiguration) throws {
        target = .hostPort(host: NWEndpoint.Host(host), port: 22)
        parameters = .tcp
        var configured = proxy
        configured.allowFailover = false
        let privacy = NWParameters.PrivacyContext(description: "CIMC CLI")
        privacy.proxyConfigurations = [configured]
        parameters.setPrivacyContext(privacy)
        let incoming = NWParameters.tcp
        incoming.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: incoming)
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .failed = state { self?.failed = true }
                if case .ready = state { self?.ready = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            DispatchQueue.main.async {
                guard let self, !self.failed, self.local == nil else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: .main)
        let deadline = ContinuousClock.now + .seconds(3)
        while !failed && ContinuousClock.now < deadline {
            if ready, let port = listener.port, port.rawValue > 0 { return port.rawValue }
            try await Task.sleep(for: .milliseconds(40))
        }
        stop()
        throw CIMCRecoveryError.unavailable
    }

    func stop() {
        failed = true
        listener.cancel()
        local?.cancel()
        upstream?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        local = connection
        let outgoing = NWConnection(to: target, using: parameters)
        upstream = outgoing
        for endpoint in [connection, outgoing] {
            endpoint.stateUpdateHandler = { [weak self] state in
                if case .failed = state { DispatchQueue.main.async { self?.stop() } }
            }
            endpoint.start(queue: .main)
        }
        forward(from: connection, to: outgoing)
        forward(from: outgoing, to: connection)
    }

    private func forward(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, eof, error in
            if error != nil {
                DispatchQueue.main.async { self?.stop() }
                return
            }
            destination.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage,
                             isComplete: eof, completion: .contentProcessed { [weak self] error in
                DispatchQueue.main.async {
                    if error != nil { self?.stop() }
                    else if !eof { self?.forward(from: source, to: destination) }
                }
            })
        }
    }
}
