import XCTest
@testable import CIMCKVM

final class CIMCRecoveryCLITests: XCTestCase {
    func testJumpProfileForwardsOnlyThroughConfiguredSshHost() {
        let route = ConnectionRoute.ssh(destination: "operator@jump.example.com")
        let arguments = CIMCRecoveryCLI.routeArguments(route)
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(arguments.first, "-o")
        XCTAssertTrue(arguments[1].hasPrefix("ProxyCommand=/usr/bin/ssh "))
        XCTAssertTrue(arguments[1].contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments[1].contains("-W '[%h]:%p' 'operator@jump.example.com'"))
        XCTAssertEqual(CIMCRecoveryCLI.routeArguments(.direct), [])
    }
}
