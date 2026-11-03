import AppKit

let fixtureID = "com.samuelzhao.memory-guard-fixture"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let suite = "com.samuelzhao.memory-guard-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
let monitor = Monitor(defaults: defaults)
// Accelerate only this isolated test configuration, never the user's settings.
monitor.idleMinutes = 0
monitor.minimumMB = 1
monitor.remindersEnabled = false
let log = directory.appendingPathComponent("fixture-quit.log")
try? FileManager.default.removeItem(at: log)
var checks = 0
var fixture: NSRunningApplication?

func finish(_ code: Int32) -> Never {
    defaults.removePersistentDomain(forName: suite)
    if let fixture, fixture.bundleIdentifier == fixtureID, !fixture.isTerminated { _ = fixture.terminate() }
    exit(code)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); finish(1) }
}

let config = NSWorkspace.OpenConfiguration()
config.activates = false
config.arguments = ["--quit-log", log.path]
NSWorkspace.shared.openApplication(at: directory.appendingPathComponent("MemoryGuardFixture.app"), configuration: config) { running, error in
    DispatchQueue.main.async {
        guard let running, running.bundleIdentifier == fixtureID else {
            fputs("Fixture launch failed: \(String(describing: error))\n", stderr); finish(1)
        }
        fixture = running
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            monitor.onUpdate = {
                guard monitor.sampledAt != nil else { return }
                monitor.onUpdate = nil
                guard let entry = monitor.entries.first(where: { $0.bundleID == fixtureID }) else {
                    fputs("Fixture not found in live app inventory\n", stderr); finish(1)
                }
                expect(entry.memory.bytes > 0 && entry.memory.processCount > 0, "real footprint read")
                expect(entry.candidate, "isolated test app becomes candidate")
                var confirmations = 0
                monitor.requestQuit(keys: [entry.key], confirmation: { _ in confirmations += 1; return false })
                expect(confirmations == 1 && !running.isTerminated, "cancel does not terminate")
                monitor.ignore(entry)
                monitor.requestQuit(keys: [entry.key], confirmation: { _ in confirmations += 1; return true })
                expect(confirmations == 1 && !running.isTerminated, "ignored app never reaches confirmation")
                monitor.ignore(entry)
                monitor.requestQuit(keys: [entry.key], confirmation: { _ in
                    monitor.ignore(entry)
                    return true
                })
                expect(!running.isTerminated && !FileManager.default.fileExists(atPath: log.path), "state rechecked after confirmation")
                monitor.ignore(entry)
                monitor.requestQuit(keys: [entry.key], confirmation: { _ in true })
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    expect(running.isTerminated, "normal request actually exits fixture")
                    expect((try? String(contentsOf: log, encoding: .utf8)) == "normal termination received", "fixture receives normal AppKit quit lifecycle")
                    expect(monitor.feedback.contains("已退出 1 个应用"), "actual result reported")
                    print("PASS: \(checks) live integration checks; only the disposable fixture was quit.")
                    finish(0)
                }
            }
            monitor.start()
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    fputs("Integration test timed out\n", stderr)
    finish(1)
}
app.run()
