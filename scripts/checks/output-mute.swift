import Foundation

private final class Output {
    var routes: Set<Int> = [1]
    var values: [Int: Bool] = [1: false, 2: false]
    var failedWrites: Set<Int> = []
    var writes: [(Int, Bool)] = []
    func lease() -> OutputMuteLease<Int> {
        OutputMuteLease(controls: { self.routes }, read: { self.values[$0] }, write: { control, muted in
            guard !self.failedWrites.contains(control) else { return false }
            self.writes.append((control, muted)); self.values[control] = muted
            return true
        })
    }
}

@main
struct OutputMuteChecks {
    static func main() {
        if CommandLine.arguments.contains("--helper") { runOutputMuteHelper(); return }
        do {
            let output = Output(); var lease = output.lease()
            lease.update(); lease.update()
            precondition(output.values[1] == true && output.writes.count == 1)
            precondition(lease.finish() && lease.finish())
            precondition(output.values[1] == false && output.writes.count == 2)
        }
        do {
            let output = Output(); output.values[1] = true
            var lease = output.lease(); lease.update(); lease.finish()
            precondition(output.values[1] == true && output.writes.isEmpty, "Preserve an existing mute")
        }
        do {
            let output = Output(); output.values[1] = nil
            var lease = output.lease(); lease.update(); lease.finish()
            precondition(output.writes.isEmpty, "Unknown state must not be changed")
        }
        do {
            let output = Output(); output.failedWrites = [1]
            var lease = output.lease(); lease.update(); output.failedWrites = []; lease.finish()
            precondition(output.writes.isEmpty, "A failed mute must not acquire ownership")
        }
        do {
            let output = Output(); var lease = output.lease(); lease.update()
            output.values[1] = false; lease.update()
            output.values[1] = true; lease.update(); lease.finish()
            precondition(output.values[1] == true && output.writes.count == 1, "Respect user unmute and subsequent mute")
        }
        do {
            let output = Output(); var lease = output.lease(); lease.update()
            output.routes = [2]; lease.update()
            precondition(output.values[1] == false && output.values[2] == true, "Restore the old route and mute the new one")
            lease.finish(); precondition(output.values[2] == false)
        }
        do {
            let output = Output(); output.routes = [1, 2]; output.values[2] = true
            var lease = output.lease(); lease.update(); lease.finish()
            precondition(output.values[1] == false && output.values[2] == true, "Preserve a separately muted sound-effects route")
        }
        do {
            let output = Output(); var lease = output.lease(); lease.update()
            output.values[1] = nil; output.routes = []; lease.update()
            precondition(!lease.finish(), "Retain ownership through a transient unavailable control")
            output.values[1] = true
            precondition(lease.finish() && output.values[1] == false)
        }
        do {
            let output = Output(); var lease = output.lease(); lease.update()
            output.failedWrites = [1]; precondition(!lease.finish())
            output.failedWrites = []; precondition(lease.finish() && output.values[1] == false)
        }
        print("Output mute checks passed: restore, initial mute, unreadable state, failed writes, user override, route switch, separate outputs, retry, duplicate finish.")
    }
}
