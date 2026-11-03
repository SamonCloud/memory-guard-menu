import Foundation
import CoreGraphics

struct DashboardSizing {
    let viewport: CGSize
    let listHeight: CGFloat

    init(visibleFrame: CGRect) {
        // Reserve space for the popover arrow, window chrome and screen edges.
        viewport = CGSize(width: min(460, max(1, visibleFrame.width - 32)),
                          height: min(620, max(1, visibleFrame.height - 40)))
        listHeight = min(280, max(96, viewport.height - 350))
    }
}

func visibleWindowFrame(_ proposed: CGRect, within visibleFrame: CGRect) -> CGRect {
    let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
    let size = CGSize(width: min(proposed.width, bounds.width), height: min(proposed.height, bounds.height))
    return CGRect(x: min(max(proposed.minX, bounds.minX), bounds.maxX - size.width),
                  y: min(max(proposed.minY, bounds.minY), bounds.maxY - size.height),
                  width: size.width, height: size.height)
}

enum Pressure: Int, Codable {
    case unknown = -1, normal = 1, warning = 2, critical = 4
    var elevated: Bool { self == .warning || self == .critical }
    var title: String {
        switch self {
        case .unknown: return "暂不可读"
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "严重"
        }
    }
}

struct ProcessRecord {
    let pid: Int32
    let parent: Int32
    let path: String
    let bytes: UInt64?
}

struct AppRoot {
    let pid: Int32
    let path: String
}

struct AppMemory {
    var bytes: UInt64 = 0
    var processCount = 0
    var unreadableCount = 0
}

// Bundle ownership takes precedence over ancestry: a separately opened app is
// never folded into the application that launched it. Every PID is counted once.
func groupMemory(processes: [ProcessRecord], roots: [AppRoot]) -> [Int32: AppMemory] {
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    let rootPIDs = Set(roots.map(\.pid))
    let sortedRoots = roots.sorted { $0.path.count > $1.path.count }
    var result = Dictionary(roots.map { ($0.pid, AppMemory()) }, uniquingKeysWith: { first, _ in first })
    for process in processes {
        var owner: Int32?
        if rootPIDs.contains(process.pid) {
            owner = process.pid
        } else if let root = sortedRoots.first(where: { process.path.hasPrefix($0.path + "/") }) {
            owner = root.pid
        } else {
            var parent = process.parent
            var visited = Set<Int32>()
            while parent > 1 && visited.insert(parent).inserted {
                if rootPIDs.contains(parent) { owner = parent; break }
                guard let entry = byPID[parent] else { break }
                parent = entry.parent
            }
        }
        if let owner {
            result[owner, default: AppMemory()].processCount += 1
            if let bytes = process.bytes { result[owner, default: AppMemory()].bytes += bytes }
            else { result[owner, default: AppMemory()].unreadableCount += 1 }
        }
    }
    return result
}

struct ActivityTracker {
    private(set) var lastActive: [String: Date] = [:]
    private(set) var frontmost: String?

    mutating func reconcile(keys: Set<String>, frontmost key: String?, now: Date) {
        lastActive = lastActive.filter { keys.contains($0.key) }
        for key in keys where lastActive[key] == nil { lastActive[key] = now }
        activate(key, now: now)
    }

    mutating func activate(_ key: String?, now: Date) {
        if let old = frontmost { lastActive[old] = now }
        frontmost = key
        if let key { lastActive[key] = now }
    }

    mutating func reset(now: Date) {
        for key in Array(lastActive.keys) { lastActive[key] = now }
    }

    func idleSeconds(key: String, now: Date) -> TimeInterval {
        if key == frontmost { return 0 }
        return max(0, now.timeIntervalSince(lastActive[key] ?? now))
    }
}

struct ReminderGate {
    var elevatedSince: Date?
    var lastReminder: Date?
    var snoozedUntil: Date?

    mutating func update(pressure: Pressure, now: Date) {
        if pressure.elevated {
            if elevatedSince == nil { elevatedSince = now }
        } else { elevatedSince = nil }
    }

    func shouldRemind(pressure: Pressure, candidateCount: Int, enabled: Bool,
                      hold: TimeInterval, cooldown: TimeInterval, now: Date) -> Bool {
        guard enabled, pressure.elevated, candidateCount > 0, let since = elevatedSince,
              now.timeIntervalSince(since) >= hold else { return false }
        if let until = snoozedUntil, now < until { return false }
        if let previous = lastReminder, now.timeIntervalSince(previous) < cooldown { return false }
        return true
    }

    mutating func resetAfterWake() { elevatedSince = nil }
}

func isCandidate(bytes: UInt64, idle: TimeInterval, isActive: Bool, ignored: Bool,
                 readable: Bool, minimumMB: Int, idleMinutes: Int) -> Bool {
    readable && !isActive && !ignored && bytes >= UInt64(minimumMB) * 1_048_576 &&
        idle >= Double(idleMinutes) * 60
}

func memoryText(_ bytes: UInt64) -> String {
    if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    return "\(Int(bytes / 1_048_576)) MB"
}

func idleText(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    if minutes < 1 { return "不足 1 分钟" }
    if minutes < 60 { return "\(minutes) 分钟" }
    return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
}
