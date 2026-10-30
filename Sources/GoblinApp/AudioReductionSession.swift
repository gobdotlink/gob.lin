import Foundation

/// Closing stdin ends the lease, including when the app exits unexpectedly.
@MainActor
final class AudioReductionSession {
    private var helpers: [(process: Process, input: Pipe)] = []
    private var ended = false

    init(pauseMedia: Bool, muteAudio: Bool) {
        if pauseMedia, let script = GoblinBrand.assetDirectory?.appendingPathComponent("pause-media.js") {
            start(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-l", "JavaScript", script.path])
        }
        if muteAudio, let executable = Bundle.main.executableURL {
            start(executable, arguments: ["--mute-output-while-dictating"])
        }
    }

    private func start(_ executable: URL, arguments: [String]) {
        let process = Process(), input = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            helpers.append((process, input))
            try? input.fileHandleForReading.close()
        } catch { try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close() }
    }

    /// Ends the lease: the helpers restore media and output now. `finish` waits for them to exit.
    func end() {
        guard !ended else { return }
        ended = true
        for helper in helpers { try? helper.input.fileHandleForWriting.close() }
    }

    func finish() async {
        end()
        // Await this lease before the next capture so a late pause cannot outlive its owner.
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while helpers.contains(where: { $0.process.isRunning }) && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { continuation.resume() }
            }
        }
        for helper in helpers where helper.process.isRunning { helper.process.terminate() }
    }

    deinit { for helper in helpers { try? helper.input.fileHandleForWriting.close() } }
}
