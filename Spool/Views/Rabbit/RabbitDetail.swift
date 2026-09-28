import SpoolKit
import SwiftUI

struct RabbitDetail: View {
    let session: RabbitSession
    let tab: RabbitTab
    let edit: () -> Void

    var body: some View {
        Group {
            switch session.status {
            case .idle, .connecting:
                ProgressView("Connecting to \(session.profile.address)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where session.client == nil:
                ConnectionFailedView(profile: session.profile, message: message, retry: { Task { await session.connect() } }, edit: edit)
            default:
                VStack(spacing: 0) {
                    if let error = session.errorMessage {
                        Label("Lost contact: \(error)", systemImage: "wifi.exclamationmark")
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(.orange.opacity(0.15))
                    }
                    switch tab {
                    case .overview: RabbitOverviewView(session: session)
                    case .queues: QueuesView(session: session)
                    case .exchanges: ExchangesView(session: session)
                    case .clients: RabbitClientsView(session: session)
                    }
                }
            }
        }
        .navigationTitle(session.profile.name)
        .navigationSubtitle(subtitle)
        .task {
            if session.status == .idle { await session.connect() }
        }
    }

    private var subtitle: String {
        var s = session.profile.address
        if let v = session.overview?.rabbitmqVersion { s += " · RabbitMQ \(v)" }
        return s
    }
}

struct RabbitOverviewView: View {
    let session: RabbitSession
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        ScrollView {
            if let o = session.overview {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        StatTile(title: "Ready", value: Format.count(o.queueTotals?.messagesReady ?? 0), detail: "messages waiting")
                        StatTile(title: "Unacked", value: Format.count(o.queueTotals?.messagesUnacknowledged ?? 0), detail: "being processed")
                        StatTile(title: "Publish", value: Format.rate(o.messageStats?.publishRate ?? 0), detail: "messages in")
                        StatTile(title: "Deliver", value: Format.rate(o.messageStats?.deliverRate ?? 0), detail: "messages out")
                        let stuck = session.queues.filter { $0.looksLikeDeadLetter && $0.depth > 0 }
                        StatTile(title: "Dead Letters", value: Format.count(stuck.reduce(0) { $0 + $1.depth }),
                                 detail: stuck.isEmpty ? "all clear" : "in \(stuck.count) queue\(stuck.count == 1 ? "" : "s")",
                                 tint: stuck.isEmpty ? .primary : .red)
                        let idle = session.queues.filter { ($0.messagesReady ?? 0) > 0 && ($0.consumers ?? 0) == 0 && !$0.looksLikeDeadLetter }
                        StatTile(title: "No Consumers", value: "\(idle.count)",
                                 detail: idle.isEmpty ? "every busy queue is consumed" : "queues with waiting messages",
                                 tint: idle.isEmpty ? .primary : .orange)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Card(title: "Message rates") {
                            LiveChart(series: [
                                Series(id: "Publish", color: .blue, points: session.serverHistory.map { ($0.date, $0.publishRate) }),
                                Series(id: "Deliver", color: .green, points: session.serverHistory.map { ($0.date, $0.deliverRate) }),
                                Series(id: "Ack", color: .teal, points: session.serverHistory.map { ($0.date, $0.ackRate) }),
                            ], unit: "/s")
                        }
                        Card(title: "Queued messages") {
                            LiveChart(series: [
                                Series(id: "Ready", color: .orange, points: session.serverHistory.map { ($0.date, $0.ready) }),
                                Series(id: "Unacked", color: .purple, points: session.serverHistory.map { ($0.date, $0.unacked) }),
                            ])
                        }
                    }

                    Card(title: "Busiest queues") {
                        let top = session.queues.sorted { $0.depth > $1.depth }.prefix(8)
                        if top.allSatisfy({ $0.depth == 0 }) {
                            Text("Every queue is empty").foregroundStyle(.secondary)
                        } else {
                            let maxDepth = Double(top.first?.depth ?? 1)
                            ForEach(Array(top.filter { $0.depth > 0 })) { q in
                                HStack {
                                    Text(q.name).lineLimit(1).frame(width: 220, alignment: .leading)
                                    GeometryReader { g in
                                        Capsule()
                                            .fill(q.looksLikeDeadLetter ? Color.red.gradient : Color.accentColor.gradient)
                                            .frame(width: max(4, g.size.width * Double(q.depth) / max(1, maxDepth)))
                                    }
                                    .frame(height: 8)
                                    Text(Format.count(q.depth)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                }
                            }
                        }
                    }

                    if let t = o.objectTotals {
                        HStack(spacing: 24) {
                            Label("\(t.connections) connections", systemImage: "cable.connector")
                            Label("\(t.channels) channels", systemImage: "arrow.left.arrow.right")
                            Label("\(t.queues) queues", systemImage: "tray.2")
                            Label("\(t.exchanges) exchanges", systemImage: "arrow.triangle.branch")
                            Label("\(t.consumers) consumers", systemImage: "person.2")
                            Spacer()
                            if let n = o.clusterName { Text(n).foregroundStyle(.tertiary) }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
    }
}
