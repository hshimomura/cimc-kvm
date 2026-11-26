import AppKit
import Network
import SwiftUI

@MainActor
final class SessionRecoveryWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SessionRecoveryModel
    private let onClose: (Bool) -> Void
    private var closing: Task<Void, Never>?

    init(profile: ConnectionProfile, proxy: ProxyConfiguration?, onClose: @escaping (Bool) -> Void) {
        model = SessionRecoveryModel(profile: profile, proxy: proxy)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 450),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        self.onClose = onClose
        super.init()
        window.title = "CIMC セッション管理"
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SessionRecoveryView(
            model: model, profile: profile, retry: { [weak self] in self?.close(retry: true) }
        ))
        window.center()
    }

    func show() {
        if closing == nil { window.makeKeyAndOrderFront(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    @discardableResult
    func close(retry: Bool = false) -> Task<Void, Never> {
        if let closing { return closing }
        let task = Task {
            await model.stop()
            window.close()
            onClose(retry)
        }
        closing = task
        return task
    }
}

@MainActor
private final class SessionRecoveryModel: ObservableObject {
    @Published private(set) var sessions: [CIMCUserSession] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var issue: String?
    @Published private(set) var status: String?

    private let profile: ConnectionProfile
    private let proxy: ProxyConfiguration?
    private var cli: CIMCRecoveryCLI?
    private var closing = false

    init(profile: ConnectionProfile, proxy: ProxyConfiguration?) {
        self.profile = profile
        self.proxy = proxy
    }

    func connect(username: String, password: String) {
        run {
            do {
                let connection = try CIMCRecoveryCLI(
                    address: self.profile.address, route: self.profile.route, proxy: self.proxy
                )
                self.cli = connection
                try await connection.connect(username: username, password: password, verify: self.confirmHostKey)
                self.sessions = try await connection.list()
                self.ready = true
            } catch {
                await self.cli?.disconnect()
                self.cli = nil
                throw error
            }
        }
    }

    func refresh() {
        run {
            guard let cli = self.cli else { return }
            self.sessions = try await cli.list()
        }
    }

    func terminate(_ selected: CIMCUserSession) {
        run {
            guard let cli = self.cli, selected.killable else { return }
            do {
                self.sessions = try await cli.terminate(selected)
                self.status = "セッション \(selected.id) を切断しました。"
            } catch CIMCRecoveryError.sessionChanged {
                self.sessions = try await cli.list()
                throw CIMCRecoveryError.sessionChanged
            }
        }
    }

    func stop() async {
        closing = true
        busy = true
        await cli?.disconnect()
        cli = nil
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy && !closing else { return }
        busy = true
        issue = nil
        status = nil
        Task {
            defer { if !closing { busy = false } }
            do {
                try await action()
            } catch {
                guard !closing else { return }
                issue = error.localizedDescription
                if let recoveryError = error as? CIMCRecoveryError,
                   [.unavailable, .timedOut, .scopeRejected, .authenticationFailed].contains(recoveryError) {
                    await cli?.disconnect()
                    cli = nil
                    ready = false
                    sessions = []
                }
            }
        }
    }

    private func confirmHostKey(_ fingerprint: String) -> Bool {
        guard !closing else { return false }
        let alert = NSAlert()
        alert.messageText = "\(profile.address) の SSH ホスト鍵を確認"
        alert.informativeText = "確認済みの指紋と照合してください。\n\n\(fingerprint)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "一致したので接続")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private struct SessionRecoveryView: View {
    @ObservedObject var model: SessionRecoveryModel
    let profile: ConnectionProfile
    let retry: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var selection: CIMCUserSession.ID?
    @State private var confirming = false

    init(model: SessionRecoveryModel, profile: ConnectionProfile, retry: @escaping () -> Void) {
        self.model = model
        self.profile = profile
        self.retry = retry
        _username = State(initialValue: profile.username)
    }

    private var selected: CIMCUserSession? { model.sessions.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.address).font(.title2.weight(.semibold))
                Text("管理者認証 · \(profile.route.description)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if model.ready {
                Table(model.sessions, selection: $selection) {
                    TableColumn("ID") { Text(String($0.id)).monospacedDigit() }.width(55)
                    TableColumn("ユーザー", value: \.user)
                    TableColumn("接続元", value: \.source)
                    TableColumn("種別", value: \.kind)
                    TableColumn("状態") { row in
                        Text(row.killable ? "切断可" : "切断不可")
                            .foregroundStyle(row.killable ? .primary : .secondary)
                    }
                    .width(75)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("ユーザー名", text: $username)
                    SecureField("パスワード", text: $password)
                    Button("一覧を取得") {
                        let credential = password
                        password = ""
                        model.connect(username: username, password: credential)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || password.isEmpty || username.isEmpty)
                }
                .disabled(model.busy)
                Spacer()
            }

            if let issue = model.issue {
                Text(issue).foregroundStyle(.red)
            } else if let status = model.status {
                Text(status).foregroundStyle(.secondary)
            }
            HStack {
                if model.ready {
                    Button("更新") { model.refresh() }.disabled(model.busy)
                    Button("切断") { confirming = true }
                        .disabled(model.busy || selected?.killable != true)
                }
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("処理中") }
                Spacer()
                Button("再接続", action: retry).disabled(model.busy)
            }
        }
        .padding(20)
        .alert("選んだセッションを切断しますか？", isPresented: $confirming, presenting: selected) { row in
            Button("切断", role: .destructive) { model.terminate(row) }
            Button("キャンセル", role: .cancel) {}
        } message: { row in
            Text("ID \(row.id) · \(row.user) · \(row.source) · \(row.kind)")
        }
    }
}
