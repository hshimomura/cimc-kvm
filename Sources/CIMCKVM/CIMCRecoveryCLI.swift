import Foundation
import Network

@MainActor
final class CIMCRecoveryCLI {
    private let address: String
    private let route: ConnectionRoute
    private let relay: CIMCSSHRelay?
    private let process = Process()
    private let input = Pipe()
    private let transcript = Pipe()
    private var output = Data()
    private var authenticated = false
    private var stopping = false

    init(address: String, route: ConnectionRoute, proxy: ProxyConfiguration?) throws {
        self.address = address
        self.route = route
        if case .socks = route {
            guard let proxy else { throw CIMCRecoveryError.unavailable }
            relay = try CIMCSSHRelay(host: address, proxy: proxy)
        } else {
            relay = nil
        }
    }

    nonisolated static func routeArguments(_ route: ConnectionRoute) -> [String] {
        guard case let .ssh(destination) = route else { return [] }
        let host = destination.replacingOccurrences(of: "'", with: "'\\''")
        let command = "/usr/bin/ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "
            + "-o ConnectTimeout=9 -o ControlPath=none -W '[%h]:%p' '\(host)'"
        return ["-o", "ProxyCommand=\(command)"]
    }

    func connect(username: String, password: String, verify: (String) -> Bool) async throws {
        guard !username.isEmpty, !password.isEmpty, !username.contains(where: \.isNewline),
              password.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CIMCRecoveryError.invalidCredentials
        }
        let port = try await relay?.start() ?? 22
        let endpoint = relay == nil ? address : "127.0.0.1"
        guard !stopping else { throw CancellationError() }
        let knownHosts = try Self.knownHostsPath()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", "/usr/bin/ssh", "-F", "/dev/null", "-tt",
            "-o", "HostKeyAlias=\(address)", "-o", "CheckHostIP=no", "-o", "StrictHostKeyChecking=ask",
            "-o", "UserKnownHostsFile=\(knownHosts) ~/.ssh/known_hosts",
            "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=9", "-o", "NumberOfPasswordPrompts=1",
            "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no",
            "-o", "EscapeChar=none", "-p", String(port), "-l", username
        ] + Self.routeArguments(route) + [endpoint]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["LC_ALL"] = "C"
        environment["TERM"] = "dumb"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = transcript
        process.standardError = transcript
        transcript.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.output.append(data)
            }
        }
        try process.run()

        let initial = try await waitFor {
            Self.requestsHostTrust($0) || Self.requestsPassword($0)
        }
        if Self.requestsHostTrust(initial) {
            guard let fingerprint = Self.fingerprint(in: initial), verify(fingerprint) else {
                throw CIMCRecoveryError.unverifiedKey
            }
            try send("yes")
            _ = try await waitFor(Self.requestsPassword)
        }
        try send(password)
        _ = try await waitFor { CIMCSessionTable.prompt(in: $0) == .global }
        authenticated = true
    }

    func list() async throws -> [CIMCUserSession] {
        try CIMCSessionTable.parse(await command("show user-session", expecting: .global))
    }

    func terminate(_ selected: CIMCUserSession) async throws -> [CIMCUserSession] {
        let id = try CIMCSessionTable.revalidate(selected, in: await list())
        _ = try await command("scope user-session \(id)", expecting: .session)
        let response = try await command("terminate", expecting: .session)
        _ = try await command("top", expecting: .global)
        let remaining = try await list()
        guard response.localizedCaseInsensitiveContains("User session \(id) terminated"),
              !remaining.contains(selected) else { throw CIMCRecoveryError.terminationRejected }
        return remaining
    }

    func disconnect() async {
        guard !stopping else { return }
        if authenticated && process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("top\nexit\n".utf8))
        }
        stopping = true
        transcript.fileHandleForReading.readabilityHandler = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        relay?.stop()
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        output.removeAll()
    }

    private func command(_ text: String, expecting prompt: CIMCSessionTable.Prompt) async throws -> String {
        guard authenticated else { throw CIMCRecoveryError.unavailable }
        try send(text)
        let response = try await waitFor { CIMCSessionTable.prompt(in: $0) != nil }
        guard CIMCSessionTable.prompt(in: response) == prompt else { throw CIMCRecoveryError.scopeRejected }
        return response
    }

    private func send(_ text: String) throws {
        guard !stopping, process.isRunning else { throw CIMCRecoveryError.unavailable }
        output.removeAll(keepingCapacity: true)
        try input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8))
    }

    private func waitFor(_ test: (String) -> Bool) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(14)
        while !stopping && ContinuousClock.now < deadline {
            let text = String(decoding: output, as: UTF8.self)
            if test(text) { return text }
            if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { throw CIMCRecoveryError.hostKeyChanged }
            if text.localizedCaseInsensitiveContains("Permission denied")
                || text.localizedCaseInsensitiveContains("maximum number of") {
                throw CIMCRecoveryError.authenticationFailed
            }
            guard process.isRunning else { throw CIMCRecoveryError.unavailable }
            try await Task.sleep(for: .milliseconds(40))
        }
        if stopping { throw CancellationError() }
        throw CIMCRecoveryError.timedOut
    }

    private static func requestsHostTrust(_ text: String) -> Bool {
        text.contains("Are you sure you want to continue connecting")
    }

    private static func fingerprint(in text: String) -> String? {
        text.range(of: #"SHA256:[A-Za-z0-9+/]+"#, options: .regularExpression).map { String(text[$0]) }
    }

    private static func requestsPassword(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix("password:")
    }

    private static func knownHostsPath() throws -> String {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = applicationSupport.appendingPathComponent("CIMCKVM", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = folder.appendingPathComponent("ssh_known_hosts").path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(path)\""
    }
}
