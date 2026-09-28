import SpoolKit
import SwiftUI

struct KeysView: View {
    @Bindable var session: RedisSession
    @AppStorage("keysAsTree") private var asTree = true
    @State private var addingKey = false
    @State private var toast: Toast?

    var body: some View {
        HSplitView {
            KeyList(session: session, asTree: asTree)
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 560)
            Group {
                if let key = session.selectedKey {
                    KeyDetailView(session: session, key: key, toast: $toast)
                        .id(key)
                } else {
                    Placeholder(title: "No Key Selected", symbol: "key",
                                message: session.keys.isEmpty ? nil : "Choose a key to see and edit its value.")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toast($toast)
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $asTree) {
                    Label("Tree", systemImage: "list.bullet.indent").tag(true)
                    Label("List", systemImage: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Group keys by “:”")
                Button("Refresh", systemImage: "arrow.clockwise") { session.reloadKeys() }
                    .keyboardShortcut("r")
                Button("New Key", systemImage: "plus") { addingKey = true }
                    .keyboardShortcut("n")
            }
        }
        .sheet(isPresented: $addingKey) {
            NewKeySheet(session: session) { name in
                toast = Toast(text: "Created \(name)")
            }
        }
    }
}

private struct KeyList: View {
    @Bindable var session: RedisSession
    let asTree: Bool
    @State private var selection: String?
    @State private var confirmDelete: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            Group {
                if session.keys.isEmpty && !session.isScanning {
                    Placeholder(title: session.pattern.isEmpty && session.typeFilter == nil ? "No Keys" : "No Matches",
                                symbol: "magnifyingglass",
                                message: session.pattern.isEmpty ? "This database is empty." : "Nothing matches “\(session.pattern)”.")
                } else if asTree {
                    List(KeyNode.tree(session.keys), children: \.children, selection: $selection) { node in
                        row(node)
                    }
                } else {
                    List(session.keys, id: \.self, selection: $selection) { key in
                        KeyRow(session: session, key: key, label: key)
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                let keys = ids.filter { !$0.hasPrefix(KeyNode.folderPrefix) }
                if !keys.isEmpty {
                    Button("Copy Name") { copyToPasteboard(keys.joined(separator: "\n")) }
                    Divider()
                    Button(keys.count == 1 ? "Delete…" : "Delete \(keys.count) Keys…", role: .destructive) {
                        confirmDelete = Array(keys)
                    }
                }
            }
            .onDeleteCommand {
                if let s = session.selectedKey { confirmDelete = [s] }
            }
            Divider()
            footer
        }
        .onChange(of: selection) { _, new in
            if let new, !new.hasPrefix(KeyNode.folderPrefix) { session.selectedKey = new }
        }
        .onChange(of: session.selectedKey) { _, new in
            if selection != new { selection = new }
        }
        .onAppear {
            #if DEBUG
            if let k = UserDefaults.standard.string(forKey: "selectItem"), session.selectedKey == nil { session.selectedKey = k }
            #endif
            selection = session.selectedKey
        }
        .confirmationDialog(confirmDelete.count == 1 ? "Delete “\(confirmDelete[0])”?" : "Delete \(confirmDelete.count) keys?",
                            isPresented: .constant(!confirmDelete.isEmpty)) {
            Button("Delete", role: .destructive) {
                let keys = confirmDelete
                confirmDelete = []
                Task { try? await session.delete(keys) }
            }
            Button("Cancel", role: .cancel) { confirmDelete = [] }
        } message: {
            Text("This can't be undone.")
        }
    }

    @ViewBuilder private func row(_ node: KeyNode) -> some View {
        if let key = node.key {
            KeyRow(session: session, key: key, label: node.name)
        } else {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(node.name)
                Spacer()
                Text(node.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter keys — user:* or text", text: $session.pattern)
                .textFieldStyle(.plain)
                .onSubmit { session.reloadKeys() }
            if !session.pattern.isEmpty {
                Button { session.pattern = ""; session.reloadKeys() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Menu {
                Picker("Type", selection: $session.typeFilter) {
                    Text("All Types").tag(RedisKeyType?.none)
                    Divider()
                    ForEach(RedisKeyType.allCases.filter { $0 != .none }, id: \.self) { t in
                        Text(t.label).tag(RedisKeyType?.some(t))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: session.typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by type")
            .onChange(of: session.typeFilter) { session.reloadKeys() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .task(id: session.pattern) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { session.reloadKeys() }
        }
    }

    private var footer: some View {
        HStack {
            if session.isScanning {
                ProgressView().controlSize(.mini)
                Text("Scanning…")
            } else {
                Text("\(session.keys.count.formatted()) keys")
                if !session.scanComplete {
                    Text("· first 10,000")
                        .help("Narrow the filter to see the rest")
                }
            }
            Spacer()
            if let size = session.info?.keyspace.first(where: { $0.db == session.profile.database })?.keys {
                Text("\(size.formatted()) in db\(session.profile.database)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct KeyRow: View {
    let session: RedisSession
    let key: String
    let label: String

    var body: some View {
        let info = session.keyInfo[key]
        HStack(spacing: 8) {
            TypeBadge(type: info?.type)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let ttl = info?.ttl {
                Label(Format.ttl(ttl), systemImage: "timer")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ttl < 60 ? .orange : .secondary)
            }
        }
        .help(key)
        .onAppear { session.describe(key) }
    }
}

/// Keys grouped by their “:” segments, like folders.
struct KeyNode: Identifiable {
    static let folderPrefix = "\u{1}folder:"
    let id: String
    let name: String
    let key: String?
    var count: Int
    var children: [KeyNode]?

    static func tree(_ keys: [String], separator: Character = ":") -> [KeyNode] {
        final class Builder {
            var keys: [String: String] = [:]   // leaf name → full key
            var folders: [String: Builder] = [:]
            var count = 0
        }
        let root = Builder()
        for key in keys {
            var node = root
            let parts = key.split(separator: separator, omittingEmptySubsequences: false)
            node.count += 1
            for part in parts.dropLast() {
                let name = String(part)
                let next = node.folders[name] ?? Builder()
                node.folders[name] = next
                node = next
                node.count += 1
            }
            node.keys[String(parts.last ?? "")] = key
        }
        func build(_ b: Builder, prefix: String) -> [KeyNode] {
            let folders = b.folders.map { name, sub -> KeyNode in
                let p = prefix + name + String(separator)
                // A folder holding a single key collapses into that key.
                if sub.count == 1, sub.folders.isEmpty, let (_, full) = sub.keys.first {
                    return KeyNode(id: full, name: String(full.dropFirst(prefix.count)), key: full, count: 1, children: nil)
                }
                return KeyNode(id: folderPrefix + p, name: name.isEmpty ? "(empty)" : name, key: nil, count: sub.count,
                               children: build(sub, prefix: p))
            }
            let leaves = b.keys.map { name, full in
                KeyNode(id: full, name: name.isEmpty ? "(empty)" : name, key: full, count: 1, children: nil)
            }
            return (folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    + leaves.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        return build(root, prefix: "")
    }
}
