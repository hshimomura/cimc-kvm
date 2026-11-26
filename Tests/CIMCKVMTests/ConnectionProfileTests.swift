import XCTest
@testable import CIMCKVM

final class ConnectionProfileTests: XCTestCase {
    func testNewProfileDefaultsToDirectKVMWithStandardTLS() throws {
        let profile = try ConnectionProfile(address: "CIMC.lab.example", username: "operator")
        XCTAssertEqual(profile.loginURL.absoluteString, "https://cimc.lab.example/")
        XCTAssertEqual(profile.username, "operator")
        XCTAssertEqual(profile.route, .direct)
        XCTAssertFalse(profile.showManagement)
        XCTAssertFalse(profile.ignoreCertificateErrors)
        XCTAssertEqual(profile.certificatePolicy(host: "CIMC.LAB.EXAMPLE", port: 443), .system)
    }

    func testValidatesTargetsAndRoutesBeforeBuildingURLs() throws {
        let profile = try ConnectionProfile(
            address: "2001:0db8::1", username: "", route: .socks(address: "proxy.lab.example", port: 1080, username: ""))
        XCTAssertEqual(profile.loginURL.absoluteString, "https://[2001:db8::1]/")
        XCTAssertTrue(profile.allowsNavigation(to: try XCTUnwrap(URL(string: "https://[2001:db8::1]:2068/"))))

        for address in ["", "https://cimc.lab.example", "host:443", "10.0.0.999", "other@host", "host/path", "foo..bar"] {
            XCTAssertThrowsError(try ConnectionProfile(address: address, username: ""), address)
        }
        for route: ConnectionRoute in [
            .socks(address: "bad/path", port: 1080, username: ""),
            .socks(address: "proxy", port: 0, username: ""),
            .ssh(destination: "-V"),
            .ssh(destination: "one two"),
        ] {
            XCTAssertThrowsError(try ConnectionProfile(address: "cimc.example", username: "", route: route))
        }
    }

    func testNavigationAndCertificateExceptionStayOnSelectedCIMC() throws {
        let profile = try ConnectionProfile(address: "cimc.lab.example", username: "", ignoreCertificateErrors: true)
        for address in ["https://cimc.lab.example/", "https://cimc.lab.example:2068/", "about:blank"] {
            XCTAssertTrue(profile.allowsNavigation(to: try XCTUnwrap(URL(string: address))), address)
        }
        for address in [
            "http://cimc.lab.example/",
            "https://cimc.lab.example:8080/",
            "https://cimc.lab.example.other.invalid/",
            "https://cimc.lab.example@other.invalid/",
            "https://other@cimc.lab.example/",
        ] {
            XCTAssertFalse(profile.allowsNavigation(to: try XCTUnwrap(URL(string: address))), address)
        }
        XCTAssertEqual(profile.certificatePolicy(host: "cimc.lab.example", port: 443), .ignoreErrors)
        XCTAssertEqual(profile.certificatePolicy(host: "cimc.lab.example", port: 2068), .ignoreErrors)
        XCTAssertEqual(profile.certificatePolicy(host: "cimc.lab.example", port: 9443), .system)
        XCTAssertEqual(profile.certificatePolicy(host: "other.invalid", port: 443), .system)
    }

    func testIdentifiesManagementPageOnlyForTheSelectedHostHTTPSOrigin() throws {
        let profile = try ConnectionProfile(address: "cimc.example.com", username: "operator")
        let management = try XCTUnwrap(URL(string: "https://cimc.example.com/index.html#CIMC"))
        XCTAssertTrue(profile.isManagementPage(management))
        for address in [
            "https://cimc.example.com/login.html",
            "https://cimc.example.com/html/kvmViewer.html",
            "https://cimc.example.com:2068/index.html",
            "https://other.invalid/index.html",
        ] {
            XCTAssertFalse(profile.isManagementPage(try XCTUnwrap(URL(string: address))), address)
        }
    }

    func testSSHTunnelUsesVerifiedHostKeysAndBatchMode() throws {
        let target = "operator@jump.example.com"
        let profile = try ConnectionProfile(address: "cimc.example.com", username: "", route: .ssh(destination: target))
        XCTAssertEqual(profile.route, .ssh(destination: target))
        XCTAssertEqual(profile.certificatePolicy(host: profile.address, port: 443), .system)
        XCTAssertEqual(profile.certificatePolicy(host: profile.address, port: 2068), .system)

        let args = SSHTunnel.arguments(destination: target, port: 52345)
        XCTAssertEqual(args.last, target)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "-D")) + 1], "127.0.0.1:52345")
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
    }

    func testProfilesPersistOnlySettingsAndUsernames() throws {
        let suite = "jp.ioslab.cimc-kvm-poc.test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        XCTAssertEqual(try store.load(), [])

        let custom = try ConnectionProfile(
            address: "node.example",
            username: "operator",
            route: .socks(address: "proxy.example", port: 1081, username: "proxy-user"),
            ignoreCertificateErrors: true,
            showManagement: true
        )
        try store.save([custom])
        XCTAssertEqual(try store.load(), [custom])
        let stored = try XCTUnwrap(defaults.data(forKey: ProfileStore.key))
        let json = try XCTUnwrap(String(data: stored, encoding: .utf8))
        XCTAssertTrue(json.contains("proxy-user"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("password"))
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }
}
