import Foundation

@MainActor
final class KVMSessionMaintenance {
    private let interval: Duration
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?
    private var worker: Task<Void, Never>?

    init(
        interval: Duration = .seconds(30),
        begin: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "CIMC KVM session")
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.interval = interval
        self.begin = begin
        self.end = end
    }

    func start(pulse: @escaping @MainActor () async -> Void) {
        guard activity == nil else { return }
        activity = begin()
        worker = Task { [interval] in
            while !Task.isCancelled {
                await pulse()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        if let activity {
            end(activity)
            self.activity = nil
        }
    }

    // Uses the firmware Web UI's authenticated, read-only sessionData request.
    // The token and response stay in the originating WebKit page.
    static let webPulse = """
        if (location.protocol !== "https:" || location.pathname !== "/index.html") return false;
        const ui = window.webUI;
        const id = ui?.sessionInfo?.getAppSessionId?.()
            || ui?.getSessionData?.()?.getAppSessionId?.();
        if (!id) return false;

        const body = new URLSearchParams({
            sessionID: id,
            queryString: encodeURIComponent("get=sessionData")
        });
        const response = await fetch("/data", {
            method: "POST", credentials: "same-origin", redirect: "error", cache: "no-store",
            headers: { "X-Requested-With": "XMLHttpRequest", "PreventCache": "nocache" },
            body, signal: AbortSignal.timeout(8000)
        });
        if (!response.ok) return false;
        const xml = await response.text();
        return xml.includes("sessionId") && xml.includes("sidValue");
        """
}
