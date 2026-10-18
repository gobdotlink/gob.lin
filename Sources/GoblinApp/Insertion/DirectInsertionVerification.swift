import Foundation

@MainActor
enum DirectInsertionVerification {
    // An accepted AX write can be a no-op; observe the editor before reporting success.
    static func wait<Value: Equatable>(expected: Value, readValue: () -> Value?, isSafe: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
            guard isSafe() else { return false }
            let observed = readValue()
            guard isSafe(), !Task.isCancelled else { return false }
            if observed == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}
