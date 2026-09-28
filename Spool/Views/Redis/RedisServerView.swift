import SpoolKit
import SwiftUI

struct RedisServerView: View {
    let session: RedisSession
    @State private var slowLog: [RedisClient.SlowLogEntry] = []
    @State private var clients: [RedisClient.ClientInfo] = []
    @State private var showRaw = false

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            if let info = session.info {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        StatTile(title: "Operations", value: "\(Format.compact(Double(info.opsPerSecond)))/s",
                                 detail: "\(Format.compact(info.inputKbps)) KB/s in · \(Format.compact(info.outputKbps)) KB/s out")
                        StatTile(title: "Memory", value: Format.bytes(info.usedMemory),
                                 detail: info.maxMemory > 0 ? "of \(Format.bytes(info.maxMemory)) · \(info["maxmemory_policy"] ?? "")" : "No limit",
                                 tint: memoryTint(info)) {
                            if info.maxMemory > 0 {
                                ProgressView(value: min(1, Double(info.usedMemory) / Double(info.maxMemory)))
                                    .tint(memoryTint(info))
                            }
                        }
                        StatTile(title: "Hit Rate", value: hitRate(info),
                                 detail: "\(Format.compact(Double(info.hits))) hits · \(Format.compact(Double(info.misses))) misses")
                        StatTile(title: "Clients", value: Format.count(info.connectedClients),
                                 detail: "\(info["blocked_clients"] ?? "0") blocked")
                        StatTile(title: "Uptime", value: Format.duration(seconds: info.uptime),
                                 detail: "Redis \(info.version) · \(info.role)")
                        StatTile(title: "Evicted · Expired", value: "\(Format.compact(Double(info.int("evicted_keys") ?? 0))) · \(Format.compact(Double(info.int("expired_keys") ?? 0)))",
                                 detail: "keys since start")
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Card(title: "Operations per second") {
                            LiveChart(series: [Series(id: "ops/s", color: .accentColor,
                                                      points: session.samples.map { ($0.date, $0.opsPerSecond) })])
                        }
                        Card(title: "Memory") {
                            LiveChart(series: [Series(id: "Memory", color: .purple,
                                                      points: session.samples.map { ($0.date, $0.memory) })], unit: "B")
                        }
                    }

                    Card(title: "Keyspace") {
                        if info.keyspace.isEmpty {
                            Text("All databases are empty").foregroundStyle(.secondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                                GridRow {
                                    Text("Database"); Text("Keys"); Text("With expiry")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                ForEach(info.keyspace, id: \.db) { db in
                                    GridRow {
                                        Text("db\(db.db)").fontWeight(db.db == session.profile.database ? .semibold : .regular)
                                        Text(db.keys.formatted()).monospacedDigit()
                                        Text(db.expires.formatted()).monospacedDigit()
                                    }
                                }
                            }
                        }
                    }

                    Card(title: "Slow Log", trailing: {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadLists() } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }) {
                        if slowLog.isEmpty {
                            Text("No slow commands logged").foregroundStyle(.secondary)
                        } else {
                            ForEach(slowLog.prefix(15)) { e in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(e.duration.formatted(.units(allowed: [.seconds, .milliseconds, .microseconds], width: .narrow, maximumUnitCount: 1)))
                                        .monospacedDigit()
                                        .foregroundStyle(.orange)
                                        .frame(width: 70, alignment: .trailing)
                                    Text(e.command)
                                        .font(.system(.callout, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(e.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Card(title: "Clients (\(clients.count))") {
                        ForEach(clients.prefix(20)) { c in
                            HStack {
                                Text(c.name.isEmpty ? c.address : c.name)
                                    .lineLimit(1)
                                if !c.name.isEmpty {
                                    Text(c.address).foregroundStyle(.secondary).font(.caption)
                                }
                                Spacer()
                                Text(c.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text("db\(c.db)").font(.caption).foregroundStyle(.tertiary)
                                Text("idle \(Format.duration(seconds: Int64(c.idle)))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                    }

                    DisclosureGroup("All server info", isExpanded: $showRaw) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(info.sections, id: \.name) { section in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(section.name).font(.headline)
                                    ForEach(section.fields, id: \.0) { k, v in
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(k).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                                            Text(v).textSelection(.enabled)
                                        }
                                        .font(.system(.caption, design: .monospaced))
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            } else {
                ProgressView().padding(60)
            }
        }
        .task {
            await loadLists()
            while !Task.isCancelled {
                await session.refreshInfo()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func loadLists() async {
        guard let c = session.client else { return }
        slowLog = (try? await c.slowLog()) ?? []
        clients = (try? await c.clients()) ?? []
    }

    private func hitRate(_ i: RedisInfo) -> String {
        let total = i.hits + i.misses
        guard total > 0 else { return "–" }
        return (Double(i.hits) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
    }

    private func memoryTint(_ i: RedisInfo) -> Color {
        guard i.maxMemory > 0 else { return .primary }
        let r = Double(i.usedMemory) / Double(i.maxMemory)
        return r > 0.9 ? .red : (r > 0.75 ? .orange : .primary)
    }
}
