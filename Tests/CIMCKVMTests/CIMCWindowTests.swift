import AppKit
import XCTest
@testable import CIMCKVM

final class CIMCWindowTests: XCTestCase {
    func testWindowShortcutsUseCommandAlone() {
        XCTAssertEqual(CIMCWindow.shortcut(characters: "w", modifiers: .command), .close)
        XCTAssertEqual(CIMCWindow.shortcut(characters: "q", modifiers: [.command, .capsLock]), .quit)
        XCTAssertNil(CIMCWindow.shortcut(characters: "q", modifiers: .control))
        XCTAssertNil(CIMCWindow.shortcut(characters: "q", modifiers: []))
        XCTAssertNil(CIMCWindow.shortcut(characters: "w", modifiers: [.command, .shift]))
        XCTAssertNil(CIMCWindow.shortcut(characters: "x", modifiers: .command))
    }
}
