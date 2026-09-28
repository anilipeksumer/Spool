import SpoolKit
import SwiftUI

struct ExchangesView: View {
    let session: RabbitSession
    @State private var selection: RabbitExchange.ID?
    @State private var search = ""
    @State private var showBuiltIn = false
    @State private var bindings: [RabbitBinding] = []
    @State private var publishing: PublishDraft?
    @State private var creating = false
    @State private var toast: Toast?

    private var rows: [RabbitExchange] {
        session.exchanges
            .filter { showBuiltIn || !($0.name.isEmpty || $0.name.hasPrefix("amq.")) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var selected: RabbitExchange? { session.exchanges.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            Table(rows, selection: $selection) {
                TableColumn("Name") { e in
                    HStack {
                        Text(e.displayName)
                        if e.vhost != "/" { Text(e.vhost).font(.caption).foregroundStyle(.tertiary) }
                    }
                }
                .width(min: 140, ideal: 220)
                TableColumn("Type") { e in Text(e.type).foregroundStyle(.secondary) }.width(60)
                TableColumn("In") { e in Text(Format.rate(e.messageStats?.publishInDetails?.rate ?? 0)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(60).alignment(.trailing)
                TableColumn("Out") { e in Text(Format.rate(e.messageStats?.publishOutDetails?.rate ?? 0)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(60).alignment(.trailing)
            }
            .frame(minWidth: 380, idealWidth: 460)
            .overlay {
                if rows.isEmpty {
                    Placeholder(title: "No Exchanges", symbol: "arrow.triangle.branch",
                                message: showBuiltIn ? nil : "Only your own exchanges are shown. Turn on “Built-in” to see amq.* too.")
                }
            }

            Group {
                if let e = selected {
                    exchangeDetail(e)
                } else {
                    Placeholder(title: "No Exchange Selected", symbol: "arrow.triangle.branch",
                                message: "Choose an exchange to see where its messages go.")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter exchanges")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Built-in", isOn: $showBuiltIn)
                Button("New Exchange", systemImage: "plus") { creating = true }
            }
        }
        .task(id: selection) { await loadBindings() }
        .sheet(item: $publishing) { d in
            PublishSheet(session: session, draft: d) { routed in
                toast = routed ? Toast(text: "Published") : Toast(text: "Published, but no binding matched the routing key", isError: true)
            }
        }
        .sheet(isPresented: $creating) {
            NewExchangeSheet(session: session) { toast = Toast(text: "Created \($0)") }
        }
        .toast($toast)
        #if DEBUG
        .task(id: session.exchanges.count) {
            if selection == nil, let name = UserDefaults.standard.string(forKey: "selectItem") {
                selection = session.exchanges.first { $0.name == name }?.id
            }
        }
        #endif
    }

    private func exchangeDetail(_ e: RabbitExchange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text("\(e.type.capitalized) exchange · \(e.durable == true ? "durable" : "transient")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Publish…", systemImage: "paperplane") {
                    publishing = PublishDraft(exchange: e.name, routingKey: bindings.first?.routingKey ?? "", vhost: e.vhost)
                }
            }
            .padding(16)
            Divider()
            if bindings.isEmpty {
                Placeholder(title: "No Bindings", symbol: "link",
                            message: "Messages published here are dropped until a queue or exchange is bound to it.")
            } else {
                // A small routing map: exchange → routing key → destination.
                List(bindings) { b in
                    HStack(spacing: 10) {
                        Text(b.routingKey.isEmpty ? "(any)" : b.routingKey)
                            .font(.body.monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.background.secondary, in: .capsule)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Image(systemName: b.destinationType == "queue" ? "tray" : "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                        Text(b.destination)
                        Spacer()
                        if let q = session.queues.first(where: { $0.name == b.destination && $0.vhost == b.vhost }) {
                            Text("\(Format.count(q.depth)) msgs").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }

    private func loadBindings() async {
        guard let e = selected, let c = session.client, !e.name.isEmpty else { bindings = []; return }
        bindings = (try? await c.bindings(fromExchange: e.name, vhost: e.vhost)) ?? []
    }
}

private struct NewExchangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RabbitSession
    let created: (String) -> Void
    @State private var name = ""
    @State private var type = "topic"
    @State private var vhost = "/"
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("orders"))
                Picker("Type", selection: $type) {
                    ForEach(["direct", "topic", "fanout", "headers"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                if session.vhosts.count > 1 {
                    Picker("Virtual host", selection: $vhost) {
                        ForEach(session.vhosts, id: \.self) { Text($0).tag($0) }
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        do {
                            try await session.perform { try await $0.declareExchange(name, vhost: vhost, type: type) }
                            created(name)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 400)
    }
}

struct RabbitClientsView: View {
    let session: RabbitSession

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Connections (\(session.connections.count))").font(.headline).padding(12)
                Table(session.connections) {
                    TableColumn("Client") { c in Text(c.clientName) }
                    TableColumn("User") { c in Text(c.user ?? "").foregroundStyle(.secondary) }.width(90)
                    TableColumn("Address") { c in Text("\(c.peerHost ?? ""):\(c.peerPort.map(String.init) ?? "")").font(.caption.monospaced()) }
                    TableColumn("Channels") { c in Text("\(c.channels ?? 0)").monospacedDigit() }.width(70).alignment(.trailing)
                    TableColumn("State") { c in
                        Text(c.state ?? "").foregroundStyle(c.state == "running" ? .green : .orange)
                    }
                    .width(80)
                }
            }
            .frame(minHeight: 180)
            VStack(alignment: .leading, spacing: 0) {
                Text("Consumers (\(session.consumers.count))").font(.headline).padding(12)
                Table(session.consumers) {
                    TableColumn("Queue") { c in Text(c.queue.name) }
                    TableColumn("Connection") { c in Text(c.channelDetails?.connectionName ?? c.channelDetails?.peerHost ?? "") }
                    TableColumn("Prefetch") { c in Text("\(c.prefetchCount ?? 0)").monospacedDigit() }.width(70).alignment(.trailing)
                    TableColumn("Ack") { c in Text(c.ackRequired == false ? "auto" : "manual").foregroundStyle(.secondary) }.width(70)
                }
            }
            .frame(minHeight: 160)
        }
    }
}
