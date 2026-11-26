import XCTest
@testable import CIMCKVM

final class SessionLogoutTests: XCTestCase {
    @MainActor
    func testClosingConnectionLogsOutKVMBeforeCIMC() async {
        var actions: [String] = []
        await SessionLogout.session.perform(
            viewer: { actions.append("KVM") },
            management: { actions.append("CIMC") }
        )
        XCTAssertEqual(actions, ["KVM", "CIMC"])
    }

    @MainActor
    func testClosingViewerInManagementModeKeepsCIMCSession() async {
        var actions: [String] = []
        await SessionLogout.viewer.perform(
            viewer: { actions.append("KVM") },
            management: { actions.append("CIMC") }
        )
        XCTAssertEqual(actions, ["KVM"])
    }
}
