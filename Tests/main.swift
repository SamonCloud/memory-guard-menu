import Foundation
import CoreGraphics

var count = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    count += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let base = Date(timeIntervalSince1970: 100_000)
var tracker = ActivityTracker()
tracker.reconcile(keys: ["a", "b"], frontmost: "a", now: base)
expect(tracker.idleSeconds(key: "b", now: base) == 0, "existing app starts with conservative baseline")
tracker.activate("b", now: base.addingTimeInterval(600))
expect(tracker.idleSeconds(key: "a", now: base.addingTimeInterval(610)) == 10, "count idle from leaving foreground, not entering it")
expect(tracker.idleSeconds(key: "b", now: base.addingTimeInterval(7200)) == 0, "frontmost app is never idle")
tracker.reset(now: base.addingTimeInterval(7200))
expect(tracker.idleSeconds(key: "a", now: base.addingTimeInterval(7201)) == 1, "sleep time excluded after wake")
tracker.reconcile(keys: ["b", "new-a"], frontmost: "b", now: base.addingTimeInterval(7300))
expect(tracker.lastActive["a"] == nil, "terminated app removed")
expect(tracker.idleSeconds(key: "new-a", now: base.addingTimeInterval(7300)) == 0, "PID reuse does not inherit idle")

expect(isCandidate(bytes: 500 * 1_048_576, idle: 1800, isActive: false, ignored: false, readable: true, minimumMB: 500, idleMinutes: 30), "inclusive rule boundaries")
expect(!isCandidate(bytes: 900 * 1_048_576, idle: 1799, isActive: false, ignored: false, readable: true, minimumMB: 500, idleMinutes: 30), "idle threshold")
expect(!isCandidate(bytes: 499 * 1_048_576, idle: 1801, isActive: false, ignored: false, readable: true, minimumMB: 500, idleMinutes: 30), "memory threshold")
for (active, ignored, readable) in [(true, false, true), (false, true, true), (false, false, false)] {
    expect(!isCandidate(bytes: 2_000_000_000, idle: 7200, isActive: active, ignored: ignored, readable: readable, minimumMB: 500, idleMinutes: 30), "exclude active, ignored, unreadable")
}

var gate = ReminderGate()
func ready(_ gate: ReminderGate, _ elapsed: Double, _ pressure: Pressure = .warning, _ candidates: Int = 1, _ enabled: Bool = true) -> Bool {
    gate.shouldRemind(pressure: pressure, candidateCount: candidates, enabled: enabled, hold: 120, cooldown: 1800, now: base.addingTimeInterval(elapsed))
}
gate.update(pressure: .warning, now: base)
expect(!ready(gate, 119), "short pressure spike does not alert")
expect(ready(gate, 120), "sustained warning does alert")
expect(!ready(gate, 120, .warning, 0), "no candidates does not alert")
expect(!ready(gate, 120, .warning, 1, false), "pause suppresses alert")
gate.lastReminder = base.addingTimeInterval(120)
expect(!ready(gate, 121), "cooldown suppresses duplicate")
expect(ready(gate, 1920), "cooldown expires")
gate.snoozedUntil = base.addingTimeInterval(4000)
expect(!ready(gate, 2000), "snooze suppresses reminder")
gate.update(pressure: .normal, now: base.addingTimeInterval(2100))
expect(gate.elevatedSince == nil, "normal clears sustained warning")
gate.update(pressure: .critical, now: base.addingTimeInterval(2200))
gate.resetAfterWake()
expect(gate.elevatedSince == nil, "wake restarts pressure hold")
gate.update(pressure: .unknown, now: base)
expect(!ready(gate, 5000, .unknown), "unknown never treated as elevated")

let roots = [AppRoot(pid: 10, path: "/Applications/Browser.app"), AppRoot(pid: 20, path: "/Applications/Editor.app")]
let processes = [
    ProcessRecord(pid: 10, parent: 1, path: "/Applications/Browser.app/Contents/MacOS/browser", bytes: 100),
    ProcessRecord(pid: 11, parent: 1, path: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/helper", bytes: 200),
    ProcessRecord(pid: 12, parent: 10, path: "/usr/bin/tool", bytes: 300),
    ProcessRecord(pid: 13, parent: 12, path: "/usr/bin/worker", bytes: 400),
    ProcessRecord(pid: 20, parent: 10, path: "/Applications/Editor.app/Contents/MacOS/editor", bytes: 500),
    ProcessRecord(pid: 21, parent: 20, path: "/usr/bin/compiler", bytes: nil),
    ProcessRecord(pid: 30, parent: 1, path: "/Applications/Browser.app.fake/worker", bytes: 999),
    ProcessRecord(pid: 40, parent: 41, path: "/cycle/a", bytes: 1),
    ProcessRecord(pid: 41, parent: 40, path: "/cycle/b", bytes: 1)
]
let grouped = groupMemory(processes: processes, roots: roots)
expect(grouped[10]?.bytes == 1000, "bundle helpers and descendants grouped exactly once")
expect(grouped[20]?.bytes == 500, "separate GUI app not folded into launcher")
expect(grouped[20]?.unreadableCount == 1, "unreadable process disclosed")
expect(grouped[10]?.processCount == 4, "prefix false positive excluded and cycles terminate")
expect(memoryText(1_073_741_824) == "1.0 GB", "memory formatter")
expect(idleText(3660) == "1 小时 1 分钟", "idle formatter")
for screen in [CGRect(x: 0, y: 24, width: 1440, height: 851),
               CGRect(x: 0, y: 24, width: 1024, height: 552),
               CGRect(x: -1920, y: -200, width: 1920, height: 1024),
               CGRect(x: 1440, y: 900, width: 800, height: 420)] {
    let sizing = DashboardSizing(visibleFrame: screen)
    expect(sizing.viewport.height <= screen.height - 40, "dashboard reserves vertical screen margin")
    expect(sizing.viewport.width <= screen.width - 32, "dashboard reserves horizontal screen margin")
    let overflow = CGRect(x: screen.maxX - 200, y: screen.maxY - 40, width: 480, height: 750)
    let frame = visibleWindowFrame(overflow, within: screen)
    expect(screen.contains(frame), "oversize/offscreen window clamped on short and offset monitors")
}
print("PASS: \(count) checks (activity, grouping, reminders and screen layout).")
