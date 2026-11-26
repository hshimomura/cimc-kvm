import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private static let maintainsKVMKey = "maintainsKVMSession"
    private var maintainsKVM: Bool { UserDefaults.standard.bool(forKey: Self.maintainsKVMKey) }
    private var picker: NSWindow?
    private var session: CIMCSession?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.maintainsKVMKey: true])
        installMenu()
        let store = ProfileStore(defaults: .standard)
        do {
            let profiles = try store.load()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 385),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = "CIMC 接続先"
            window.contentMinSize = NSSize(width: 490, height: 300)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: HostPicker(store: store, profiles: profiles) {
                [weak self] profile, proxyPassword in self?.connect(profile, proxyPassword: proxyPassword)
            })
            picker = window
            window.center()
            showPicker()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        if !terminating {
            terminating = true
            Task {
                await session.close().value
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        if !terminating { NSApp.terminate(nil) }
    }

    private func connect(_ profile: ConnectionProfile, proxyPassword: String?) {
        guard session == nil else { return }
        let connection = CIMCSession(profile: profile, maintainsKVM: maintainsKVM) { [weak self] in
            guard let self else { return }
            self.session = nil
            if !self.terminating { self.showPicker() }
        }
        session = connection
        picker?.orderOut(nil)
        connection.start(proxyPassword: proxyPassword)
    }

    private func showPicker() {
        picker?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func showSessionRecovery(_ item: NSMenuItem) {
        session?.showSessionRecovery()
    }

    @objc private func toggleKVMMaintenance(_ item: NSMenuItem) {
        let enabled = !maintainsKVM
        UserDefaults.standard.set(enabled, forKey: Self.maintainsKVMKey)
        session?.setKVMMaintenance(enabled)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showSessionRecovery(_:)) { return session?.canManageSessions == true }
        if item.action == #selector(toggleKVMMaintenance(_:)) { item.state = maintainsKVM ? .on : .off }
        return true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = appMenu.addItem(withTitle: "cimc-kvm を終了",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let connectionItem = NSMenuItem()
        let connectionMenu = NSMenu(title: "接続")
        let recovery = connectionMenu.addItem(withTitle: "CIMC セッション管理…",
                                              action: #selector(showSessionRecovery(_:)), keyEquivalent: "")
        recovery.target = self
        let maintenance = connectionMenu.addItem(withTitle: "KVMセッションを維持",
                                                 action: #selector(toggleKVMMaintenance(_:)), keyEquivalent: "")
        maintenance.target = self
        connectionItem.submenu = connectionMenu
        mainMenu.addItem(connectionItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

@main
enum CIMCKVMApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
    }
}
