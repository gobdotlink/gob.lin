import AppKit

@MainActor
final class GoblinApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    /// The person already chose Quit Anyway for this quit, so it isn't asked a second time.
    private var unsavedConfirmed = false
    /// The unsaved-data question is up; another quit arriving meanwhile doesn't ask it again on top.
    private var askingUnsaved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `NSApp.delegate` is SwiftUI's wrapper around this one, so the menus' Quit is handed it here.
        UpdateChecker.quit = (self, #selector(quit))
        StatusMenu.install { [weak self] in self?.model }
        // AppKit drops a quit while any window has a sheet up, without asking the delegate. macOS's own requests
        // (System Settings' Quit & Reopen, logging out) come here instead, so they close the sheets first.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        quit()
        // Only reached when the person kept gob.lin open; tell whoever asked, as AppKit's own handler does.
        reply.setParam(NSAppleEventDescriptor(int32: Int32(userCanceledErr)), forKeyword: keyErrorNumber)
    }

    /// Quits whatever is on screen: asks about unsaved data, closes any sheet, then terminates. It returns only when
    /// gob.lin stays open: the person chose that, or it was to reopen and the helper for that wouldn't start.
    @objc func quit() {
        let reopen = Relaunch.takeRequest()
        guard confirmUnsaved() else { return }
        // Only now, so a quit the person turned down leaves nothing waiting to reopen gob.lin later.
        if reopen, !Relaunch.start() {
            unsavedConfirmed = false
            return
        }
        SystemAudioAccess.shared.rememberSetupForNextLaunch()
        for window in NSApp.windows { closeSheets(of: window) }
        NSApp.terminate(nil)
    }

    private func closeSheets(of window: NSWindow) {
        for sheet in window.sheets {
            closeSheets(of: sheet)
            window.endSheet(sheet)
        }
    }

    /// False when unsaved data remains and the person chose to keep gob.lin open.
    private func confirmUnsaved() -> Bool {
        guard let model, !unsavedConfirmed, !model.history.pending.isEmpty || model.insertion.hasRecoveryClipboard else { return true }
        guard !askingUnsaved else { return false }
        askingUnsaved = true
        defer { askingUnsaved = false }
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
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        unsavedConfirmed = true
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        guard confirmUnsaved() else { return .terminateCancel }
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
