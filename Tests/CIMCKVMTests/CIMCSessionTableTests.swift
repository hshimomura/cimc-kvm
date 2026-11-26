import XCTest
@testable import CIMCKVM

final class CIMCSessionTableTests: XCTestCase {
    func testParsesActualSessionKindsAndProtectsRecoveryCLI() throws {
        let sessions = try CIMCSessionTable.parse("""
        C220-EXAMPLE# show user-session
        ID     Name             IP Address        Type         Killable
        ------ ---------------- ----------------- ------------ --------
        55     admin            10.0.0.66         vKVM         yes
        54     admin            10.0.0.66         webgui       yes
        53     service          2001:db8::1234    XML API      yes
        51     admin            10.0.0.66         CLI          no
        C220-EXAMPLE#
        """)
        XCTAssertEqual(sessions.map(\.id), [55, 54, 53, 51])
        XCTAssertEqual(sessions[2].kind, "XML API")
        XCTAssertEqual(sessions[2].source, "2001:db8::1234")
        XCTAssertThrowsError(try CIMCSessionTable.revalidate(sessions[3], in: sessions))
        XCTAssertEqual(try CIMCSessionTable.revalidate(sessions[1], in: sessions), 54)
    }

    func testEmptyAndInvalidResponsesAreDistinguished() throws {
        XCTAssertEqual(try CIMCSessionTable.parse("ID Name IP Address Type Killable\n--- ---\nexample# "), [])
        XCTAssertThrowsError(try CIMCSessionTable.parse("ERROR: user does not have permission\nexample# "))
        XCTAssertThrowsError(try CIMCSessionTable.parse("ID Name IP Address Type Killable\n55 bad row\nexample# "))
    }

    func testRevalidationRejectsDisappearedAndReusedSessionIDs() {
        let selected = CIMCUserSession(id: 9, user: "admin", source: "192.0.2.1", kind: "webgui", killable: true)
        let replacement = CIMCUserSession(id: 9, user: "operator", source: "192.0.2.2", kind: "webgui", killable: true)
        XCTAssertThrowsError(try CIMCSessionTable.revalidate(selected, in: []))
        XCTAssertThrowsError(try CIMCSessionTable.revalidate(selected, in: [replacement]))
    }

    func testDistinguishesScopePromptFromGlobalAndErrorResponses() {
        XCTAssertEqual(CIMCSessionTable.prompt(in: "show user-session\r\nC220-EXAMPLE# "), .global)
        XCTAssertEqual(CIMCSessionTable.prompt(in: "C220-EXAMPLE /user-session # "), .session)
        XCTAssertNil(CIMCSessionTable.prompt(in: "Enter password: "))
        XCTAssertNil(CIMCSessionTable.prompt(in: "C220-EXAMPLE /user # "))
    }
}
