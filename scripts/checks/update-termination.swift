import AppKit
import Foundation

@MainActor
private final class TerminationDelegate: NSObject, NSApplicationDelegate {
    let marker: URL
    init(marker: URL) { self.marker = marker }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        try? Data("termination requested".utf8).write(to: marker)
        Task { @MainActor in
            try? Data("shutdown started".utf8).write(to: marker)
            // Exercise a genuinely asynchronous shutdown, as in GoblinApplicationDelegate.
            try? await Task.sleep(for: .milliseconds(20))
            do { try Data("shutdown finished".utf8).write(to: marker) }
            catch { exit(2) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct UpdateTerminationCheck {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = TerminationDelegate(marker: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        Task { @MainActor in
            // Production handoff must return from its task before entering AppKit termination.
            UpdateChecker.requestTermination()
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
