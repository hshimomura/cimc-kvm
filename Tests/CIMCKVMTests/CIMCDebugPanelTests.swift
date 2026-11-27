import WebKit
import XCTest
@testable import CIMCKVM

final class CIMCDebugPanelTests: XCTestCase {
    @MainActor
    func testClosesOnlyTheDebugPanelWhenItAppearsInTheViewer() async throws {
        let webView = await loadPage(path: "/html/kvmViewer.html")
        let before = try await webView.evaluateJavaScript("window.closeCalls")
        XCTAssertEqual(before as? Int, 0)

        let closed = try await showPanel(in: webView)
        XCTAssertTrue(closed)
        let closeCalls = try await webView.evaluateJavaScript("window.closeCalls")
        XCTAssertEqual(closeCalls as? Int, 1)
    }

    @MainActor
    func testClosesManagementDebugPanelAndKeepsHardwareAlertsVisible() async throws {
        let webView = await loadPage(path: "/index.html")
        let closed = try await showPanel(in: webView)
        XCTAssertTrue(closed)

        let hardwareStatus = try await webView.evaluateJavaScript("""
            (() => {
                const status = document.getElementById('hardware-status');
                return status.getClientRects().length > 0 ? status.innerText : null;
            })()
            """)
        XCTAssertEqual(hardwareStatus as? String, "Power Supplies: Fault")
    }

    @MainActor
    func testLeavesLoginPageAlone() async throws {
        let webView = await loadPage(path: "/login.html")
        let closed = try await showPanel(in: webView)
        XCTAssertFalse(closed)
    }

    @MainActor
    private func loadPage(path: String) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(CIMCDebugPanel.script)
        configuration.setURLSchemeHandler(CIMCPageFixture(), forURLScheme: "fixture")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let finished = expectation(description: "Loaded fixture")
        let navigation = NavigationObserver(finished: finished)
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: URL(string: "fixture://cimc\(path)")!))
        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(navigation) {}
        return webView
    }

    @MainActor
    private func showPanel(in webView: WKWebView) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript("""
            showDebugPanel();
            await new Promise(resolve => setTimeout(resolve, 0));
            return document.getElementById('firebug').style.display === 'none';
            """, arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(result as? Bool)
    }
}

private final class NavigationObserver: NSObject, WKNavigationDelegate {
    let finished: XCTestExpectation

    init(finished: XCTestExpectation) {
        self.finished = finished
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished.fulfill()
    }
}

private final class CIMCPageFixture: NSObject, WKURLSchemeHandler {
    private static let html = """
        <!doctype html>
        <a title="Close the console" onclick="console.close(); return false;">Close</a>
        <p id="hardware-status">Power Supplies: Fault</p>
        <script>
            window.closeCalls = 0;
            console.close = () => {
                window.closeCalls++;
                const panel = document.getElementById('firebug');
                if (panel) panel.style.display = 'none';
            };
            function showDebugPanel() {
                document.body.insertAdjacentHTML('beforeend', `
                    <div class="firebug" id="firebug">
                        <div id="firebugToolbar">
                            <a title="Close the console" onclick="console.close(); return false;">Close</a>
                        </div>
                    </div>
                `);
            }
        </script>
        """

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let data = Data(Self.html.utf8)
        let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
