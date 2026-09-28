import SpoolKit
import SwiftUI

struct PublishDraft: Identifiable {
    let id = UUID()
    var exchange: String
    var routingKey: String
    var vhost: String
    var payload = "{\n  \n}"
    var contentType = "application/json"
    var headers: [String: JSONValue] = [:]
}

struct PublishSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RabbitSession
    @State var draft: PublishDraft
    let published: (Bool) -> Void
    @State private var headerRows: [HeaderRow] = []
    @State private var repeatCount = 1
    @State private var error: String?
    @State private var sending = false

    struct HeaderRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Exchange", selection: $draft.exchange) {
                    Text("(AMQP default) — straight to a queue").tag("")
                    ForEach(session.exchanges.filter { $0.vhost == draft.vhost && !$0.name.isEmpty }) { e in
                        Text("\(e.name)  ·  \(e.type)").tag(e.name)
                    }
                }
                TextField(draft.exchange.isEmpty ? "Queue" : "Routing key", text: $draft.routingKey)
                    .font(.body.monospaced())
                TextField("Content type", text: $draft.contentType, prompt: Text("application/json"))
                Section {
                    ForEach($headerRows) { $row in
                        HStack {
                            TextField("Header", text: $row.key).font(.body.monospaced())
                            TextField("Value", text: $row.value).font(.body.monospaced())
                            Button { headerRows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Header", systemImage: "plus") { headerRows.append(HeaderRow(key: "", value: "")) }
                        .buttonStyle(.borderless)
                } header: {
                    Text("Headers")
                }
                Section {
                    TextEditor(text: $draft.payload)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .scrollContentBackground(.hidden)
                } header: {
                    HStack {
                        Text("Payload")
                        Spacer()
                        if draft.contentType.contains("json") {
                            if JSONFormatter.pretty(draft.payload) == nil {
                                Label("Not valid JSON", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            } else {
                                Button("Format") { draft.payload = JSONFormatter.pretty(draft.payload) ?? draft.payload }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Stepper("Send \(repeatCount) time\(repeatCount == 1 ? "" : "s")", value: $repeatCount, in: 1...1000)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                if session.profile.environment == .prod {
                    Label("Production", systemImage: "exclamationmark.shield.fill").foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Publish") { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.glassProminent)
                    .disabled(sending || (draft.exchange.isEmpty && draft.routingKey.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            headerRows = draft.headers.sorted { $0.key < $1.key }.map { HeaderRow(key: $0.key, value: $0.value.display) }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        var headers: [String: JSONValue] = [:]
        for r in headerRows where !r.key.isEmpty { headers[r.key] = JSONValue(guessing: r.value) }
        var props = RabbitClient.PublishProperties(contentType: draft.contentType, headers: headers)
        props.messageId = nil
        do {
            var routed = true
            for _ in 0..<repeatCount {
                routed = try await session.client?.publish(exchange: draft.exchange, vhost: draft.vhost, routingKey: draft.routingKey,
                                                           payload: draft.payload, properties: props) ?? false
            }
            await session.refresh()
            published(routed)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
