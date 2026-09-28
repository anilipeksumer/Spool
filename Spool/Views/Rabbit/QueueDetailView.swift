import SpoolKit
import SwiftUI

struct QueueDetailView: View {
    let session: RabbitSession
    let queue: RabbitQueue
    @Binding var toast: Toast?
    @Environment(WatchStore.self) private var watches
    @State private var tab: Tab = .messages
    @State private var confirm: Confirm?
    @State private var publishing: PublishDraft?
    @State private var moving = false

    enum Tab: String, CaseIterable, Identifiable {
        case messages, activity, bindings, consumers, details
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Confirm: Identifiable {
        case purge, delete
        var id: Int { self == .purge ? 0 : 1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t == .consumers ? "Consumers (\(session.consumers(of: queue).count))" : t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()
            switch tab {
            case .messages:
                MessagesPane(session: session, queue: queue, toast: $toast) { publishing = $0 }
            case .activity:
                ScrollView { activity.padding(16) }
            case .bindings:
                BindingsPane(session: session, queue: queue, toast: $toast)
            case .consumers:
                consumers
            case .details:
                details
            }
        }
        .confirmationDialog(confirmTitle, isPresented: .constant(confirm != nil), presenting: confirm) { c in
            Button(c == .purge ? "Purge \(Format.count(queue.messagesReady ?? 0)) Messages" : "Delete Queue", role: .destructive) {
                confirm = nil
                Task {
                    do {
                        try await session.perform { cl in
                            if c == .purge { try await cl.purge(queue: queue.name, vhost: queue.vhost) }
                            else { try await cl.deleteQueue(queue.name, vhost: queue.vhost) }
                        }
                        toast = Toast(text: c == .purge ? "Purged \(queue.name)" : "Deleted \(queue.name)")
                    } catch {
                        toast = Toast(text: error.localizedDescription, isError: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { c in
            Text(c == .purge
                 ? "Every ready message in “\(queue.name)” is removed. Unacked messages stay. This can't be undone."
                 : "The queue and its \(Format.count(queue.depth)) messages are removed. This can't be undone.")
        }
        .sheet(item: $publishing) { draft in
            PublishSheet(session: session, draft: draft) { routed in
                toast = routed ? Toast(text: "Published") : Toast(text: "Published, but no queue received it", isError: true)
            }
        }
        .sheet(isPresented: $moving) {
            MoveSheet(session: session, source: queue) { target in
                toast = Toast(text: "Moving messages to \(target)…")
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .purge: "Purge “\(queue.name)”?"
        case .delete: "Delete “\(queue.name)”?"
        case nil: ""
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(queue.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if queue.looksLikeDeadLetter {
                        Text("DEAD LETTER").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.red.opacity(0.5)))
                    }
                }
                Text([queue.typeDescription, queue.vhost == "/" ? nil : "vhost \(queue.vhost)", queue.state].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            metric("Ready", Format.count(queue.messagesReady ?? 0))
            metric("Unacked", Format.count(queue.messagesUnacknowledged ?? 0))
            metric("In", Format.rate(queue.messageStats?.publishRate ?? 0))
            metric("Out", Format.rate(queue.messageStats?.deliverRate ?? 0))
            HStack(spacing: 6) {
                Button("Publish…", systemImage: "paperplane") {
                    publishing = PublishDraft(exchange: "", routingKey: queue.name, vhost: queue.vhost)
                }
                Menu {
                    Button("Move All Messages To…", systemImage: "arrow.right.circle") { moving = true }
                        .disabled(!session.canMove || queue.depth == 0)
                    Button(watches.isWatched(queue, profile: session.profile.id) ? "Stop Watching" : "Watch in Menu Bar", systemImage: "eye") {
                        watches.toggle(queue, profile: session.profile)
                    }
                    Divider()
                    Button("Purge Messages…", systemImage: "xmark.bin", role: .destructive) { confirm = .purge }
                        .disabled((queue.messagesReady ?? 0) == 0)
                    Button("Delete Queue…", systemImage: "trash", role: .destructive) { confirm = .delete }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .animation(.snappy, value: value)
    }

    private var activity: some View {
        let h = session.queueHistory[queue.id] ?? []
        return HStack(alignment: .top, spacing: 12) {
            Card(title: "Depth") {
                LiveChart(series: [
                    Series(id: "Ready", color: .orange, points: h.map { ($0.date, $0.ready) }),
                    Series(id: "Unacked", color: .purple, points: h.map { ($0.date, $0.unacked) }),
                ], height: 180)
            }
            Card(title: "Rates") {
                LiveChart(series: [
                    Series(id: "In", color: .blue, points: h.map { ($0.date, $0.publishRate) }),
                    Series(id: "Out", color: .green, points: h.map { ($0.date, $0.deliverRate) }),
                ], height: 180, unit: "/s")
            }
        }
    }

    private var consumers: some View {
        let list = session.consumers(of: queue)
        return Group {
            if list.isEmpty {
                Placeholder(title: "No Consumers", symbol: "person.crop.circle.badge.questionmark",
                            message: (queue.messagesReady ?? 0) > 0 ? "Messages are waiting, but nothing is reading this queue." : nil)
            } else {
                Table(list) {
                    TableColumn("Connection") { c in Text(c.channelDetails?.connectionName ?? c.channelDetails?.peerHost ?? "—") }
                    TableColumn("Tag") { c in Text(c.consumerTag).font(.caption.monospaced()) }
                    TableColumn("Prefetch") { c in Text("\(c.prefetchCount ?? 0)").monospacedDigit() }.width(70)
                    TableColumn("Ack") { c in Text(c.ackRequired == false ? "auto" : "manual") }.width(70)
                }
            }
        }
    }

    private var details: some View {
        Form {
            LabeledContent("Durable", value: queue.durable == true ? "Yes" : "No")
            LabeledContent("Auto-delete", value: queue.autoDelete == true ? "Yes" : "No")
            LabeledContent("Exclusive", value: queue.exclusive == true ? "Yes" : "No")
            if let n = queue.node { LabeledContent("Node", value: n) }
            if let m = queue.memory { LabeledContent("Memory", value: Format.bytes(m)) }
            if let idle = queue.idleSince { LabeledContent("Idle since", value: idle) }
            if let args = queue.arguments, !args.isEmpty {
                Section("Arguments") {
                    ForEach(args.keys.sorted(), id: \.self) { k in
                        LabeledContent(k) { Text(args[k]?.display ?? "").textSelection(.enabled).font(.body.monospaced()) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension RabbitQueue {
    var typeDescription: String { (type ?? "classic").capitalized + " queue" }
}

// MARK: - Messages

private struct MessagesPane: View {
    let session: RabbitSession
    let queue: RabbitQueue
    @Binding var toast: Toast?
    let republish: (PublishDraft) -> Void
    @State private var messages: [RabbitMessage] = []
    @State private var selection: Int?
    @State private var count = 20
    @State private var loading = false
    @State private var loaded = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        Task { await peek() }
                    } label: {
                        Label(loaded ? "Peek Again" : "Peek", systemImage: "eye")
                    }
                    .fixedSize()
                    .disabled(loading || (queue.messagesReady ?? 0) == 0)
                    Picker("", selection: $count) {
                        ForEach([10, 20, 50, 100], id: \.self) { Text("\($0) messages").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .padding(10)
                Divider()
                if messages.isEmpty {
                    Placeholder(
                        title: loaded ? "Queue Is Empty" : "Look Inside",
                        symbol: "envelope.open",
                        message: (queue.messagesReady ?? 0) == 0
                            ? "No ready messages right now."
                            : "Peek fetches the first messages and puts them straight back. They return to the queue marked as redelivered.")
                } else {
                    List(Array(messages.enumerated()), id: \.offset, selection: $selection) { i, m in
                        MessageRow(index: i, message: m)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 260, idealWidth: 320)

            Group {
                if let i = selection, messages.indices.contains(i) {
                    MessageDetail(message: messages[i], queue: queue, toast: $toast, republish: republish)
                } else {
                    Text(messages.isEmpty ? "" : "Select a message")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "autoPeek") { await peek() } }
        #endif
    }

    private func peek() async {
        guard let c = session.client else { return }
        loading = true
        defer { loading = false }
        do {
            messages = try await c.getMessages(queue: queue.name, vhost: queue.vhost, count: count, mode: .peek)
            selection = messages.isEmpty ? nil : 0
            loaded = true
        } catch {
            toast = Toast(text: error.localizedDescription, isError: true)
        }
    }
}

private struct MessageRow: View {
    let index: Int
    let message: RabbitMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("#\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                let key = message.originalRoutingKey ?? message.routingKey
                Text(key.isEmpty ? "(no routing key)" : key)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(ByteFormat.string(Int64(message.payloadBytes))).font(.caption).foregroundStyle(.secondary)
            }
            Text(preview)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let reason = message.deathReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        let s = message.payloadData.displayString
        return s.replacingOccurrences(of: "\n", with: " ").prefix(200).description
    }
}

private struct MessageDetail: View {
    let message: RabbitMessage
    let queue: RabbitQueue
    @Binding var toast: Toast?
    let republish: (PublishDraft) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Payload").font(.headline)
                    Text(isJSON ? "JSON" : (message.payloadEncoding == "base64" ? "Binary" : "Text"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        copyToPasteboard(message.payloadData.displayString)
                        toast = Toast(text: "Payload copied")
                    }
                    Button("Republish…", systemImage: "arrow.uturn.forward") {
                        republish(PublishDraft(
                            exchange: message.originalExchange ?? message.exchange,
                            routingKey: message.originalRoutingKey ?? message.routingKey,
                            vhost: queue.vhost,
                            payload: message.payloadData.displayString,
                            contentType: message.properties?["content_type"]?.stringValue ?? "",
                            headers: message.headers.filter { $0.key != "x-death" && !$0.key.hasPrefix("x-first-death") && !$0.key.hasPrefix("x-last-death") }))
                    }
                    .help("Opens the publish form filled with this message, sent to where it was originally going")
                }
                .buttonStyle(.borderless)
                CodeText(text: JSONFormatter.pretty(message.payloadData) ?? message.payloadData.displayString)
                    .frame(minHeight: 140)

                if let reason = message.deathReason {
                    Label("Dead-lettered: \(reason)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                section("Routing", [
                    ("Exchange", message.exchange.isEmpty ? "(AMQP default)" : message.exchange),
                    ("Routing key", message.routingKey),
                    ("Redelivered", message.redelivered ? "Yes" : "No"),
                ])
                if !message.propertyPairs.isEmpty {
                    section("Properties", message.propertyPairs)
                }
                if !message.headers.isEmpty {
                    section("Headers", message.headers.sorted { $0.key < $1.key }.map { ($0.key, $0.value.display) })
                }
            }
            .padding(16)
        }
    }

    private var isJSON: Bool { JSONFormatter.pretty(message.payloadData) != nil }

    private func section(_ title: String, _ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(pairs, id: \.0) { k, v in
                    GridRow {
                        Text(k).foregroundStyle(.secondary)
                        Text(v).textSelection(.enabled).lineLimit(4)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Bindings

private struct BindingsPane: View {
    let session: RabbitSession
    let queue: RabbitQueue
    @Binding var toast: Toast?
    @State private var bindings: [RabbitBinding] = []
    @State private var exchange = ""
    @State private var routingKey = ""

    var body: some View {
        VStack(spacing: 0) {
            Table(bindings) {
                TableColumn("From exchange") { b in Text(b.source.isEmpty ? "(AMQP default)" : b.source) }
                TableColumn("Routing key") { b in Text(b.routingKey).font(.body.monospaced()) }
                TableColumn("") { b in
                    if !b.source.isEmpty {
                        Button("Unbind") { Task { await unbind(b) } }
                            .buttonStyle(.borderless)
                    }
                }
                .width(70)
            }
            Divider()
            HStack {
                Picker("Exchange", selection: $exchange) {
                    Text("Choose…").tag("")
                    ForEach(session.exchanges.filter { $0.vhost == queue.vhost && !$0.name.isEmpty }) { Text($0.name).tag($0.name) }
                }
                .fixedSize()
                TextField("Routing key", text: $routingKey)
                Button("Bind") { Task { await bind() } }
                    .disabled(exchange.isEmpty)
            }
            .padding(10)
        }
        .task { await load() }
    }

    private func load() async {
        bindings = (try? await session.client?.bindings(forQueue: queue.name, vhost: queue.vhost)) ?? []
    }

    private func bind() async {
        do {
            try await session.client?.bind(queue: queue.name, to: exchange, vhost: queue.vhost, routingKey: routingKey)
            routingKey = ""
            await load()
            toast = Toast(text: "Bound to \(exchange)")
        } catch {
            toast = Toast(text: error.localizedDescription, isError: true)
        }
    }

    private func unbind(_ b: RabbitBinding) async {
        do {
            try await session.client?.unbind(b)
            await load()
        } catch {
            toast = Toast(text: error.localizedDescription, isError: true)
        }
    }
}

// MARK: - Move

private struct MoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RabbitSession
    let source: RabbitQueue
    let started: (String) -> Void
    @State private var target = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move messages from “\(source.name)”").font(.headline)
            Text("All \(Format.count(source.messagesReady ?? 0)) ready messages are moved with a one-off shovel. Each is removed from “\(source.name)” only after the target has it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("To queue", selection: $target) {
                ForEach(session.queues.filter { $0.vhost == source.vhost && $0.id != source.id }) { q in
                    Text(q.name).tag(q.name)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move") {
                    Task {
                        do {
                            try await session.perform { try await $0.moveMessages(from: source.name, to: target, vhost: source.vhost) }
                            started(target)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { target = guessTarget() }
    }

    /// orders.dlq → orders, orders_error → orders.
    private func guessTarget() -> String {
        let names = Set(session.queues.filter { $0.vhost == source.vhost }.map(\.name))
        for suffix in [".dlq", "-dlq", "_dlq", ".dead", "_error", ".error", ".deadletter", "-deadletter"] where source.name.hasSuffix(suffix) {
            let base = String(source.name.dropLast(suffix.count))
            if names.contains(base) { return base }
        }
        return session.queues.first { $0.vhost == source.vhost && $0.id != source.id }?.name ?? ""
    }
}
