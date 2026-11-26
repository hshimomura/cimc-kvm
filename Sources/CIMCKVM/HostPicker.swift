import SwiftUI

struct HostPicker: View {
    let store: ProfileStore
    let connect: (ConnectionProfile, String?) -> Void

    @State private var profiles: [ConnectionProfile]
    @State private var selection: UUID?
    @State private var editor: EditorRequest?
    @State private var proxyLogin: ConnectionProfile?
    @State private var confirmingRemoval = false
    @State private var storageError: String?

    init(store: ProfileStore, profiles: [ConnectionProfile], connect: @escaping (ConnectionProfile, String?) -> Void) {
        self.store = store
        self.connect = connect
        _profiles = State(initialValue: profiles)
        _selection = State(initialValue: profiles.first?.id)
    }

    private var selected: ConnectionProfile? { profiles.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(profiles) { profile in
                    Button { selection = profile.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "display")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.address).font(.body.weight(.medium))
                                Text(profile.route.description + (profile.username.isEmpty ? "" : " · \(profile.username)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(profile.showManagement ? "CIMC" : "KVM")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tag(profile.id)
                }
            }
            .accessibilityLabel("登録済みの接続先")
            .overlay {
                if profiles.isEmpty {
                    ContentUnavailableView("登録済みの接続先がありません", systemImage: "display")
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button { editor = EditorRequest(profile: nil) } label: {
                    Label("追加", systemImage: "plus")
                }
                Button("編集") {
                    if let selected { editor = EditorRequest(profile: selected) }
                }
                .disabled(selected == nil)
                Button("削除") { confirmingRemoval = true }
                    .disabled(selected == nil)
                Spacer()
                Button("接続") {
                    if let selected { start(selected) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
            .padding(14)
        }
        .sheet(item: $editor) { request in
            HostEditor(profile: request.profile, save: save)
        }
        .sheet(item: $proxyLogin) { profile in
            if case let .socks(_, _, username) = profile.route {
                ProxyPasswordSheet(profile: profile, username: username, connect: connect)
            }
        }
        .confirmationDialog("この接続先を削除しますか？", isPresented: $confirmingRemoval) {
            Button("削除", role: .destructive, action: removeSelected)
        } message: {
            if let selected { Text(selected.address) }
        }
        .alert("接続先を保存できませんでした", isPresented: Binding(
            get: { storageError != nil }, set: { if !$0 { storageError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storageError ?? "")
        }
    }

    private func start(_ profile: ConnectionProfile) {
        selection = profile.id
        if case let .socks(_, _, username) = profile.route, !username.isEmpty {
            proxyLogin = profile
        } else {
            connect(profile, nil)
        }
    }

    private func save(_ profile: ConnectionProfile) throws {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        try store.save(updated)
        profiles = updated
        selection = profile.id
    }

    private func removeSelected() {
        guard let selected else { return }
        let updated = profiles.filter { $0.id != selected.id }
        do {
            try store.save(updated)
            profiles = updated
            selection = updated.first?.id
        } catch {
            storageError = error.localizedDescription
        }
    }

    private struct EditorRequest: Identifiable {
        let profile: ConnectionProfile?
        let id = UUID()
    }
}

private struct HostEditor: View {
    enum Route: String, CaseIterable {
        case direct = "直接接続"
        case socks = "SOCKS5"
        case ssh = "SSH踏み台"
    }

    let existingID: UUID?
    let save: (ConnectionProfile) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var username: String
    @State private var route = Route.direct
    @State private var socksAddress = ""
    @State private var socksPort = "1080"
    @State private var socksUsername = ""
    @State private var jumpHost = ""
    @State private var ignoreCertificateErrors: Bool
    @State private var showManagement: Bool
    @State private var error: String?

    init(profile: ConnectionProfile?, save: @escaping (ConnectionProfile) throws -> Void) {
        existingID = profile?.id
        self.save = save
        _address = State(initialValue: profile?.address ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _ignoreCertificateErrors = State(initialValue: profile?.ignoreCertificateErrors ?? false)
        _showManagement = State(initialValue: profile?.showManagement ?? false)
        switch profile?.route {
        case let .socks(address, port, username):
            _route = State(initialValue: .socks)
            _socksAddress = State(initialValue: address)
            _socksPort = State(initialValue: String(port))
            _socksUsername = State(initialValue: username)
        case let .ssh(destination):
            _route = State(initialValue: .ssh)
            _jumpHost = State(initialValue: destination)
        case .direct, nil:
            break
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existingID == nil ? "接続先を追加" : "接続先を編集")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Form {
                Section("CIMC") {
                    TextField("接続先", text: $address, prompt: Text("IPアドレスまたはFQDN"))
                        .focused($focused, equals: .address)
                    TextField("ユーザー名", text: $username)
                }
                Section("経路") {
                    Picker("接続経路", selection: $route) {
                        ForEach(Route.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    switch route {
                    case .direct:
                        EmptyView()
                    case .socks:
                        TextField("SOCKS5ホスト", text: $socksAddress)
                        TextField("ポート", text: $socksPort)
                        TextField("SOCKS5ユーザー名", text: $socksUsername, prompt: Text("認証が必要な場合"))
                    case .ssh:
                        TextField("SSHホスト", text: $jumpHost, prompt: Text("SSHの別名または user@host"))
                    }
                }
                Section("オプション") {
                    Toggle("証明書エラーを無視", isOn: $ignoreCertificateErrors)
                    Toggle("接続後にCIMC管理画面を表示", isOn: $showManagement)
                }
            }
            .formStyle(.grouped)
            .defaultFocus($focused, .address)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 450)
    }

    @FocusState private var focused: Field?
    private enum Field { case address }

    private func submit() {
        do {
            let connection: ConnectionRoute
            switch route {
            case .direct:
                connection = .direct
            case .socks:
                guard let port = UInt16(socksPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw ProfileError.invalidProxy
                }
                connection = .socks(address: socksAddress, port: port, username: socksUsername)
            case .ssh:
                connection = .ssh(destination: jumpHost)
            }
            try save(ConnectionProfile(
                id: existingID ?? UUID(), address: address, username: username, route: connection,
                ignoreCertificateErrors: ignoreCertificateErrors, showManagement: showManagement
            ))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProxyPasswordSheet: View {
    let profile: ConnectionProfile
    let username: String
    let connect: (ConnectionProfile, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SOCKS5認証").font(.headline)
            Text(username).foregroundStyle(.secondary)
            SecureField("パスワード", text: $password)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("接続") {
                    let credential = password
                    password = ""
                    dismiss()
                    DispatchQueue.main.async { connect(profile, credential) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}
