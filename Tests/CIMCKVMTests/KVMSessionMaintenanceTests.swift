import Foundation
import XCTest
@testable import CIMCKVM

final class KVMSessionMaintenanceTests: XCTestCase {
    @MainActor
    func testRepeatedStartRetainsOnlyOneActivityAndStopReleasesIt() {
        var acquisitions = 0
        var released: [NSObjectProtocol] = []
        let token = NSObject()
        let maintenance = KVMSessionMaintenance(
            begin: { acquisitions += 1; return token },
            end: { released.append($0) }
        )

        maintenance.start(pulse: {})
        maintenance.start(pulse: {})
        XCTAssertEqual(acquisitions, 1)
        XCTAssertTrue(released.isEmpty)

        maintenance.stop()
        maintenance.stop()
        XCTAssertEqual(released.count, 1)
        XCTAssertTrue(released.first === token)

        maintenance.start(pulse: {})
        XCTAssertEqual(acquisitions, 2)
        maintenance.stop()
    }

    @MainActor
    func testCancellingStopsSubsequentPulses() async throws {
        let fired = expectation(description: "first pulse")
        let maintenance = KVMSessionMaintenance(interval: .milliseconds(80), begin: { NSObject() }, end: { _ in })
        var calls = 0
        maintenance.start {
            calls += 1
            if calls == 1 { fired.fulfill() }
        }
        await fulfillment(of: [fired], timeout: 1)
        maintenance.stop()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(calls, 1)
    }
}
