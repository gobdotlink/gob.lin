import Foundation

/// Closing stdin ends the lease, including when the app exits unexpectedly.
@MainActor
final class MediaPauseSession {
    private let process = Process()
    private let input = Pipe()
    private var ended = false

    init?(script: URL) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", script.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); try input.fileHandleForReading.close() }
        catch { try? input.fileHandleForWriting.close(); return nil }
    }

    func finish() async {
        if !ended { ended = true; try? input.fileHandleForWriting.close() }
        // Await this lease before the next capture so a late pause cannot outlive its owner.
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while process.isRunning && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { continuation.resume() }
            }
        }
        if process.isRunning { process.terminate() }
    }

    deinit { try? input.fileHandleForWriting.close() }
}
