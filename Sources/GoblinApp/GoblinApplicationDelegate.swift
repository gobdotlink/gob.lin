import AppKit

@MainActor
final class GoblinApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusMenu.install { [weak self] in self?.model }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        if !model.history.pending.isEmpty || model.insertion.hasRecoveryClipboard {
            // Quit can come from a menu that left gob.lin in the background; bring the question forward.
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unsaved data remains in gob.lin"
            var details: [String] = []
            if !model.history.pending.isEmpty {
                details.append("\(model.history.pending.count) dictation(s) could not be saved. Keep gob.lin open to copy or retry their raw text. Quitting loses the unsaved text.")
            }
            if model.insertion.hasRecoveryClipboard {
                details.append("Your previous clipboard still has a recovery copy. Restore it from the menu before quitting if you want to keep it. Quitting leaves the current clipboard in place and loses that recovery copy.")
            }
            alert.informativeText = details.joined(separator: "\n\n")
            alert.addButton(withTitle: "Keep gob.lin open")
            alert.addButton(withTitle: "Quit anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        terminating = true
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
