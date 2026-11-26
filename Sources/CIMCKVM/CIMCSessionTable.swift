import Foundation

struct CIMCUserSession: Identifiable, Equatable {
    let id: Int
    let user: String
    let source: String
    let kind: String
    let killable: Bool
}

enum CIMCRecoveryError: LocalizedError {
    case invalidTable
    case sessionChanged
    case protectedSession
    case scopeRejected
    case terminationRejected
    case invalidCredentials
    case authenticationFailed
    case hostKeyChanged
    case unverifiedKey
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidTable: return "CIMCのセッション一覧を読み取れませんでした。管理者権限とCLIの対応状況を確認してください。"
        case .sessionChanged: return "選択したセッションが変わりました。一覧を確認して選び直してください。"
        case .protectedSession: return "このセッションは切断できません。"
        case .scopeRejected: return "CIMCが選択したセッションを指定できませんでした。"
        case .terminationRejected: return "CIMCで切断を確認できませんでした。"
        case .invalidCredentials: return "管理者ユーザー名とパスワードを入力してください。"
        case .authenticationFailed: return "CIMC CLIの認証に失敗しました。資格情報とCLIの接続枠を確認してください。"
        case .hostKeyChanged: return "CIMCのSSHホスト鍵が登録済みの鍵と一致しません。"
        case .unverifiedKey: return "CIMCのSSHホスト鍵が確認されませんでした。"
        case .unavailable: return "CIMCのSSH CLIに接続できませんでした。接続経路とTCP 22を確認してください。"
        case .timedOut: return "CIMC CLIから応答がありませんでした。"
        }
    }
}

enum CIMCSessionTable {
    enum Prompt { case global, session }

    static func prompt(in text: String) -> Prompt? {
        guard let last = text.split(whereSeparator: \.isNewline).last else { return nil }
        if last.range(of: #"^[a-zA-Z0-9_.:-]+\s*/user-session\s+#\s*$"#, options: .regularExpression) != nil {
            return .session
        }
        if last.range(of: #"^[a-zA-Z0-9_.:-]+\s*#\s*$"#, options: .regularExpression) != nil {
            return .global
        }
        return nil
    }

    static func parse(_ text: String) throws -> [CIMCUserSession] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.firstIndex(where: { line in
            line.hasPrefix("ID ") && line.contains("IP Address") && line.contains("Killable")
        }), prompt(in: text) == .global else { throw CIMCRecoveryError.invalidTable }
        let nameIndex = lines[header].contains("BMC Session ID") ? 2 : 1
        var ids = Set<Int>()
        var sessions: [CIMCUserSession] = []
        for row in lines.dropFirst(header + 1).dropLast() {
            let line = row.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.allSatisfy({ $0 == "-" || $0.isWhitespace }) { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= nameIndex + 4, let id = Int(fields[0]), id > 0,
                  let killable = fields.last?.lowercased(), ["yes", "no"].contains(killable),
                  ids.insert(id).inserted else { throw CIMCRecoveryError.invalidTable }
            sessions.append(CIMCUserSession(
                id: id, user: String(fields[nameIndex]), source: String(fields[nameIndex + 1]),
                kind: fields[(nameIndex + 2)..<(fields.count - 1)].joined(separator: " "),
                killable: killable == "yes"
            ))
        }
        return sessions
    }

    static func revalidate(_ selected: CIMCUserSession, in current: [CIMCUserSession]) throws -> Int {
        guard selected.killable else { throw CIMCRecoveryError.protectedSession }
        guard current.contains(selected) else { throw CIMCRecoveryError.sessionChanged }
        return selected.id
    }
}
