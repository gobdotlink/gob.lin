import Foundation
import GoblinCore
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
           goblin meetings notes <id> [--tool codex|claude] [--notes-model <id>] [--thinking <level>] [--template <id>]
             [--style concise|detailed] [--out <file>] [--print-prompt] [--dictionary <file>] [--root <dir>] [--verbose]
           goblin meetings notes-tools
      notes writes notes.json into the meeting, or only to --out when given; --print-prompt sends nothing.
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
        let rootOption = try options.take("--root").map { URL(fileURLWithPath: $0, isDirectory: true) }
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
            guard let system = try options.take("--system") else { throw CommandError.usage(usage) }
            let microphone = try options.take("--mic")
            let echoText = try options.take("--echo") ?? "0"
            guard let echo = Float(echoText), echo >= 0, echo <= 1 else { throw CommandError.usage("--echo takes a gain from 0 to 1") }
            let title = try options.take("--title") ?? "Simulation"
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
        case "notes":
            let toolName = try options.take("--tool") ?? "codex"
            guard let tool = NotesTool.allCases.first(where: { $0.rawValue == toolName || $0.command == toolName }) else {
                throw CommandError.usage("--tool takes codex or claude")
            }
            let model = try options.take("--notes-model"), effort = try options.take("--thinking")
            let templateID = try options.take("--template") ?? NotesTemplate.auto.id
            guard let template = NotesTemplate.builtIns.first(where: { $0.id == templateID }) else {
                throw CommandError.usage("--template takes " + NotesTemplate.builtIns.map(\.id).joined(separator: ", "))
            }
            guard let style = NotesStyle(rawValue: try options.take("--style") ?? NotesStyle.concise.rawValue) else {
                throw CommandError.usage("--style takes concise or detailed")
            }
            let out = try options.take("--out")
            // The Markdown goes beside the JSON, so they need different names.
            if let out, URL(fileURLWithPath: out).pathExtension.lowercased() == "md" {
                throw CommandError.usage("--out takes a .json file; the Markdown is written beside it.")
            }
            let dictionaryPath = try options.take("--dictionary")
            let printPrompt = options.flag("--print-prompt")
            let id = try options.finish(positional: 1)[0]
            let directory = try await MeetingStore(root: root).directory(for: id)
            // Drafts go somewhere else: inside any meeting's folder they could replace its transcript.
            // The meeting's own folder too, which may be a link to somewhere outside the meetings folder.
            if let out {
                // Every meeting's folder as it resolves, since any of them may be a link to elsewhere.
                let meetings = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                let folders = ([root, directory] + meetings).map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
                let destination = URL(fileURLWithPath: out).deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
                if folders.contains(where: { destination.hasPrefix($0) }) {
                    throw CommandError.usage("--out must be outside the meetings folder.")
                }
            }
            let repository = dictionaryPath.map { DictionaryRepository(url: URL(fileURLWithPath: $0)) } ?? .applicationDefault
            if let dictionaryPath, !FileManager.default.fileExists(atPath: dictionaryPath) {
                throw CommandError.usage("No dictionary at \(dictionaryPath).")
            }
            // A dictionary asked for by name must load; the app's own may simply not exist yet.
            let vocabulary = (dictionaryPath == nil ? ((try? repository.load()) ?? []) : try repository.load()).map(\.spelling)
            let settings = NotesSettings(tool: tool, model: model, effort: effort, template: template, style: style)
            if printPrompt {
                let prepared = try MeetingNotesWriter.prepare(directory: directory, settings: settings, vocabulary: vocabulary)
                FileHandle.standardOutput.write(Data((prepared.model.instructions + "\n\n----- input -----\n" + prepared.input.text + "\n").utf8))
                return
            }
            guard let install = await NotesTools.find(tool) else { throw MeetingNotesError.notInstalled(tool) }
            guard install.signedIn else { throw MeetingNotesError.signedOut(tool) }
            let runner = NotesTools.runner(install)
            if let out {
                let draft = try await MeetingNotesWriter.draft(directory: directory, settings: settings, vocabulary: vocabulary, runner: runner, log: log)
                // As the meeting page would show it: the person's saved spelling decisions kept, fixes applied.
                let notes = MeetingNotesWriter.withSavedDecisions(draft, directory: directory).corrected
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(notes).write(to: URL(fileURLWithPath: out), options: .atomic)
                let markdownURL = URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("md")
                try MeetingNotesFile.markdown(notes, title: MeetingTitles.display(directory: directory, generated: notes.title),
                                              names: MeetingNotesFile.names(for: notes, directory: directory))
                    .write(to: markdownURL, atomically: true, encoding: .utf8)
                try write(DraftWritten(path: out, markdown: markdownURL.path, seconds: notes.written.seconds))
            } else {
                try write(try await MeetingStore(root: root).writeNotes(id, settings: settings, vocabulary: vocabulary, runner: runner, log: log))
            }
        case "notes-tools":
            try options.finish(positional: 0)
            var found: [FoundTool] = []
            for tool in NotesTool.allCases {
                guard let install = await NotesTools.find(tool) else { continue }
                // A tool that's signed in but can't list its models is an error, not an empty list.
                let models = install.signedIn ? try await NotesTools.models(install) : []
                found.append(FoundTool(tool: tool, executable: install.executable.path, version: install.version, signedIn: install.signedIn,
                                       signIn: install.signIn, models: models))
            }
            let available = Dictionary(found.filter(\.signedIn).map { ($0.tool, $0.models) }, uniquingKeysWith: { first, _ in first })
            try write(ToolsFound(tools: found, pick: NotesModelRanking.best(available: available)))
        default:
            throw CommandError.usage(usage)
        }
    }

    private struct DraftWritten: Encodable { let path: String; let markdown: String; let seconds: Double }
    private struct FoundTool: Encodable {
        let tool: NotesTool; let executable: String; let version: String?; let signedIn: Bool; let signIn: String?; let models: [NotesModelOption]
    }
    private struct ToolsFound: Encodable { let tools: [FoundTool]; let pick: NotesSettings? }

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

        /// The option's value. An option at the end, or followed by another option ("--out --print-prompt"), has
        /// none, and that's an error rather than taking the next option as its value.
        mutating func take(_ option: String) throws -> String? {
            guard let index = arguments.firstIndex(of: option) else { return nil }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CommandError.usage("\(option) needs a value.")
            }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            return value
        }

        mutating func preset() throws -> String {
            let preset = try take("--preset") ?? "offline"
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
