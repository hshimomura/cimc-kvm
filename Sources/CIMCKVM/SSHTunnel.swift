import Darwin
import Foundation

@MainActor
final class SSHTunnel {
    private let process = Process()
    private let output = Pipe()
    let port: UInt16
    nonisolated private static let readinessMarker = "CIMC_KVM_SOCKS_READY"

    init(destination: String) throws {
        port = try Self.availableLoopbackPort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(destination: destination, port: port)
        process.standardOutput = output
    }

    nonisolated static func arguments(destination: String, port: UInt16) -> [String] {
        [
            "-nNT", "-D", "127.0.0.1:\(port)",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "PermitLocalCommand=yes",
            "-o", "LocalCommand=/bin/echo \(readinessMarker)",
            destination,
        ]
    }

    func start(ready: @escaping @MainActor () -> Void, stopped: @escaping @MainActor () -> Void) throws {
        let reading = output.fileHandleForReading
        process.terminationHandler = { _ in
            Task { @MainActor in stopped() }
        }
        try process.run()
        // ssh writes one newline-terminated readiness marker after establishing forwarding.
        DispatchQueue.global(qos: .userInitiated).async {
            let expected = Data((Self.readinessMarker + "\n").utf8)
            guard let signal = try? reading.read(upToCount: expected.count), signal == expected else { return }
            Task { @MainActor in ready() }
        }
    }

    func stop() {
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { close(descriptor) }

        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout.size(ofValue: address))
        address.sin_len = UInt8(length)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                guard bind(descriptor, socketAddress, length) == 0 else { return Int32(-1) }
                return getsockname(descriptor, socketAddress, &length)
            }
        }
        guard status == 0 else { throw currentPOSIXError() }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
