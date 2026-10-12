import Foundation
import GoblinCore

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
precondition(!DiagnosticFailure.rewriteHTTPStatus(Int.max).message.contains(String(Int.max)))
print("Diagnostics smoke passed: typed errors, redaction, bounded report, permissions, and stage timings.")
