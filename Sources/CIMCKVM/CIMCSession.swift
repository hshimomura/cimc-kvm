import AppKit
import Network
import OSLog
import WebKit

@MainActor
final class CIMCSession: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let profile: ConnectionProfile
    private let onClose: () -> Void
    private let maintenance = KVMSessionMaintenance()
    private var maintainsKVM: Bool
    private let maintenanceLog = Logger(subsystem: "jp.ioslab.cimc-kvm-poc", category: "SessionMaintenance")
    private var tunnel: SSHTunnel?
    private var windows: Set<NSWindow> = []
    private weak var managementView: WKWebView?
    private weak var viewerView: WKWebView?
    private var recovery: SessionRecoveryWindow?
    private var viewerExited = false
    private var viewerClose: Task<Void, Never>?
    private var sessionClose: Task<Void, Never>?
    private var attemptingLaunch = false
    private weak var progressCover: NSView?
    private var closing = false

    init(profile: ConnectionProfile, maintainsKVM: Bool, onClose: @escaping () -> Void) {
        self.profile = profile
        self.maintainsKVM = maintainsKVM
        self.onClose = onClose
    }

    func start(proxyPassword: String?) {
        do {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            configuration.userContentController.add(
                CIMCLoginLimitObserver(session: self), contentWorld: .defaultClient, name: CIMCLoginLimitObserver.name
            )
            configuration.userContentController.addUserScript(CIMCLoginLimitObserver.script)
            configuration.userContentController.addUserScript(CIMCDebugPanel.script)

            switch profile.route {
            case .direct:
                break
            case let .socks(address, port, username):
                let credentials = proxyPassword.map { (username: username, password: $0) }
                configureProxy(in: configuration, host: address, port: port, credentials: credentials)
            case let .ssh(destination):
                let tunnel = try SSHTunnel(destination: destination)
                self.tunnel = tunnel
                configureProxy(in: configuration, host: "127.0.0.1", port: tunnel.port)
            }

            let webView = openWindow(title: "\(profile.address) CIMC", configuration: configuration)
            managementView = webView
            let request = URLRequest(url: profile.loginURL)
            if let tunnel {
                try tunnel.start(ready: { [weak self, weak webView] in
                    guard let self, !self.closing else { return }
                    webView?.load(request)
                }, stopped: { [weak self] in
                    guard let self, !self.closing else { return }
                    self.showError("SSH 接続が終了しました。踏み台、ホスト鍵、SSH 鍵を確認してください。\n"
                        + "パスワード認証の場合は、ターミナルで SSH の SOCKS5 転送を開始し、接続経路に SOCKS5 を選択してください。")
                    self.dispose()
                })
            } else {
                webView.load(request)
            }
        } catch {
            showError(error.localizedDescription)
            dispose()
        }
    }

    private func configureProxy(in configuration: WKWebViewConfiguration, host: String, port: UInt16,
                                credentials: (username: String, password: String)? = nil) {
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!
        ))
        if let credentials {
            proxy.applyCredential(username: credentials.username, password: credentials.password)
        }
        proxy.allowFailover = false
        configuration.websiteDataStore.proxyConfigurations = [proxy]
    }

    var canManageSessions: Bool {
        !closing && managementView != nil && viewerView == nil
    }

    func showSessionRecovery() {
        guard canManageSessions, let webView = managementView else { return }
        if let recovery {
            recovery.show()
            return
        }
        let recovery = SessionRecoveryWindow(
            profile: profile, proxy: webView.configuration.websiteDataStore.proxyConfigurations.first
        ) { [weak self, weak webView] retry in
            guard let self else { return }
            self.recovery = nil
            guard !self.closing else { return }
            webView?.window?.makeKeyAndOrderFront(nil)
            if retry, let webView {
                Task {
                    await self.logoutManagement()
                    guard !self.closing else { return }
                    webView.load(URLRequest(url: self.profile.loginURL, cachePolicy: .reloadIgnoringLocalCacheData))
                }
            }
        }
        self.recovery = recovery
        recovery.show()
    }

    fileprivate func loginLimitDetected(_ message: WKScriptMessage) {
        guard message.webView === managementView, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, profile.isLoginPage(url) else { return }
        showSessionRecovery()
    }

    @discardableResult
    func close(_ scope: SessionLogout = .session) -> Task<Void, Never> {
        if let sessionClose { return sessionClose }

        switch scope {
        case .viewer:
            if let viewerClose { return viewerClose }
            let task = Task {
                await scope.perform(viewer: logoutViewer, management: logoutManagement)
                viewerClose = nil
            }
            viewerClose = task
            return task
        case .session:
            closing = true
            let task = Task {
                if let recovery { await recovery.close().value }
                if let viewerClose { await viewerClose.value }
                await scope.perform(viewer: logoutViewer, management: logoutManagement)
                dispose()
            }
            sessionClose = task
            return task
        }
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        close(profile.showManagement && window === viewerView?.window ? .viewer : .session)
        return false
    }

    func setKVMMaintenance(_ enabled: Bool) {
        maintainsKVM = enabled
        updateMaintenance()
    }

    private func updateMaintenance() {
        guard maintainsKVM, !closing, viewerView != nil, !viewerExited else {
            maintenance.stop()
            return
        }
        maintenance.start { [weak self] in
            await self?.refreshWebSession()
        }
    }

    private func refreshWebSession() async {
        guard let webView = managementView, let url = webView.url, profile.isManagementPage(url) else { return }
        let result = try? await webView.callAsyncJavaScript(
            KVMSessionMaintenance.webPulse, arguments: [:], in: nil, contentWorld: .page
        ) as? Bool
        if result == true {
            maintenanceLog.debug("CIMC Web session heartbeat acknowledged")
        } else {
            maintenanceLog.debug("CIMC Web session heartbeat unavailable")
        }
    }

    private func logoutViewer() async {
        maintenance.stop()
        guard let webView = viewerView, let window = webView.window else { return }
        if !viewerExited, let url = webView.url, profile.allowsNavigation(to: url),
           url.path == "/html/kvmViewer.html" {
            _ = try? await webView.evaluateJavaScript("window.logOut?.('exit');")
            await waitForLogout { self.viewerExited }
        }
        viewerView = nil
        windows.remove(window)
        window.close()
        if !closing {
            managementView?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func logoutManagement() async {
        guard let webView = managementView, let url = webView.url, profile.isManagementPage(url) else { return }
        _ = try? await webView.evaluateJavaScript("window.webUI?.logOut?.();")
        await waitForLogout {
            guard let url = webView.url else { return true }
            return self.profile.isLoginPage(url)
        }
    }

    private func waitForLogout(_ finished: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !finished() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(75))
        }
    }

    private func dispose() {
        closing = true
        maintenance.stop()
        recovery?.close()
        tunnel?.stop()
        for window in windows {
            window.close()
        }
        windows.removeAll()
        onClose()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closing, webView === managementView, windows.count == 1,
              let url = navigationAction.request.url, profile.allowsNavigation(to: url) else { return nil }
        let console = openWindow(title: "\(profile.address) KVM", configuration: configuration)
        viewerView = console
        viewerExited = false
        updateMaintenance()
        if !profile.showManagement {
            webView.window?.orderOut(nil)
            progressCover?.removeFromSuperview()
        }
        return console
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !closing, !profile.showManagement, webView === managementView, windows.count == 1,
              let url = webView.url else { return }
        if profile.isManagementPage(url), let content = webView.superview {
            showLaunchProgress(in: content)
        } else if profile.isLoginPage(url) {
            progressCover?.removeFromSuperview()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closing, webView === managementView, let url = webView.url else { return }
        if profile.isLoginPage(url), !profile.username.isEmpty {
            webView.callAsyncJavaScript(
                Self.prefillUsername, arguments: ["username": profile.username],
                in: nil, in: .defaultClient, completionHandler: nil
            )
        }
        guard !profile.showManagement, windows.count == 1, !attemptingLaunch,
              profile.isManagementPage(url) else { return }
        attemptingLaunch = true
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            defer { self.attemptingLaunch = false }
            let result = try? await webView.callAsyncJavaScript(
                Self.launchKVM, arguments: [:], in: nil, contentWorld: .page
            )
            if result as? String == "clicked" && self.windows.count == 1 {
                try? await Task.sleep(for: .seconds(3))
            }
            guard !self.closing, self.windows.count == 1 else { return }
            self.progressCover?.removeFromSuperview()
        }
    }

    private static let prefillUsername = """
        return await new Promise(resolve => {
            const observer = new MutationObserver(fill);
            const timer = setTimeout(done, 8000);
            function done() {
                observer.disconnect();
                clearTimeout(timer);
                resolve();
            }
            function fill() {
                const password = document.querySelector("input[type='password']:not([disabled])");
                const user = Array.from(document.querySelectorAll("input[type='text']:not([disabled])"))
                    .find(field => /username|user.name|login/i.test(
                        [field.name, field.id, field.getAttribute('aria-label')].join(' ')
                    ));
                if (!password || !user) return;
                if (!user.value) {
                    user.value = username;
                    user.dispatchEvent(new Event('input', { bubbles: true }));
                    user.dispatchEvent(new Event('change', { bubbles: true }));
                    if (document.activeElement === user || document.activeElement === document.body) password.focus();
                }
                done();
            }
            observer.observe(document, { subtree: true, childList: true, attributes: true });
            fill();
        });
        """

    private static let launchKVM = """
        return await new Promise(resolve => {
            const title = /\\bLaunch\\s+v?KVM\\b/i;
            const selector = "button, [role='button'], a, input[type='button']";
            const observer = new MutationObserver(launch);
            const timeout = setTimeout(() => {
                observer.disconnect();
                resolve("button not found");
            }, 12000);

            function launch() {
                const control = Array.from(document.querySelectorAll(selector)).find(element => {
                    if (element.disabled || element.getAttribute('aria-disabled') === 'true') return false;
                    const label = (element.getAttribute('aria-labelledby') ?? '').split(' ')
                        .map(id => document.getElementById(id)?.textContent).join(' ');
                    return [label, element.getAttribute('aria-label'), element.title, element.value, element.textContent]
                        .some(text => title.test(text ?? ''));
                });
                if (!control) return;
                observer.disconnect();
                clearTimeout(timeout);
                control.click();
                resolve("clicked");
            }

            observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            launch();
        });
        """

    func webViewDidClose(_ webView: WKWebView) {
        if webView === viewerView {
            viewerExited = true
            maintenance.stop()
            if viewerClose == nil && !closing {
                close(profile.showManagement ? .viewer : .session)
            }
        } else if webView === managementView && !closing {
            close()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url.map(profile.allowsNavigation(to:)) ?? false
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch profile.certificatePolicy(host: space.host, port: space.port) {
        case .system:
            completionHandler(.performDefaultHandling, nil)
        case .ignoreErrors:
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let failure = error as NSError
        if !closing && failure.domain == NSURLErrorDomain && failure.code != NSURLErrorCancelled
            && failure.code != NSURLErrorUserCancelledAuthentication {
            showError("CIMC の画面を開けませんでした。\n\(failure.localizedDescription)")
        }
    }

    private func openWindow(title: String, configuration: WKWebViewConfiguration) -> WKWebView {
        let window = CIMCWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: window.contentLayoutRect)
        let webView = WKWebView(frame: content.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        content.addSubview(webView)
        window.contentView = content
        windows.insert(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.activate()
        return webView
    }

    private func showLaunchProgress(in content: NSView) {
        progressCover?.removeFromSuperview()
        let cover = NSView(frame: content.bounds)
        cover.autoresizingMask = [.width, .height]
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let status = NSTextField(labelWithString: "KVMに接続中…")
        status.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(status)
        content.addSubview(cover)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])
        progressCover = cover
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

}


@MainActor
private final class CIMCLoginLimitObserver: NSObject, WKScriptMessageHandler {
    static let name = "cimcLoginLimit"
    weak var session: CIMCSession?

    init(session: CIMCSession) {
        self.session = session
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.loginLimitDetected(message)
    }

    static let script = WKUserScript(
        source: CIMCLoginLimit.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
    )
}

@MainActor
enum CIMCDebugPanel {
    static let script = WKUserScript(
        source: """
            if (location.pathname === "/index.html" || location.pathname === "/html/kvmViewer.html") {
                const selector = '#firebug.firebug #firebugToolbar a[title="Close the console"][onclick="console.close(); return false;"]';
                const observer = new MutationObserver(closePanel);
                function closePanel() {
                    const control = document.querySelector(selector);
                    if (!control) return;
                    observer.disconnect();
                    control.click();
                }
                observer.observe(document, { childList: true, subtree: true });
                closePanel();
            }
            """,
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient
    )
}

enum CIMCLoginLimit {
    static let source = #"""
        if (location.pathname === "/login.html") {
            const sessionLimit = /maximum number of user sessions has been reached|ユーザー?\s*セッション.{0,32}(?:上限|最大)|(?:上限|最大).{0,32}セッション数に達/i;
            const observer = new MutationObserver(check);
            function check() {
                const text = document.body?.innerText ?? "";
                if (!sessionLimit.test(text)) return;
                observer.disconnect();
                window.webkit.messageHandlers.cimcLoginLimit.postMessage(null);
            }
            observer.observe(document.documentElement, {
                subtree: true, childList: true, characterData: true, attributes: true,
                attributeFilter: ["class", "style", "hidden", "aria-hidden"]
            });
            check();
        }
        """#
}
