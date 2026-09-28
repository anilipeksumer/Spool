import SpoolKit
import SwiftUI

@main
struct SpoolApp: App {
    @State private var store = ProfileStore()
    @State private var watches: WatchStore
    @State private var sessions: SessionRegistry
    @FocusedValue(\.connectionActions) private var actions

    init() {
        let w = WatchStore()
        _watches = State(initialValue: w)
        _sessions = State(initialValue: SessionRegistry(watches: w))
    }

    var body: some Scene {
        WindowGroup("Spool", id: "main") {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
                .environment(store)
                .environment(sessions)
                .environment(watches)
                .task { startWatchedSessions() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Redis Connection…") { actions?.add(.redis) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(actions == nil)
                Button("New RabbitMQ Connection…") { actions?.add(.rabbitmq) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(actions == nil)
            }
        }

        MenuBarExtra(isInserted: .constant(!watches.watches.isEmpty)) {
            WatchMenu()
                .environment(store)
                .environment(sessions)
                .environment(watches)
        } label: {
            WatchMenuLabel()
                .environment(sessions)
                .environment(watches)
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }

    /// Watched queues stay live in the menu bar even before the window is used.
    private func startWatchedSessions() {
        for id in watches.profileIDs {
            guard let p = store.profile(id) else { continue }
            let s = sessions.rabbit(for: p)
            if s.status == .idle { Task { await s.connect() } }
        }
    }
}

private struct WatchMenuLabel: View {
    @Environment(WatchStore.self) private var watches
    @Environment(SessionRegistry.self) private var sessions

    var body: some View {
        let alerting = watches.watches.contains { w in
            sessions.existingRabbit(w.profileID).map { _ in watches.isAlerting(w) } ?? false
        }
        Image(systemName: alerting ? "tray.full.fill" : "tray")
    }
}

struct WatchMenu: View {
    @Environment(WatchStore.self) private var watches
    @Environment(SessionRegistry.self) private var sessions
    @Environment(ProfileStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Watched Queues").font(.headline)
                Spacer()
                Button("Open Spool") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderless)
            }
            ForEach(store.profiles.filter { watches.profileIDs.contains($0.id) }) { p in
                let session = sessions.existingRabbit(p.id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        EnvironmentBadge(environment: p.environment)
                        if let e = session?.errorMessage {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(e)
                        }
                    }
                    ForEach(watches.watches.filter { $0.profileID == p.id }) { w in
                        WatchRow(watch: w, queue: session?.queues.first { $0.name == w.queue && $0.vhost == w.vhost },
                                 history: session?.queueHistory["\(w.vhost)/\(w.queue)"] ?? [])
                    }
                }
            }
            if let s = store.profiles.compactMap({ sessions.existingRabbit($0.id)?.lastRefresh }).max() {
                Text("Updated \(s.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct WatchRow: View {
    @Environment(WatchStore.self) private var watches
    let watch: WatchStore.Watch
    let queue: RabbitQueue?
    let history: [RabbitSession.QueueSample]
    @State private var editing = false

    var body: some View {
        let over = watches.isAlerting(watch)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(watch.queue).lineLimit(1)
                Text("limit \(watch.threshold.formatted())")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Sparkline(values: history.map { $0.ready + $0.unacked })
                .frame(width: 60, height: 16)
            Text(queue.map { Format.count($0.depth) } ?? "–")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(over ? .red : .primary)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(8)
        .background(over ? Color.red.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { editing = true }
        .popover(isPresented: $editing) {
            ThresholdEditor(watch: watch)
        }
    }
}

private struct ThresholdEditor: View {
    @Environment(WatchStore.self) private var watches
    let watch: WatchStore.Watch
    @State private var value: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alert when “\(watch.queue)” reaches").font(.callout)
            HStack {
                TextField("Messages", value: $value, format: .number).frame(width: 100)
                Text("messages")
                Spacer()
                Button("Save") { watches.setThreshold(value, for: watch) }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Stop Watching", role: .destructive) { watches.remove(watch) }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { value = watch.threshold }
    }
}
