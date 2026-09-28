import SpoolKit
import SwiftUI

struct ConsoleView: View {
    let session: RedisSession
    @State private var line = ""
    @State private var historyIndex: Int?
    @State private var running = false
    @FocusState private var focused: Bool

    private var history: [String] { session.consoleEntries.map(\.command) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if session.consoleEntries.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Run any Redis command. Use ↑ and ↓ for history, “clear” to start over.")
                                Text("Try: INFO keyspace · SCAN 0 MATCH user:* · HGETALL <key> · TTL <key>")
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                        }
                        ForEach(session.consoleEntries) { e in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("›").foregroundStyle(.tint)
                                    Text(e.command).fontWeight(.medium)
                                    Spacer()
                                    Text(e.duration.formatted(.units(allowed: [.seconds, .milliseconds, .microseconds], width: .narrow, maximumUnitCount: 1)))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Group {
                                    if let error = e.error {
                                        Text(error).foregroundStyle(.red)
                                    } else if let reply = e.reply {
                                        Text(render(reply))
                                            .foregroundStyle(reply.isErrorReply ? .red : .primary)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                            .id(e.id)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .onChange(of: session.consoleEntries.count) {
                    if let last = session.consoleEntries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text("\(session.profile.host)[\(session.profile.database)]›")
                    .foregroundStyle(.secondary)
                TextField("Command", text: $line)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            .font(.system(.body, design: .monospaced))
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func render(_ v: RESPValue) -> String {
        // JSON strings read better formatted.
        if case .bulk(let d?) = v, let pretty = JSONFormatter.pretty(d) { return pretty }
        return v.rendered()
    }

    private func submit() {
        let cmd = line
        guard !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        line = ""
        historyIndex = nil
        running = true
        Task {
            await session.run(cmd)
            running = false
            focused = true
        }
    }

    private func step(_ delta: Int) {
        guard !history.isEmpty else { return }
        let i = (historyIndex ?? history.count) + delta
        if i >= history.count {
            historyIndex = nil
            line = ""
        } else {
            historyIndex = max(0, i)
            line = history[historyIndex!]
        }
    }
}

extension RESPValue {
    var isErrorReply: Bool {
        if case .error = self { return true }
        return false
    }
}
