import AppKit
import SwiftUI

let arguments = CommandLine.arguments
func argumentValue(_ flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func jsonData(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let monitor = Monitor()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var reviewWindow: NSWindow?
    var settingsWindow: NSWindow?
    var reminderPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if arguments.contains("--quit-running") {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier)
                where app.processIdentifier != ProcessInfo.processInfo.processIdentifier { _ = app.terminate() }
            NSApp.terminate(nil)
            return
        }
        if !arguments.contains("--status"),
           NSRunningApplication.runningApplications(withBundleIdentifier: appIdentifier).contains(where: {
               $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
           }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("内存提醒")
        }
        popover.behavior = .transient
        popover.delegate = self
        monitor.onUpdate = { [weak self] in self?.updated() }
        monitor.onReminder = { [weak self] entries, preview in self?.showReminder(entries, preview: preview) }
        monitor.onSessionEnd = { [weak self] in self?.reminderPanel?.close() }
        monitor.start()
        updated()
        if arguments.contains("--show-window") { showReview() }
    }

    func dashboard(width: CGFloat = 460, listHeight: CGFloat = 280) -> DashboardView {
        DashboardView(monitor: monitor, width: width, listHeight: listHeight,
                      openSettings: { [weak self] in self?.showSettings() }, quitTargets: { [weak self] keys in
            guard let self else { return }
            self.popover.performClose(nil)
            self.showReview()
            self.monitor.requestQuit(keys: keys)
        })
    }

    var menuScreen: NSScreen? { statusItem.button?.window?.screen ?? NSScreen.main }

    func boundedDashboard(on screen: NSScreen?) -> NSHostingController<DashboardViewport> {
        let sizing = DashboardSizing(visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768))
        let controller = NSHostingController(rootView: DashboardViewport(
            dashboard: dashboard(width: sizing.viewport.width, listHeight: sizing.listHeight), size: sizing.viewport))
        // SwiftUI's intrinsic height must not resize a menu-bar popover as its
        // rows change: AppKit can otherwise move the top off the screen.
        controller.sizingOptions = []
        controller.preferredContentSize = sizing.viewport
        controller.view.setFrameSize(sizing.viewport)
        return controller
    }

    func keepVisible(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { return }
        let frame = visibleWindowFrame(window.frame, within: screen.visibleFrame)
        if !window.frame.equalTo(frame) { window.setFrame(frame, display: true) }
    }

    func popoverDidShow(_ notification: Notification) {
        if let window = popover.contentViewController?.view.window { keepVisible(window, on: menuScreen) }
        updated()
    }

    func updated() {
        let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "内存压力\(monitor.pressure.title)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = monitor.pressure == .critical ? .systemRed : (monitor.pressure == .warning ? .systemOrange : nil)
        statusItem.button?.title = monitor.paused ? " 暂停" : (monitor.pressure.elevated && !monitor.candidates.isEmpty ? " \(monitor.candidates.count)" : "")
        statusItem.button?.toolTip = "内存压力\(monitor.pressure.title) · \(monitor.candidates.count) 个候选应用"
        guard monitor.sampledAt != nil else { return }
        if let path = argumentValue("--diagnostics"), var diagnostics = Optional(monitor.diagnostics()) {
            diagnostics["statusItemVisible"] = statusItem.isVisible
            diagnostics["popoverShown"] = popover.isShown
            diagnostics["reviewWindowVisible"] = reviewWindow?.isVisible ?? false
            diagnostics["reminderVisible"] = reminderPanel?.isVisible ?? false
            if let window = reviewWindow, window.isVisible, let screen = window.screen ?? menuScreen {
                diagnostics["reviewFrame"] = NSStringFromRect(window.frame)
                diagnostics["screenVisibleFrame"] = NSStringFromRect(screen.visibleFrame)
                diagnostics["reviewFullyVisible"] = screen.visibleFrame.contains(window.frame)
            }
            if let window = popover.contentViewController?.view.window, popover.isShown,
               let screen = menuScreen {
                diagnostics["popoverFrame"] = NSStringFromRect(window.frame)
                diagnostics["screenVisibleFrame"] = NSStringFromRect(screen.visibleFrame)
                diagnostics["popoverFullyVisible"] = screen.visibleFrame.contains(window.frame)
            }
            if let data = jsonData(diagnostics) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        }
        if arguments.contains("--status") {
            if let data = jsonData(monitor.diagnostics()) { FileHandle.standardOutput.write(data); print("") }
            NSApp.terminate(nil)
        }
        if let directory = argumentValue("--render-preview") {
            renderPreviews(directory)
            NSApp.terminate(nil)
        }
    }

    @objc func togglePopover() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            let show = menu.addItem(withTitle: "查看内存与应用…", action: #selector(showReviewAction), keyEquivalent: "")
            show.target = self
            let settings = menu.addItem(withTitle: "设置…", action: #selector(showSettingsAction), keyEquivalent: "")
            settings.target = self
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "退出内存提醒", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        monitor.refresh()
        if let button = statusItem.button {
            let controller = boundedDashboard(on: menuScreen)
            popover.contentViewController = controller
            popover.contentSize = controller.preferredContentSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showReviewAction() { showReview() }
    @objc func showSettingsAction() { showSettings() }

    func showReview() {
        reminderPanel?.close()
        popover.performClose(nil)
        if reviewWindow == nil {
            let controller = boundedDashboard(on: menuScreen)
            let window = NSWindow(contentViewController: controller)
            window.title = "内存提醒"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MemoryGuardReview")
            window.center()
            reviewWindow = window
        }
        if let window = reviewWindow { keepVisible(window, on: window.screen ?? menuScreen) }
        reviewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        monitor.refresh()
        updated()
    }

    func showSettings() {
        popover.performClose(nil)
        monitor.refreshLoginStatus()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(monitor: monitor)))
            window.title = "内存提醒设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showReminder(_ entries: [AppEntry], preview: Bool) {
        reminderPanel?.close()
        let view = ReminderView(entries: entries, preview: preview, pressure: monitor.pressure,
                                review: { [weak self] in self?.showReview() },
                                later: { [weak self] in
                                    if !preview { self?.monitor.snooze() }
                                    self?.reminderPanel?.close()
                                })
        let controller = NSHostingController(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.title = preview ? "内存提醒 · 预览" : "内存提醒"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        let size = controller.view.fittingSize
        panel.setContentSize(size)
        if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - panel.frame.height - 16))
        }
        reminderPanel = panel
        panel.orderFrontRegardless()
        updated()
    }

    func renderPreviews(_ directory: String) {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Preview uses current read-only data and never changes persisted rules.
        monitor.showAll = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (suffix, screenFrame) in [("", CGRect(x: 0, y: 0, width: 1440, height: 850)),
                                          ("-compact", CGRect(x: 0, y: 0, width: 1024, height: 552))] {
                let sizing = DashboardSizing(visibleFrame: screenFrame)
                let viewport = DashboardViewport(dashboard: dashboard(width: sizing.viewport.width, listHeight: sizing.listHeight),
                                                 size: sizing.viewport)
                render(view: viewport, size: sizing.viewport, appearance: appearance,
                       path: url.appendingPathComponent("dashboard\(suffix)-\(name).png"))
            }
            render(view: SettingsView(monitor: monitor), size: NSSize(width: 510, height: 630), appearance: appearance,
                   path: url.appendingPathComponent("settings-\(name).png"))
            render(view: ReminderView(entries: Array(monitor.entries.prefix(3)), preview: true, pressure: monitor.pressure,
                                     review: {}, later: {}), size: NSSize(width: 360, height: 270), appearance: appearance,
                   path: url.appendingPathComponent("reminder-\(name).png"))
        }
    }

    func render<V: View>(view: V, size: NSSize, appearance: NSAppearance.Name, path: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: path) }
        window.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showReview()
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
