import AppKit
import SwiftUI
import ServiceManagement

extension Pressure {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

struct DashboardView: View {
    @ObservedObject var monitor: Monitor
    var width: CGFloat = 460
    var listHeight: CGFloat = 280
    var openSettings: () -> Void
    var quitTargets: (Set<String>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("内存提醒", systemImage: "memorychip").font(.title3.weight(.semibold))
                Spacer()
                Button(action: { monitor.refresh() }) { Image(systemName: "arrow.clockwise") }
                    .help("立即刷新").disabled(monitor.sampling)
                Button(action: openSettings) { Image(systemName: "gearshape") }.help("设置")
            }.buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("内存压力").foregroundStyle(.secondary)
                    Spacer()
                    Circle().fill(monitor.pressure.color).frame(width: 9, height: 9)
                    Text(monitor.pressure.title).font(.title2.weight(.semibold))
                }
                Divider()
                HStack {
                    metric("物理内存", memoryText(monitor.physical))
                    Spacer()
                    metric("压缩内存", monitor.compressed.map(memoryText) ?? "暂不可读")
                    Spacer()
                    metric("交换空间", monitor.swap.map(memoryText) ?? "暂不可读")
                }
            }
            .padding(16)
            .background(monitor.pressure.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text("建议退出 \(monitor.candidates.count) 个应用").font(.headline)
                Spacer()
                Toggle("显示全部", isOn: $monitor.showAll).toggleStyle(.checkbox).font(.caption)
            }
            Text("未切到前台 ≥ \(monitor.idleMinutes) 分钟 · 内存 ≥ \(monitor.minimumMB) MB")
                .font(.caption).foregroundStyle(.secondary).padding(.top, -10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if monitor.visibleEntries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                            Text("目前没有符合条件的应用").font(.headline)
                            Text("从本工具启动后开始记录；唤醒后重新计时。\n需要查看内存占用时，可以勾选“显示全部”。")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(monitor.visibleEntries) { entry in
                        appRow(entry)
                    }
                }.padding(.horizontal, 1)
            }.frame(height: listHeight)

            if !monitor.feedback.isEmpty {
                Text(monitor.feedback).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !monitor.candidates.isEmpty {
                    Button(monitor.selected.count == monitor.candidates.count ? "取消选择" : "全选候选") {
                        monitor.selected = monitor.selected.count == monitor.candidates.count ? [] : Set(monitor.candidates.map(\.key))
                    }
                }
                Spacer()
                Button("退出所选（\(monitor.selected.count)）…") { quitTargets(monitor.selected) }
                    .buttonStyle(.borderedProminent).disabled(monitor.selected.isEmpty)
            }

            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.statusMessage)
                    if let date = monitor.sampledAt {
                        Text("更新于 \(date.formatted(date: .omitted, time: .standard)) · 未切到前台的应用仍可能在后台工作。")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button(monitor.paused ? "恢复自动提醒" : "暂停自动提醒") { monitor.paused.toggle() }
                    Button("预览提醒（不会退出应用）") { monitor.testReminder() }
                    Divider()
                    Button("退出内存提醒") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("更多操作")
            }
            if monitor.paused { Text("自动提醒已暂停，重新打开应用后恢复。").font(.caption).foregroundStyle(.orange) }
        }
        .padding(20).frame(width: width).background(Color(nsColor: .windowBackgroundColor))
    }

    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
        }
    }

    func appRow(_ entry: AppEntry) -> some View {
        HStack(spacing: 10) {
            if entry.candidate {
                Toggle("选择 \(entry.name)", isOn: Binding(
                    get: { monitor.selected.contains(entry.key) },
                    set: { if $0 { monitor.selected.insert(entry.key) } else { monitor.selected.remove(entry.key) } }
                )).labelsHidden().toggleStyle(.checkbox)
            } else { Image(systemName: entry.ignored ? "bell.slash" : "circle").foregroundStyle(.tertiary).frame(width: 14) }
            if let icon = entry.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail(entry)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 2)
            Text(entry.readable ? memoryText(entry.memory.bytes) : "不可读")
                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
            Menu {
                if entry.candidate { Button("正常退出…") { quitTargets([entry.key]) } }
                Button("切到这个应用") { NSRunningApplication(processIdentifier: entry.pid)?.activate(options: []) }
                if !entry.protected { Button(entry.ignored ? "恢复提醒" : "加入忽略名单") { monitor.ignore(entry) } }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 20)
        }
        .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    func detail(_ entry: AppEntry) -> String {
        let state = entry.protected ? "系统应用，保留运行" : (entry.ignored ? "已忽略" : (entry.active ? "正在前台使用" : "未切到前台 \(idleText(entry.idle))"))
        let partial = entry.memory.unreadableCount > 0 ? " · 部分进程不可读" : ""
        return state + " · \(entry.memory.processCount) 个进程" + partial
    }
}

struct DashboardViewport: View {
    let dashboard: DashboardView
    let size: CGSize

    var body: some View {
        // The list scrolls normally. The outer scroll view also keeps controls
        // reachable on unusually short screens or with long result messages.
        ScrollView {
            dashboard.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("内存提醒设置").font(.title2.weight(.semibold))
            Form {
                Section("提醒条件") {
                    Toggle("内存压力偏高或严重时提醒", isOn: $monitor.remindersEnabled)
                    Picker("持续时间", selection: $monitor.holdMinutes) {
                        ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                    Picker("未切到前台", selection: $monitor.idleMinutes) {
                        ForEach([5, 15, 30, 60, 120, 240], id: \.self) { Text("至少 \($0) 分钟").tag($0) }
                    }
                    Picker("应用内存占用", selection: $monitor.minimumMB) {
                        ForEach([100, 250, 500, 1024, 2048, 4096], id: \.self) { Text("至少 \($0) MB").tag($0) }
                    }
                    Picker("提醒间隔 / 稍后提醒", selection: $monitor.cooldownMinutes) {
                        ForEach([5, 15, 30, 60, 120], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                }
                Section("启动") {
                    Toggle("登录时自动打开", isOn: Binding(get: { monitor.loginEnabled }, set: { monitor.setLogin($0) }))
                    if !monitor.loginMessage.isEmpty {
                        Text(monitor.loginMessage).font(.caption).foregroundStyle(.secondary)
                        Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Section("忽略名单") {
                    Text("同步、下载、会议及长任务应用可以加入忽略名单。")
                        .font(.caption).foregroundStyle(.secondary)
                    if monitor.ignoredIDs.isEmpty { Text("尚未添加应用；可在应用列表的“…”中添加。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(monitor.ignoredIDs).sorted(), id: \.self) { id in
                        HStack {
                            Text(monitor.entries.first { $0.bundleID == id }?.name ?? id).lineLimit(1)
                            Spacer()
                            Button("移除") { monitor.ignoredIDs.remove(id) }
                        }
                    }
                }
            }.formStyle(.grouped)
            Text("记录仅保存在本次运行的内存中，重启和唤醒后重新计时。提醒由你确认后才会发送正常退出请求。内存数值为应用及可归属辅助进程的 footprint 近似合计，与活动监视器可能略有差异。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 510, height: 630).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ReminderView: View {
    let entries: [AppEntry]
    let preview: Bool
    let pressure: Pressure
    let review: () -> Void
    let later: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip").font(.title2).foregroundStyle(preview ? Color.accentColor : pressure.color)
                Text(preview ? "提醒效果预览" : "内存压力\(pressure.title)").font(.headline)
            }
            Text(preview ? "这是提醒预览。点击查看后，可以审阅实际符合条件的应用。" :
                 "发现 \(entries.count) 个占用较大、较久未切到前台的应用。你可以查看后决定是否退出。")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(entries.prefix(3))) { entry in
                HStack {
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    Text(memoryText(entry.memory.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.caption)
            }
            HStack {
                Button("稍后提醒", action: later)
                Spacer()
                Button("查看应用…", action: review).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 360).background(Color(nsColor: .windowBackgroundColor))
    }
}
