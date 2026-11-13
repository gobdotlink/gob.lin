import Foundation
import Darwin
import GoblinCore


// A console-only persistence reproduction; it never starts audio or reads TCC grants.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-writer" {
    let log = DevelopmentLog(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    let operation = UUID()
    log.record(.appStarted, area: .application)
    var selection = DevelopmentDetails(reason: .savedDevice)
    selection.selectedDevice = log.deviceID("private-device-uid")
    log.record(.previewRequested, area: .microphone, operation: operation, details: selection)
    selection.reason = .deviceUnavailable
    log.record(.deviceFallback, area: .microphone, severity: .warning, operation: operation, details: selection)
    var resolved = DevelopmentDetails(); resolved.resolvedDevice = log.deviceID("default-private-uid"); resolved.osStatus = 0
    log.record(.deviceResolved, area: .microphone, operation: operation, details: resolved)
    var format = DevelopmentDetails(); format.channelCount = 2; format.sampleRate = 48_000
    log.record(.inputFormat, area: .microphone, operation: operation, details: format)
    log.record(.tapInstalled, area: .microphone, operation: operation)
    log.record(.engineStarted, area: .microphone, operation: operation)
    log.record(.firstBuffer, area: .microphone, operation: operation)
    log.record(.configurationChanged, area: .microphone, severity: .warning, operation: operation)
    var failure = DevelopmentDetails(reason: .configurationChanged)
    failure.underlyingError = NSError(domain: "private-error-domain", code: -50, userInfo: [NSLocalizedDescriptionKey: "private dictated text", NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10868)])
    log.record(.previewFailed, area: .microphone, severity: .error, operation: operation, details: failure)
    log.record(.previewStopped, area: .microphone, operation: operation, details: DevelopmentDetails(reason: .configurationChanged))
    try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
    raise(SIGSTOP)
    exit(1)
}

let sensitive = "secret-provider-key /Users/private/transcript.txt confidential dictated words"
let failure = DiagnosticFailure.rewrite(.configuration(sensitive))
let environment = DiagnosticEnvironment(microphonePermission: .granted,
    accessibilityPermission: .denied, inputMonitoringPermission: .granted,
    microphoneNames: ["Private device name"], defaultMicrophoneName: "Private device name")
let events = (0..<80).map { index in
    DiagnosticEvent(failure: .rewriteHTTPStatus(400 + index), date: Date(timeIntervalSince1970: Double(index)))
}
let timings = DictationTimings(captureMilliseconds: 1000, trimMilliseconds: 12, asrMilliseconds: 200,
    rewriteMilliseconds: .nan, insertionMilliseconds: -.infinity)
let report = DiagnosticsReport.render(environment: environment, activeFailures: [failure], events: events, timings: timings)
precondition(!report.contains(sensitive) && !report.contains("secret-provider-key") && !report.contains("/Users/"))
precondition(!report.contains("Private device name"))
precondition(report.contains("polish failed — pasted raw"))
precondition(report.contains("Accessibility permission: denied"))
precondition(report.contains("ASR: 200.0 ms") && report.contains("Rewrite: unavailable") && report.contains("Insert: unavailable"))
precondition(report.components(separatedBy: "\n").filter { $0.hasPrefix("1970-") }.count == 50)
let withNames = DiagnosticsReport.render(environment: environment, activeFailures: [], events: [], timings: nil, includeDeviceNames: true)
precondition(withNames.contains("Microphone: Private device name"))
precondition(report.contains("History sync: unavailable in this build"))
var syncing = environment
syncing.historySync = .waitingForAccount
precondition(DiagnosticsReport.render(environment: syncing, activeFailures: [], events: [], timings: nil).contains("History sync: waitingForAccount"))
precondition(!DiagnosticFailure.rewriteHTTPStatus(Int.max).message.contains(String(Int.max)))
print("Diagnostics smoke passed: typed errors, redaction, bounded report, permissions, and stage timings.")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goblin-log-probe-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
process.arguments = ["--crash-writer", directory.path]
let pipe = Pipe(); process.standardOutput = pipe
try process.run()
let ready = try pipe.fileHandleForReading.read(upToCount: 6)
precondition(ready == Data("ready\n".utf8))
precondition(kill(process.processIdentifier, SIGKILL) == 0)
process.waitUntilExit()
precondition(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL)
let relaunched = DevelopmentLog(directory: directory)
precondition(relaunched.record(.appStarted, area: .application))
let trail = try relaunched.recentText()
let records = try trail.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
precondition(records.map { $0["event"] as! String } == ["appStarted", "previewRequested", "deviceFallback", "deviceResolved", "inputFormat", "tapInstalled", "engineStarted", "firstBuffer", "configurationChanged", "previewFailed", "previewStopped", "appStarted"])
precondition(Set(records.map { $0["launchID"] as! String }).count == 2)
precondition(Set(records.dropFirst().dropLast().map { $0["operationID"] as! String }).count == 1)
precondition(!trail.contains("private-") && !trail.contains("private dictated text"))
let identity = records.last!["build"] as! [String: Any]
precondition((identity["sourceRevision"] as! String).count == 40 && UUID(uuidString: identity["buildID"] as! String) != nil)
precondition((records[9]["details"] as! [String: Any])["errors"] != nil)
let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events.jsonl").path)[.posixPermissions] as! NSNumber
precondition(mode.intValue == 0o600)
let lockMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("events.lock").path)[.posixPermissions] as! NSNumber
precondition(lockMode.intValue == 0o600)
let sameLaunch = relaunched.deviceID("private-device-uid")
var tokens = DevelopmentDetails(); tokens.selectedDevice = sameLaunch; tokens.resolvedDevice = relaunched.deviceID("private-device-uid")
precondition(relaunched.record(.deviceResolved, area: .microphone, details: tokens))
let tokenRecord = try JSONSerialization.jsonObject(with: Data((try relaunched.recentText()).split(separator: "\n").last!.utf8)) as! [String: Any]
let fields = tokenRecord["details"] as! [String: Any]
precondition(fields["selectedDevice"] as! String == fields["resolvedDevice"] as! String)
precondition(fields["selectedDevice"] as! String != (records[1]["details"] as! [String: Any])["selectedDevice"] as! String)
let current = directory.appendingPathComponent("events.jsonl")
let torn = try FileHandle(forWritingTo: current)
try torn.seekToEnd(); try torn.write(contentsOf: Data("{incomplete".utf8)); try torn.close()
precondition(relaunched.record(.appStopped, area: .application))
let repaired = try relaunched.recentText()
precondition(!repaired.contains("incomplete"))

let rotating = DevelopmentLog(directory: directory.appendingPathComponent("rotation"), maximumFileBytes: 4096)
for _ in 0..<40 { precondition(rotating.record(.appStarted, area: .application)) }
let files = try FileManager.default.contentsOfDirectory(at: rotating.directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "jsonl" }
precondition(files.count == DevelopmentLog.fileCount)
for file in files {
    let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    precondition(bytes <= 4096)
}
let rotated = try rotating.recentText()
precondition(rotated.utf8.count <= 4096 * DevelopmentLog.fileCount)
let sequences = try rotated.split(separator: "\n").map { (try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["sequence"] as! Int }
precondition(sequences == sequences.sorted() && sequences.last == 40 && sequences.first! > 1)
// Reproduce a rotation interrupted after archive 1 moved to archive 2.
let archive1 = rotating.directory.appendingPathComponent("events.1.jsonl")
let archive2 = rotating.directory.appendingPathComponent("events.2.jsonl")
try FileManager.default.removeItem(at: archive2)
try FileManager.default.moveItem(at: archive1, to: archive2)
let retainedArchive = try Data(contentsOf: archive2)
let fullEvent = String(rotated.split(separator: "\n").last!)
try (fullEvent + String(repeating: " ", count: 4095 - fullEvent.utf8.count) + "\n")
    .write(to: rotating.directory.appendingPathComponent("events.jsonl"), atomically: false, encoding: .utf8)
precondition(rotating.record(.appStarted, area: .application))
precondition(FileManager.default.fileExists(atPath: archive1.path))
let recoveredArchive = try Data(contentsOf: archive2)
precondition(recoveredArchive == retainedArchive)
let blocked = directory.appendingPathComponent("blocked")
try Data().write(to: blocked)
let unwritable = DevelopmentLog(directory: blocked)
precondition(!unwritable.record(.appStarted, area: .application) && unwritable.lastError != nil)
if let index = CommandLine.arguments.firstIndex(of: "--evidence"), CommandLine.arguments.count > index + 1 {
    let evidence = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    try ("Synthetic console lifecycle reproduction, SIGKILL then relaunch. No hardware/TCC assertions.\n" + trail).write(to: evidence.appendingPathComponent("persistence-trail.txt"), atomically: true, encoding: .utf8)
}
print("Development log probe passed: SIGKILL/relaunch trail, correlation/build identity, UID/error redaction, private files, torn-write recovery, rotation bound/interruption recovery, and visible I/O failure.")
