import SpoolKit
import SwiftUI

enum RedisTab: String, CaseIterable, Identifiable {
    case keys, server, console
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .keys: "key"
        case .server: "gauge.with.dots.needle.33percent"
        case .console: "terminal"
        }
    }
}

enum RabbitTab: String, CaseIterable, Identifiable {
    case overview, queues, exchanges, clients
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .queues: "tray.2"
        case .exchanges: "arrow.triangle.branch"
        case .clients: "person.2"
        }
    }
}

enum Destination: Hashable {
    case redis(UUID, RedisTab)
    case rabbit(UUID, RabbitTab)

    var profileID: UUID {
        switch self {
        case .redis(let id, _), .rabbit(let id, _): id
        }
    }
}

struct RootView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(SessionRegistry.self) private var sessions
    @SceneStorage("selection") private var storedSelection: String?
    @State private var selection: Destination?
    @State private var editing: ConnectionProfile?
    @State private var isNew = false
    @State private var confirmDelete: ConnectionProfile?

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, edit: { edit($0) }, add: { add($0) }, delete: { confirmDelete = $0 })
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .sheet(item: $editing) { profile in
            ConnectionEditor(profile: profile, isNew: isNew) { saved in
                store.upsert(saved)
                sessions.drop(saved.id)
                selection = saved.kind == .redis ? .redis(saved.id, .keys) : .rabbit(saved.id, .overview)
            }
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: .constant(confirmDelete != nil), presenting: confirmDelete) { p in
            Button("Delete Connection", role: .destructive) {
                sessions.drop(p.id)
                store.remove(p)
                if selection?.profileID == p.id { selection = nil }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { _ in
            Text("The saved password is removed from your Keychain too. Nothing changes on the server.")
        }
        .onAppear(perform: restoreSelection)
        .onChange(of: selection) { saveSelection() }
        .focusedSceneValue(\.connectionActions, ConnectionActions(add: add))
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .redis(let id, let tab):
            if let p = store.profile(id) {
                RedisDetail(session: sessions.redis(for: p), tab: tab, edit: { edit(p) })
                    .id(p)
            } else {
                welcome
            }
        case .rabbit(let id, let tab):
            if let p = store.profile(id) {
                RabbitDetail(session: sessions.rabbit(for: p), tab: tab, edit: { edit(p) })
                    .id(p)
            } else {
                welcome
            }
        case nil:
            welcome
        }
    }

    private var welcome: some View {
        WelcomeView(hasConnections: !store.profiles.isEmpty, add: add)
    }

    private func add(_ kind: ServerKind) {
        isNew = true
        var p = kind == .redis ? ConnectionProfile.newRedis() : ConnectionProfile.newRabbit()
        let existing = store.profiles.filter { $0.kind == kind }.count
        if existing > 0 { p.name += " \(existing + 1)" }
        editing = p
    }

    private func edit(_ p: ConnectionProfile) {
        isNew = false
        editing = p
    }

    private func restoreSelection() {
        #if DEBUG
        // `--args -startAt rabbit:queues` opens a tab of the first matching connection.
        if let start = UserDefaults.standard.string(forKey: "startAt") {
            let parts = start.split(separator: ":").map(String.init)
            if parts.count == 2, parts[0] == "redis", let t = RedisTab(rawValue: parts[1]),
               let p = store.profiles.first(where: { $0.kind == .redis }) { selection = .redis(p.id, t); return }
            if parts.count == 2, parts[0] == "rabbit", let t = RabbitTab(rawValue: parts[1]),
               let p = store.profiles.first(where: { $0.kind == .rabbitmq }) { selection = .rabbit(p.id, t); return }
        }
        #endif
        guard selection == nil, let s = storedSelection else { return }
        let parts = s.split(separator: "|").map(String.init)
        guard parts.count == 3, let id = UUID(uuidString: parts[1]), store.profile(id) != nil else { return }
        if parts[0] == "redis", let t = RedisTab(rawValue: parts[2]) { selection = .redis(id, t) }
        if parts[0] == "rabbit", let t = RabbitTab(rawValue: parts[2]) { selection = .rabbit(id, t) }
    }

    private func saveSelection() {
        switch selection {
        case .redis(let id, let t): storedSelection = "redis|\(id)|\(t.rawValue)"
        case .rabbit(let id, let t): storedSelection = "rabbit|\(id)|\(t.rawValue)"
        case nil: storedSelection = nil
        }
    }
}

struct ConnectionActions {
    var add: (ServerKind) -> Void
}

extension FocusedValues {
    @Entry var connectionActions: ConnectionActions?
}

private struct Sidebar: View {
    @Environment(ProfileStore.self) private var store
    @Environment(SessionRegistry.self) private var sessions
    @Binding var selection: Destination?
    let edit: (ConnectionProfile) -> Void
    let add: (ServerKind) -> Void
    let delete: (ConnectionProfile) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(store.profiles) { p in
                Section {
                    switch p.kind {
                    case .redis:
                        ForEach(RedisTab.allCases) { t in
                            Label(t.title, systemImage: t.symbol).tag(Destination.redis(p.id, t))
                        }
                    case .rabbitmq:
                        ForEach(RabbitTab.allCases) { t in
                            Label(t.title, systemImage: t.symbol)
                                .badge(t == .queues ? queueBadge(p) : 0)
                                .tag(Destination.rabbit(p.id, t))
                        }
                    }
                } header: {
                    header(p)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.profiles.isEmpty {
                Text("No connections")
                    .foregroundStyle(.tertiary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Redis…", systemImage: ServerKind.redis.symbol) { add(.redis) }
                    Button("RabbitMQ…", systemImage: ServerKind.rabbitmq.symbol) { add(.rabbitmq) }
                } label: {
                    Label("Add Connection", systemImage: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }

    private func header(_ p: ConnectionProfile) -> some View {
        HStack(spacing: 6) {
            Image(systemName: p.kind.symbol)
                .foregroundStyle(p.kind.tint)
            Text(p.name)
                .lineLimit(1)
            EnvironmentBadge(environment: p.environment)
            Spacer()
            if let ok = sessions.isConnected(p.id) {
                Circle()
                    .fill(ok ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .help(ok ? "Connected" : "Not connected")
            }
        }
        .contextMenu {
            Button("Edit…") { edit(p) }
            Button("Reconnect") { sessions.drop(p.id); selection = selection }
            Button("Copy Address") { copyToPasteboard(p.address) }
            Divider()
            Button("Delete…", role: .destructive) { delete(p) }
        }
    }

    private func queueBadge(_ p: ConnectionProfile) -> Int {
        guard let s = sessions.existingRabbit(p.id) else { return 0 }
        return s.queues.filter { $0.looksLikeDeadLetter && $0.depth > 0 }.count
    }
}

private struct WelcomeView: View {
    let hasConnections: Bool
    let add: (ServerKind) -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text(hasConnections ? "Pick a connection" : "Welcome to Spool")
                    .font(.largeTitle.weight(.semibold))
                Text("Browse Redis keys and RabbitMQ queues, peek at messages, and fix what's stuck — natively on your Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 14) {
                ForEach(ServerKind.allCases) { k in
                    Button { add(k) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: k.symbol)
                                .font(.system(size: 26))
                                .foregroundStyle(k.tint)
                            Text("Add \(k.title)")
                                .font(.headline)
                        }
                        .frame(width: 150, height: 96)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
