import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Exercise a real process with a small, bounded allocation.
        let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: 4 * 1024 * 1024)
        allocation.initialize(repeating: 1, count: 4 * 1024 * 1024)
        Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in NSApp.terminate(nil) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let index = CommandLine.arguments.firstIndex(of: "--quit-log"), index + 1 < CommandLine.arguments.count {
            try? "normal termination received".write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        }
        return .terminateNow
    }
}
let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
