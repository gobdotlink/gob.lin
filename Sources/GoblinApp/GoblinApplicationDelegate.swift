import AppKit

@MainActor
final class GoblinApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        if !model.history.pending.isEmpty || model.insertion.hasRecoveryClipboard {
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
        // A microphone stuck inside CoreAudio never finishes shutting down; quit anyway after a few seconds.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model.shutdown()
            reply()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            reply()
        }
        return .terminateLater
    }
}
