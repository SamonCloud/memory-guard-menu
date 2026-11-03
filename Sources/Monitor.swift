import AppKit
import SwiftUI
import ServiceManagement

let appIdentifier = "com.samuelzhao.memory-guard-menu"
let protectedAppIDs: Set<String> = ["com.apple.finder", "com.apple.loginwindow", "com.apple.systemuiserver"]

struct AppEntry: Identifiable {
    let pid: Int32
    let key: String
    let bundleID: String
    let bundleURL: URL
    let launchDate: Date?
    let name: String
    let icon: NSImage?
    let memory: AppMemory
    var idle: TimeInterval
    var active: Bool
    var ignored: Bool
    var candidate: Bool
    var protected: Bool { protectedAppIDs.contains(bundleID) }
    var id: String { key }
    var readable: Bool { memory.processCount > memory.unreadableCount }
}

func activityKey(_ app: NSRunningApplication) -> String {
    "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)"
}

final class Monitor: ObservableObject {
    @Published var pressure: Pressure = .unknown
    @Published var entries: [AppEntry] = []
    @Published var physical: UInt64 = 0
    @Published var compressed: UInt64?
    @Published var swap: UInt64?
    @Published var sampledAt: Date?
    @Published var scanDuration: Double = 0
    @Published var statusMessage = "正在读取系统状态…"
    @Published var sampling = false
    @Published var showAll = false
    @Published var selected = Set<String>()
    @Published var paused = false
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var feedback = ""

    @Published var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: "idleMinutes"); reevaluate() } }
    @Published var minimumMB: Int { didSet { defaults.set(minimumMB, forKey: "minimumMB"); reevaluate() } }
    @Published var holdMinutes: Int { didSet { defaults.set(holdMinutes, forKey: "holdMinutes") } }
    @Published var cooldownMinutes: Int { didSet { defaults.set(cooldownMinutes, forKey: "cooldownMinutes") } }
    @Published var remindersEnabled: Bool { didSet { defaults.set(remindersEnabled, forKey: "remindersEnabled") } }
    @Published var ignoredIDs: Set<String> { didSet { defaults.set(Array(ignoredIDs).sorted(), forKey: "ignoredIDs"); reevaluate() } }

    var onUpdate: (() -> Void)?
    var onReminder: (([AppEntry], Bool) -> Void)?
    var onSessionEnd: (() -> Void)?
    private let defaults: UserDefaults
    private var tracker = ActivityTracker()
    private var gate = ReminderGate()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private var eventPressure: Pressure = .unknown
    private var sessionAvailable = true
    private var generation = 0
    private let queue = DispatchQueue(label: "com.samuelzhao.memory-guard.sample", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func number(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key)))
        }
        idleMinutes = number("idleMinutes", 30, 1...240)
        minimumMB = number("minimumMB", 500, 1...16384)
        holdMinutes = number("holdMinutes", 2, 1...10)
        cooldownMinutes = number("cooldownMinutes", 30, 1...240)
        remindersEnabled = defaults.object(forKey: "remindersEnabled") == nil ? true : defaults.bool(forKey: "remindersEnabled")
        ignoredIDs = Set(defaults.stringArray(forKey: "ignoredIDs") ?? [])
        refreshLoginStatus()
    }

    var candidates: [AppEntry] { entries.filter(\.candidate) }
    var visibleEntries: [AppEntry] { showAll ? entries : candidates }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.tracker.activate(app.map(activityKey), now: Date())
            self.reevaluate()
        })
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sessionAvailable = false
                self.generation += 1
                self.gate.resetAfterWake()
                self.onSessionEnd?()
            })
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sessionAvailable = true
                self.tracker.reset(now: Date())
                self.eventPressure = .unknown
                self.gate.resetAfterWake()
                self.reevaluate()
                self.refresh()
            })
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let data = self.pressureSource?.data else { return }
            if data.contains(.critical) { self.eventPressure = .critical }
            else if data.contains(.warning) { self.eventPressure = .warning }
            else { self.eventPressure = .normal }
            self.refresh()
        }
        pressureSource = source
        source.resume()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 3
        refresh()
    }

    func refresh() {
        guard !sampling, sessionAvailable else { return }
        sampling = true
        let scanGeneration = generation
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !$0.isTerminated && $0.bundleURL != nil
        }
        var roots = applications.map { AppRoot(pid: $0.processIdentifier, path: $0.bundleURL!.resolvingSymlinksInPath().path) }
        if let ownURL = Bundle.main.bundleURL as URL? {
            roots.append(AppRoot(pid: ProcessInfo.processInfo.processIdentifier, path: ownURL.resolvingSymlinksInPath().path))
        }
        let samplingRoots = roots
        let appInfo = applications.map { app in
            AppEntry(pid: app.processIdentifier, key: activityKey(app), bundleID: app.bundleIdentifier ?? app.bundleURL!.path,
                     bundleURL: app.bundleURL!, launchDate: app.launchDate, name: app.localizedName ?? "未命名应用",
                     icon: app.icon, memory: AppMemory(), idle: 0, active: false, ignored: false, candidate: false)
        }
        queue.async { [weak self] in
            let start = Date()
            let system = mg_system()
            var count: Int32 = 0, unreadable: Int32 = 0
            let pointer = mg_processes(&count, &unreadable)
            var processes: [ProcessRecord] = []
            if let pointer {
                defer { mg_free_processes(pointer) }
                for i in 0..<Int(count) {
                    var process = pointer[i]
                    let path = withUnsafePointer(to: &process.path) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
                    }
                    processes.append(ProcessRecord(pid: process.pid, parent: process.parent, path: path,
                                                   bytes: process.footprint_valid != 0 ? process.footprint : nil))
                }
            }
            let grouped = groupMemory(processes: processes, roots: samplingRoots)
            let elapsed = Date().timeIntervalSince(start)
            let failed = pointer == nil || unreadable < 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.sampling = false
                guard self.generation == scanGeneration, self.sessionAvailable else { return }
                let now = Date()
                let currentKeys = Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(activityKey))
                let currentInfo = appInfo.filter { currentKeys.contains($0.key) }
                self.tracker.reconcile(keys: Set(currentInfo.map(\.key)),
                                       frontmost: NSWorkspace.shared.frontmostApplication.map(activityKey), now: now)
                let reported = Pressure(rawValue: Int(system.pressure)) ?? .unknown
                self.pressure = reported == .unknown ? self.eventPressure : reported
                self.physical = system.physical
                self.compressed = system.vm_valid != 0 ? system.compressed : nil
                self.swap = system.swap_valid != 0 ? system.swap : nil
                self.entries = currentInfo.map { app in
                    AppEntry(pid: app.pid, key: app.key, bundleID: app.bundleID, bundleURL: app.bundleURL,
                             launchDate: app.launchDate, name: app.name, icon: app.icon,
                             memory: grouped[app.pid] ?? AppMemory(), idle: 0, active: false, ignored: false, candidate: false)
                }.sorted { $0.memory.bytes > $1.memory.bytes }
                self.sampledAt = now
                self.scanDuration = elapsed
                let allUnreadable = !currentInfo.isEmpty && grouped.values.allSatisfy { $0.processCount <= $0.unreadableCount }
                self.statusMessage = failed || allUnreadable ? "无法读取应用内存；请检查系统访问限制。" :
                    (self.pressure == .unknown ? "系统暂未提供内存压力，等待系统事件。" : "每 15 秒检查一次，数据仅在本机处理。")
                self.reevaluate()
                self.gate.update(pressure: self.pressure, now: now)
                if self.gate.shouldRemind(pressure: self.pressure, candidateCount: self.candidates.count,
                                         enabled: self.remindersEnabled && !self.paused,
                                         hold: Double(self.holdMinutes) * 60,
                                         cooldown: Double(self.cooldownMinutes) * 60, now: now) {
                    self.gate.lastReminder = now
                    self.onReminder?(self.candidates, false)
                }
                self.onUpdate?()
            }
        }
    }

    func reevaluate() {
        let now = Date()
        entries = entries.map { entry in
            var entry = entry
            entry.idle = tracker.idleSeconds(key: entry.key, now: now)
            entry.active = tracker.frontmost == entry.key
            entry.ignored = ignoredIDs.contains(entry.bundleID)
            entry.candidate = isCandidate(bytes: entry.memory.bytes, idle: entry.idle,
                                          isActive: entry.active, ignored: entry.ignored || entry.protected, readable: entry.readable,
                                          minimumMB: minimumMB, idleMinutes: idleMinutes)
            return entry
        }
        selected.formIntersection(Set(candidates.map(\.key)))
        onUpdate?()
    }

    func ignore(_ entry: AppEntry) {
        if ignoredIDs.contains(entry.bundleID) { ignoredIDs.remove(entry.bundleID) }
        else { ignoredIDs.insert(entry.bundleID) }
    }

    func snooze() { gate.snoozedUntil = Date().addingTimeInterval(Double(cooldownMinutes) * 60) }

    func testReminder() { onReminder?(Array(entries.prefix(3)), true) }

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请到系统设置的登录项中允许此应用。" : ""
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginMessage = "设置未生效：\(error.localizedDescription)"
        }
    }

    func requestQuit(keys: Set<String>, confirmation: (([AppEntry]) -> Bool)? = nil) {
        reevaluate()
        let targets = candidates.filter { keys.contains($0.key) }
        guard !targets.isEmpty else { feedback = "候选状态已经变化，请刷新后重新选择。"; return }
        if let confirmation {
            guard confirmation(targets) else { return }
        } else {
            let alert = NSAlert()
            alert.messageText = "退出这 \(targets.count) 个应用？"
            alert.informativeText = targets.map { "\($0.name)：\(memoryText($0.memory.bytes))，未切到前台 \(idleText($0.idle))" }.joined(separator: "\n") +
                "\n\n将发送正常退出请求。应用可能要求保存文件；后台任务也可能停止。实际释放量以系统结果为准。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "正常退出")
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        var requested: [AppEntry] = [], skipped: [String] = []
        for target in targets {
            guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated,
                  app.bundleURL == target.bundleURL, app.launchDate == target.launchDate,
                  app.activationPolicy == .regular, !app.isActive,
                  !protectedAppIDs.contains(target.bundleID),
                  !ignoredIDs.contains(target.bundleID),
                  tracker.idleSeconds(key: target.key, now: Date()) >= Double(idleMinutes) * 60 else {
                skipped.append(target.name); continue
            }
            if app.terminate() { requested.append(target) }
            else { skipped.append(target.name) }
        }
        feedback = requested.isEmpty ? "没有发出退出请求。" : "已向 \(requested.count) 个应用发送正常退出请求。"
        if !skipped.isEmpty { feedback += "已跳过：" + skipped.joined(separator: "、") + "。" }
        selected.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let remaining = requested.filter { target in
                guard let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
                return !app.isTerminated && app.launchDate == target.launchDate
            }
            if !requested.isEmpty {
                self.feedback = "已退出 \(requested.count - remaining.count) 个应用。"
                if !remaining.isEmpty {
                    self.feedback += "\(remaining.map(\.name).joined(separator: "、")) 仍在运行，可能正在等待保存或处理后台任务。"
                }
                if !skipped.isEmpty { self.feedback += "已跳过 \(skipped.count) 个状态变化或未接受请求的应用。" }
            }
            self.refresh()
        }
    }

    func diagnostics() -> [String: Any] {
        ["pressure": pressure.title, "pressureRaw": pressure.rawValue, "physicalBytes": physical,
         "compressedBytes": compressed as Any? ?? NSNull(), "swapBytes": swap as Any? ?? NSNull(),
         "sampledAt": sampledAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
         "scanSeconds": scanDuration, "candidateCount": candidates.count,
         "trackedApps": entries.count, "status": statusMessage, "loginEnabled": loginEnabled,
         "settings": ["idleMinutes": idleMinutes, "minimumMB": minimumMB, "holdMinutes": holdMinutes,
                      "cooldownMinutes": cooldownMinutes, "remindersEnabled": remindersEnabled] as [String: Any],
         "apps": entries.map { entry in
             ["name": entry.name, "pid": entry.pid, "bundleID": entry.bundleID, "bytes": entry.memory.bytes,
              "processes": entry.memory.processCount, "unreadable": entry.memory.unreadableCount,
              "idleSeconds": entry.idle, "active": entry.active, "ignored": entry.ignored,
              "candidate": entry.candidate] as [String: Any]
         }]
    }
}
