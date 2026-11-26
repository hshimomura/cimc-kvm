import JavaScriptCore
import XCTest
@testable import CIMCKVM

final class CIMCLoginLimitTests: XCTestCase {
    func testLoginLimitOpensRecoveryOnceWhenDisplayed() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        let notices = 0;
        let observer;
        let active = false;
        class MutationObserver {
            constructor(callback) { observer = callback; }
            observe() { active = true; }
            disconnect() { active = false; }
        }
        const location = { pathname: "/login.html" };
        const document = { body: { innerText: "Login failed." }, documentElement: {} };
        const window = {webkit: {messageHandlers: {cimcLoginLimit: { postMessage: () => notices++ }}}};
        """)
        context.evaluateScript(CIMCLoginLimit.source)
        XCTAssertEqual(context.evaluateScript("notices").toInt32(), 0)
        context.evaluateScript("""
        document.body.innerText = "The maximum number of user sessions has been reached.";
        if (active) observer();
        if (active) observer();
        """)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("notices").toInt32(), 1)
    }
}
