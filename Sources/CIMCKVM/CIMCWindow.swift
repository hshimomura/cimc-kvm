import AppKit

final class CIMCWindow: NSWindow {
    enum Shortcut { case close, quit }

    nonisolated static func shortcut(characters: String?, modifiers: NSEvent.ModifierFlags) -> Shortcut? {
        guard modifiers.intersection([.command, .control, .option, .shift]) == .command else {
            return nil
        }
        switch characters?.lowercased() {
        case "w": return .close
        case "q": return .quit
        default: return nil
        }
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp,
              let shortcut = Self.shortcut(characters: event.charactersIgnoringModifiers,
                                           modifiers: event.modifierFlags) else {
            super.sendEvent(event)
            return
        }
        // Keep local window shortcuts out of the embedded KVM keyboard.
        guard event.type == .keyDown, !event.isARepeat else { return }
        switch shortcut {
        case .close: performClose(nil)
        case .quit: NSApp.terminate(nil)
        }
    }
}
