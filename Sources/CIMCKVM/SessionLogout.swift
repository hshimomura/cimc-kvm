enum SessionLogout {
    case viewer
    case session

    @MainActor
    func perform(viewer: () async -> Void, management: () async -> Void) async {
        await viewer()
        if self == .session { await management() }
    }
}
