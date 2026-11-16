import Foundation
import GoblinEngines
import GoblinMeetings

/// `goblin meetings …`: read and process meeting folders. Output is JSON on stdout, like the rest
/// of the CLI; `--verbose` sends progress lines to stderr.
enum MeetingsCommand {
    static let usage = """
    Usage: goblin meetings list [--root <dir>]
           goblin meetings show <id> [--markdown] [--root <dir>]
           goblin meetings process <folder> [--preset offline|fast32|fast128] [--verbose]
           goblin meetings export-fixture <id> <destination> [--root <dir>]
           goblin meetings simulate --system <audio> [--mic <audio>] [--echo <gain>] [--title <text>]
             [--preset offline|fast32|fast128] [--root <dir>] [--verbose]
      simulate writes to a new temporary folder unless --root is given.
    """

    /// Whether these arguments need a speech model: `simulate` transcribes, and so does `process` for a folder whose
    /// live transcript left speech for after the call.
    static func needsSpeechModel(_ arguments: [String]) -> Bool {
        let rest = Array(arguments.dropFirst())
        switch rest.first {
        case "simulate": return true
        case "process":
            return rest.dropFirst().contains { argument in
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: argument, isDirectory: true)
                    .appendingPathComponent(MeetingStorage.deferredFile).path)
            }
        default: return false
        }
    }

    /// `recognition` is the language (and vocabulary) the CLI was asked for; `simulate` transcribes with it.
    static func run(_ arguments: [String], engine: (any PCMSpeechEngine)? = nil,
                    recognition: RecognitionOptions = .init(language: "en")) async throws {
        var arguments = Array(arguments.dropFirst())
        guard let command = arguments.first else { throw CommandError.usage(usage) }
        arguments.removeFirst()
        var options = try Options(arguments)
        let rootOption = options.take("--root").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = rootOption ?? MeetingStorage.root
        let verbose = options.flag("--verbose")
        let log: @Sendable (String) -> Void = { message in
            if verbose { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        }

        switch command {
        case "list":
            try options.finish(positional: 0)
            try write(await MeetingStore(root: root).list())
        case "show":
            let markdown = options.flag("--markdown")
            let id = try options.finish(positional: 1)[0]
            let store = MeetingStore(root: root)
            if markdown {
                FileHandle.standardOutput.write(Data((try await store.markdown(id) + "\n").utf8))
            } else {
                try write(try await store.detail(id))
            }
        case "process":
            let preset = try options.preset()
            let folder = URL(fileURLWithPath: try options.finish(positional: 1)[0], isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingStorage.segmentsFile).path)
                    || FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingStorage.audioFile(.system)).path) else {
                throw CommandError.usage("\(folder.path) is not a meeting folder (no segments.jsonl or system.wav).")
            }
            var processOptions = MeetingPostProcessOptions(preset: preset)
            if let engine { processOptions.transcribeLater = Self.transcribeLater(engine) }
            let store = MeetingStore(root: folder.deletingLastPathComponent(), options: processOptions)
            let id = folder.lastPathComponent
            let started = Date()
            try await store.process(id, log: log)
            try write(Processed(seconds: Date().timeIntervalSince(started), meeting: try await store.detail(id)))
        case "export-fixture":
            let values = try options.finish(positional: 2)
            let destination = URL(fileURLWithPath: values[1], isDirectory: true).standardizedFileURL
            let files = try await MeetingStore(root: root).exportFixture(values[0], to: destination)
            try write(Exported(destination: destination.path, files: files))
        case "simulate":
            guard let system = options.take("--system") else { throw CommandError.usage(usage) }
            let microphone = options.take("--mic")
            let echoText = options.take("--echo") ?? "0"
            guard let echo = Float(echoText), echo >= 0, echo <= 1 else { throw CommandError.usage("--echo takes a gain from 0 to 1") }
            let title = options.take("--title") ?? "Simulation"
            let preset = try options.preset()
            try options.finish(positional: 0)
            for path in [system] + (microphone.map { [$0] } ?? []) where !FileManager.default.isReadableFile(atPath: path) {
                throw CommandError.usage("Audio file not found: \(path)")
            }
            guard let engine else { throw RecordedAudioError.engineNotConfigured }
            let started = Date()
            // A simulation never lands in the real meetings library unless asked to.
            let simulationRoot = rootOption ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("goblin-meetings-\(UUID().uuidString)", isDirectory: true)
            let directory = try await MeetingSimulator.run(system: URL(fileURLWithPath: system), microphone: microphone.map { URL(fileURLWithPath: $0) },
                                                           echoGain: echo, engine: engine, recognition: recognition, title: title, root: simulationRoot, log: log)
            let live = Date().timeIntervalSince(started)
            await engine.unload()
            let store = MeetingStore(root: directory.deletingLastPathComponent(), options: MeetingPostProcessOptions(preset: preset))
            try await store.process(directory.lastPathComponent, log: log)
            try write(Simulated(liveSeconds: live, seconds: Date().timeIntervalSince(started),
                                meeting: try await store.detail(directory.lastPathComponent)))
        default:
            throw CommandError.usage(usage)
        }
    }

    /// Deferred speech, transcribed on the CLI's own engine, which the CLI unloads when it's done.
    private static func transcribeLater(_ engine: any PCMSpeechEngine) -> MeetingLateTranscriber {
        { chunks, options in try await MeetingTranscriber.transcribeAll(chunks, engine: engine, options: options) }
    }

    private struct Processed: Encodable { let seconds: Double; let meeting: MeetingDetail }
    private struct Simulated: Encodable { let liveSeconds: Double; let seconds: Double; let meeting: MeetingDetail }
    private struct Exported: Encodable { let destination: String; let files: [String] }

    private static func write<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileHandle.standardOutput.write(contentsOf: try encoder.encode(value) + Data([0x0A]))
    }

    /// Options take one value each and may appear once; whatever is left is positional.
    private struct Options {
        private var arguments: [String]

        init(_ arguments: [String]) throws { self.arguments = arguments }

        mutating func take(_ option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            return value
        }

        mutating func preset() throws -> String {
            let preset = take("--preset") ?? "offline"
            guard MeetingPostProcessOptions.presets.contains(preset) else {
                throw CommandError.usage("--preset must be one of \(MeetingPostProcessOptions.presets.joined(separator: ", "))")
            }
            return preset
        }

        mutating func flag(_ option: String) -> Bool {
            guard let index = arguments.firstIndex(of: option) else { return false }
            arguments.remove(at: index)
            return true
        }

        @discardableResult
        func finish(positional count: Int) throws -> [String] {
            if let unknown = arguments.first(where: { $0.hasPrefix("--") }) {
                throw CommandError.usage("Unknown or repeated meetings option: \(unknown)")
            }
            guard arguments.count == count else { throw CommandError.usage(MeetingsCommand.usage) }
            return arguments
        }
    }
}
