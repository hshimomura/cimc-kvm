import Darwin
import Foundation

enum ConnectionRoute: Codable, Equatable {
    case direct
    case socks(address: String, port: UInt16, username: String)
    case ssh(destination: String)

    var description: String {
        switch self {
        case .direct: return "直接接続"
        case let .socks(address, port, _): return "SOCKS5 · \(address):\(port)"
        case let .ssh(destination): return "SSH踏み台 · \(destination)"
        }
    }

    fileprivate func validated() throws -> Self {
        switch self {
        case .direct:
            return self
        case let .socks(address, port, username):
            guard let host = ConnectionProfile.canonicalHost(address), port > 0 else {
                throw ProfileError.invalidProxy
            }
            return .socks(address: host, port: port, username: username.trimmingCharacters(in: .whitespacesAndNewlines))
        case let .ssh(destination):
            let target = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = target.split(separator: "@", omittingEmptySubsequences: false)
            guard !target.hasPrefix("-"), (1...2).contains(parts.count),
                  parts.allSatisfy({ !$0.isEmpty }),
                  target.range(of: #"^[a-zA-Z0-9_.@:\[\]-]+$"#, options: .regularExpression) != nil else {
                throw ProfileError.invalidSSH
            }
            return .ssh(destination: target)
        }
    }

}

enum CertificatePolicy: Equatable {
    case system
    case ignoreErrors
}

enum ProfileError: LocalizedError {
    case invalidHost
    case invalidProxy
    case invalidSSH

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "接続先にIPアドレスまたはFQDNを入力してください。"
        case .invalidProxy: return "SOCKS5のホスト名とポート（1〜65535）を確認してください。"
        case .invalidSSH: return "SSH設定のホスト名または user@host を入力してください。"
        }
    }
}

struct ConnectionProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let address: String
    let username: String
    let route: ConnectionRoute
    let ignoreCertificateErrors: Bool
    let showManagement: Bool

    init(id: UUID = UUID(), address: String, username: String, route: ConnectionRoute = .direct,
         ignoreCertificateErrors: Bool = false, showManagement: Bool = false) throws {
        guard let host = Self.canonicalHost(address) else { throw ProfileError.invalidHost }
        self.id = id
        self.address = host
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.route = try route.validated()
        self.ignoreCertificateErrors = ignoreCertificateErrors
        self.showManagement = showManagement
    }

    var loginURL: URL {
        let urlHost = address.contains(":") ? "[\(address)]" : address
        return URL(string: "https://\(urlHost)/")!
    }

    func allowsNavigation(to url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        return url.scheme == "https" && url.user == nil && url.password == nil
            && matches(host: url.host(percentEncoded: false) ?? "", port: url.port ?? 443)
    }

    func isLoginPage(_ url: URL) -> Bool {
        allowsNavigation(to: url) && (url.port ?? 443) == 443 && url.path == "/login.html"
    }

    func isManagementPage(_ url: URL) -> Bool {
        allowsNavigation(to: url) && (url.port ?? 443) == 443 && url.path == "/index.html"
    }

    func certificatePolicy(host: String, port: Int) -> CertificatePolicy {
        if ignoreCertificateErrors && matches(host: host, port: port) { return .ignoreErrors }
        return .system
    }

    func validated() throws -> Self {
        try Self(id: id, address: address, username: username, route: route,
                 ignoreCertificateErrors: ignoreCertificateErrors, showManagement: showManagement)
    }

    private func matches(host: String, port: Int) -> Bool {
        (port == 443 || port == 2068) && Self.canonicalHost(host) == address
    }

    fileprivate static func canonicalHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard host.contains(":") else { return nil }
        }
        if host.contains(":") {
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, host, &bytes) == 1 else { return nil }
            var canonical = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &bytes, &canonical, socklen_t(canonical.count)) != nil else { return nil }
            return String(cString: canonical)
        }

        if host.hasSuffix(".") { host.removeLast() }
        if !host.isEmpty && host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) {
            var bytes = in_addr()
            return inet_pton(AF_INET, host, &bytes) == 1 ? host : nil
        }
        guard (1...253).contains(host.utf8.count) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return host
    }
}

struct ProfileStore {
    static let key = "registeredCIMCHosts"
    let defaults: UserDefaults

    func load() throws -> [ConnectionProfile] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return try JSONDecoder().decode([ConnectionProfile].self, from: data).map { try $0.validated() }
    }

    func save(_ profiles: [ConnectionProfile]) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.key)
    }
}
