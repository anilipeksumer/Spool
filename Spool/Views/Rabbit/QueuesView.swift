import SpoolKit
import SwiftUI

struct QueuesView: View {
    let session: RabbitSession
    @Environment(WatchStore.self) private var watches
    @State private var selection: RabbitQueue.ID?
    @State private var search = ""
    @State private var onlyProblems = false
    @State private var sortOrder = [KeyPathComparator(\RabbitQueue.name, comparator: .localizedStandard)]
    @State private var creating = false
    @State private var toast: Toast?

    private var rows: [RabbitQueue] {
        session.queues
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .filter { !onlyProblems || isProblem($0) }
            .sorted(using: sortOrder)
    }

    private func isProblem(_ q: RabbitQueue) -> Bool {
        (q.looksLikeDeadLetter && q.depth > 0) || ((q.messagesReady ?? 0) > 0 && (q.consumers ?? 0) == 0)
    }

    var body: some View {
        VSplitView {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { q in
                    HStack(spacing: 6) {
                        if watches.isWatched(q, profile: session.profile.id) {
                            Image(systemName: "eye.fill").foregroundStyle(.tint).font(.caption)
                        }
                        Text(q.name)
                            .foregroundStyle(q.looksLikeDeadLetter && q.depth > 0 ? .red : .primary)
                        if q.vhost != "/" {
                            Text(q.vhost).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .help(q.name)
                }
                .width(min: 180, ideal: 280)
                TableColumn("Type", value: \.typeLabel) { q in
                    Text(q.typeLabel).foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Ready", value: \.readySort) { q in
                    Text(Format.count(q.messagesReady ?? 0)).monospacedDigit()
                        .foregroundStyle((q.messagesReady ?? 0) > 0 ? .primary : .tertiary)
                }
                .width(min: 60, ideal: 80)
                .alignment(.trailing)
                TableColumn("Unacked", value: \.unackedSort) { q in
                    Text(Format.count(q.messagesUnacknowledged ?? 0)).monospacedDigit()
                        .foregroundStyle((q.messagesUnacknowledged ?? 0) > 0 ? .primary : .tertiary)
                }
                .width(min: 60, ideal: 80)
                .alignment(.trailing)
                TableColumn("Consumers", value: \.consumerSort) { q in
                    Text("\(q.consumers ?? 0)").monospacedDigit()
                        .foregroundStyle((q.consumers ?? 0) == 0 && (q.messagesReady ?? 0) > 0 ? .orange : .secondary)
                }
                .width(min: 60, ideal: 80)
                .alignment(.trailing)
                TableColumn("In", value: \.inSort) { q in
                    Text(Format.rate(q.messageStats?.publishRate ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70)
                .alignment(.trailing)
                TableColumn("Out", value: \.outSort) { q in
                    Text(Format.rate(q.messageStats?.deliverRate ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 70)
                .alignment(.trailing)
                TableColumn("Trend") { q in
                    Sparkline(values: session.queueHistory[q.id]?.map { $0.ready + $0.unacked } ?? [])
                        .frame(height: 16)
                }
                .width(min: 60, ideal: 90)
            }
            .contextMenu(forSelectionType: RabbitQueue.ID.self) { ids in
                if let q = session.queue(ids.first) {
                    Button(watches.isWatched(q, profile: session.profile.id) ? "Stop Watching" : "Watch in Menu Bar") {
                        watches.toggle(q, profile: session.profile)
                    }
                    Button("Copy Name") { copyToPasteboard(q.name) }
                }
            }
            .frame(minHeight: 190, idealHeight: 240)
            .overlay {
                if rows.isEmpty {
                    Placeholder(title: session.queues.isEmpty ? "No Queues" : "No Matches", symbol: "tray",
                                message: session.queues.isEmpty ? "Create one with +, or start an app that declares its queues." : nil)
                }
            }

            Group {
                if let q = session.queue(selection) {
                    QueueDetailView(session: session, queue: q, toast: $toast)
                        .id(q.id)
                } else {
                    Placeholder(title: "No Queue Selected", symbol: "tray.2", message: "Choose a queue to see its messages, bindings and consumers.")
                }
            }
            .frame(minHeight: 380, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter queues")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $onlyProblems) {
                    Label("Needs Attention", systemImage: "exclamationmark.triangle")
                }
                .help("Only dead-letter queues with messages and queues with no consumers")
                Button("New Queue", systemImage: "plus") { creating = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await session.refresh() } }
                    .keyboardShortcut("r")
            }
        }
        .sheet(isPresented: $creating) {
            NewQueueSheet(session: session) { name in toast = Toast(text: "Created \(name)") }
        }
        .toast($toast)
        #if DEBUG
        .task(id: session.queues.count) {
            if selection == nil, let name = UserDefaults.standard.string(forKey: "selectItem") {
                selection = session.queues.first { $0.name == name }?.id
            }
        }
        #endif
    }
}

private extension RabbitQueue {
    var typeLabel: String { (type ?? "classic").capitalized }
    var readySort: Int64 { messagesReady ?? 0 }
    var unackedSort: Int64 { messagesUnacknowledged ?? 0 }
    var consumerSort: Int { consumers ?? 0 }
    var inSort: Double { messageStats?.publishRate ?? 0 }
    var outSort: Double { messageStats?.deliverRate ?? 0 }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let maxV = max(values.max() ?? 1, 1)
            let step = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(v / maxV) * (size.height - 2) - 1)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct NewQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RabbitSession
    let created: (String) -> Void
    @State private var name = ""
    @State private var vhost = "/"
    @State private var type = "classic"
    @State private var durable = true
    @State private var dlx = ""
    @State private var bindExchange = ""
    @State private var routingKey = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("orders.created"))
                if session.vhosts.count > 1 {
                    Picker("Virtual host", selection: $vhost) {
                        ForEach(session.vhosts, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Type", selection: $type) {
                    Text("Classic").tag("classic")
                    Text("Quorum").tag("quorum")
                    Text("Stream").tag("stream")
                }
                Toggle("Durable", isOn: $durable)
                    .disabled(type != "classic")
                TextField("Dead-letter exchange", text: $dlx, prompt: Text("Optional"))
                Section("Bind to") {
                    Picker("Exchange", selection: $bindExchange) {
                        Text("Don't bind").tag("")
                        ForEach(session.exchanges.filter { $0.vhost == vhost && !$0.name.isEmpty && !$0.name.hasPrefix("amq.") }) {
                            Text($0.name).tag($0.name)
                        }
                    }
                    if !bindExchange.isEmpty {
                        TextField("Routing key", text: $routingKey, prompt: Text(name))
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
    }

    private func create() async {
        do {
            var args: [String: JSONValue] = [:]
            if !dlx.isEmpty { args["x-dead-letter-exchange"] = .string(dlx) }
            try await session.perform { c in
                try await c.declareQueue(name, vhost: vhost, durable: type == "classic" ? durable : true, type: type, arguments: args)
                if !bindExchange.isEmpty {
                    try await c.bind(queue: name, to: bindExchange, vhost: vhost, routingKey: routingKey.isEmpty ? name : routingKey)
                }
            }
            created(name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
