import SpoolKit
import SwiftUI

struct KeyDetailView: View {
    let session: RedisSession
    let key: String
    @Binding var toast: Toast?
    @State private var value: RedisValue?
    @State private var loadError: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var editingTTL = false
    @State private var confirmDelete = false

    private var info: RedisKeyInfo? { session.keyInfo[key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            Group {
                if let loadError {
                    Placeholder(title: "Couldn't Load Value", symbol: "exclamationmark.triangle", message: loadError)
                } else if let value {
                    content(value)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await load() }
        .confirmationDialog("Delete “\(key)”?", isPresented: $confirmDelete) {
            Button("Delete Key", role: .destructive) {
                Task { await run("Deleted \(key)") { _ in try await session.delete([key]) } }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TypeBadge(type: info?.type)
                Text(key)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Button { newName = key; renaming = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename")
                    .popover(isPresented: $renaming, arrowEdge: .bottom) { renamePopover }
                Spacer()
                ControlGroup {
                    Button("Copy Name", systemImage: "doc.on.doc") { copyToPasteboard(key); toast = Toast(text: "Copied") }
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
                .fixedSize()
            }
            HStack(spacing: 18) {
                meta("Size", Format.bytes(info?.memory))
                if let n = info?.length {
                    meta(info?.type == .string ? "Length" : "Items", n.formatted())
                }
                Button { editingTTL = true } label: {
                    meta("TTL", Format.ttl(info?.ttl), tint: info?.ttl == nil ? .secondary : .orange)
                }
                .buttonStyle(.plain)
                .help("Change expiry")
                .popover(isPresented: $editingTTL, arrowEdge: .bottom) {
                    TTLEditor(current: info?.ttl) { seconds in
                        editingTTL = false
                        Task { await run(seconds == nil ? "Expiry removed" : "Expires in \(Format.ttl(seconds))") { try await $0.expire(key, seconds: seconds) } }
                    }
                }
            }
        }
    }

    private func meta(_ title: String, _ value: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.tertiary)
            Text(value).monospacedDigit().foregroundStyle(tint)
        }
        .font(.callout)
    }

    private var renamePopover: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField("New name", text: $newName)
                .frame(width: 320)
                .onSubmit(commitRename)
            HStack {
                Button("Cancel") { renaming = false }
                Button("Rename", action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.isEmpty || newName == key)
            }
        }
        .padding(14)
    }

    private func commitRename() {
        guard !newName.isEmpty, newName != key else { return }
        renaming = false
        let target = newName
        Task {
            do {
                try await session.rename(key, to: target)
            } catch {
                toast = Toast(text: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ value: RedisValue) -> some View {
        switch value {
        case .string(let data):
            StringEditor(data: data) { text in
                await run("Saved") { try await $0.setString(key, text) }
            }
        case .hash(let pairs):
            CollectionEditor(
                columns: ["Field", "Value"],
                rows: pairs.enumerated().map { i, p in .init(id: "\(i)", cells: [p.field, p.value.displayString], value: p.value) },
                truncated: pairs.count >= RedisClient.valueLimit,
                addForm: [.init("Field"), .init("Value", multiline: true)],
                editForm: { r in [.init("Field", r.cells[0], locked: true), .init("Value", r.value.displayString, multiline: true)] },
                add: { f in await run("Field saved") { try await $0.hashSet(key, field: f[0], value: f[1]) } },
                edit: { _, f in await run("Field saved") { try await $0.hashSet(key, field: f[0], value: f[1]) } },
                delete: { row in await run("Field deleted") { try await $0.hashDelete(key, field: row.cells[0]) } })
        case .list(let items):
            CollectionEditor(
                columns: ["#", "Value"],
                rows: items.enumerated().map { i, v in .init(id: "\(i)", cells: ["\(i)", v.displayString], value: v) },
                truncated: items.count >= RedisClient.valueLimit,
                addForm: [.init("Value", multiline: true)],
                editForm: { r in [.init("Index", r.cells[0], locked: true), .init("Value", r.value.displayString, multiline: true)] },
                add: { f in await run("Appended") { try await $0.listPush(key, f[0]) } },
                edit: { row, f in await run("Saved") { try await $0.listSet(key, index: Int(row.cells[0]) ?? 0, f[1]) } },
                delete: { row in await run("Removed") { try await $0.listRemove(key, index: Int(row.cells[0]) ?? 0) } })
        case .set(let members):
            CollectionEditor(
                columns: ["Member"],
                rows: members.enumerated().map { i, m in .init(id: "\(i)", cells: [m.displayString], value: m) },
                truncated: members.count >= RedisClient.valueLimit,
                addForm: [.init("Member", multiline: true)],
                editForm: nil,
                add: { f in await run("Added") { try await $0.setAdd(key, f[0]) } },
                edit: nil,
                delete: { row in await run("Removed") { try await $0.setRemove(key, row.value) } })
        case .zset(let items):
            CollectionEditor(
                columns: ["Score", "Member"],
                rows: items.enumerated().map { i, it in .init(id: "\(i)", cells: [Format.score(it.score), it.member.displayString], value: it.member) },
                truncated: items.count >= RedisClient.valueLimit,
                addForm: [.init("Score"), .init("Member", multiline: true)],
                editForm: { r in [.init("Score", r.cells[0]), .init("Member", r.cells[1], locked: true)] },
                add: { f in await run("Added") { try await $0.zsetAdd(key, f[1], score: Double(f[0]) ?? 0) } },
                edit: { _, f in await run("Saved") { try await $0.zsetAdd(key, f[1], score: Double(f[0]) ?? 0) } },
                delete: { row in await run("Removed") { try await $0.zsetRemove(key, row.value) } })
        case .stream(let entries):
            CollectionEditor(
                columns: ["ID", "Fields"],
                rows: entries.map { e in
                    let text = e.fields.map { "\($0.0)=\($0.1)" }.joined(separator: "  ")
                    let json = "{" + e.fields.map { "\"\($0.0)\":\(jsonLiteral($0.1))" }.joined(separator: ",") + "}"
                    return .init(id: e.id, cells: [e.id, text], value: Data(json.utf8))
                },
                truncated: entries.count >= RedisClient.valueLimit,
                addForm: [.init("Field"), .init("Value", multiline: true)],
                editForm: nil,
                add: { f in await run("Entry added") { try await $0.streamAdd(key, fields: [(f[0], f[1])]) } },
                edit: nil,
                delete: { row in await run("Entry deleted") { try await $0.streamDelete(key, id: row.cells[0]) } })
        case .json(let text):
            CodeText(text: JSONFormatter.pretty(text) ?? text)
                .padding(16)
        case .missing:
            Placeholder(title: "Key No Longer Exists", symbol: "questionmark.folder",
                        message: "It may have expired or been deleted by another client.")
        }
    }

    private func jsonLiteral(_ s: String) -> String {
        if let d = s.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed)) != nil, s.first != "\"" || s.last == "\"" {
            return s
        }
        let escaped = (try? JSONSerialization.data(withJSONObject: [s])).map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }
        return escaped.map(String.init) ?? "\"\""
    }

    // MARK: Actions

    private func load() async {
        loadError = nil
        do {
            await session.refreshKey(key)
            let type = session.keyInfo[key]?.type ?? .none
            value = try await session.perform { try await $0.value(of: key, type: type) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func run(_ success: String, _ body: @escaping (RedisClient) async throws -> Void) async {
        do {
            try await session.perform(body)
            toast = Toast(text: success)
            if session.selectedKey == key { await load() }
        } catch {
            toast = Toast(text: error.localizedDescription, isError: true)
        }
    }
}

extension Format {
    static func score(_ v: Double) -> String {
        v.rounded() == v && abs(v) < 1e15 ? String(Int64(v)) : String(v)
    }
}

// MARK: - String value

private struct StringEditor: View {
    let data: Data
    let save: (String) async -> Void
    @State private var draft = ""
    @State private var original = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            if data.isText {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
            } else {
                CodeText(text: data.displayString).padding(16)
            }
            Divider()
            HStack {
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isJSON {
                    Button("Format JSON") { if let p = JSONFormatter.pretty(draft) { draft = p } }
                    Button("Minify") { draft = minified(draft) }
                }
                Button("Revert") { draft = original }
                    .disabled(draft == original)
                Button("Save") {
                    saving = true
                    // JSON stored compact is saved compact again; the
                    // formatting is only for reading.
                    let stored = data.displayString
                    let text = !stored.contains("\n") ? (JSONFormatter.minified(draft) ?? draft) : draft
                    Task {
                        await save(text)
                        saving = false
                    }
                }
                .keyboardShortcut("s")
                .buttonStyle(.glassProminent)
                .disabled(draft == original || saving || !data.isText)
            }
            .padding(10)
        }
        .onAppear {
            let s = data.displayString
            original = s
            draft = JSONFormatter.pretty(s) ?? s
            // Formatting alone isn't an edit worth saving.
            if draft != s { original = draft }
        }
    }

    private var isJSON: Bool { JSONFormatter.pretty(draft) != nil }

    private var kind: String {
        if !data.isText { return "Binary · \(data.count.formatted()) bytes" }
        return (isJSON ? "JSON" : "Text") + " · \(data.count.formatted()) bytes"
    }

    private func minified(_ s: String) -> String {
        JSONFormatter.minified(s) ?? s
    }
}

// MARK: - Collections

struct CollectionRow: Identifiable, Hashable {
    let id: String
    let cells: [String]
    let value: Data
}

private struct CollectionEditor: View {
    let columns: [String]
    let rows: [CollectionRow]
    let truncated: Bool
    let addForm: [FormField]
    let editForm: ((CollectionRow) -> [FormField])?
    let add: ([String]) async -> Void
    let edit: ((CollectionRow, [String]) async -> Void)?
    let delete: (CollectionRow) async -> Void

    @State private var selection: CollectionRow.ID?
    @State private var filter = ""
    @State private var sheet: SheetMode?

    enum SheetMode: Identifiable {
        case add, edit(CollectionRow)
        var id: String {
            switch self {
            case .add: "add"
            case .edit(let r): "edit-\(r.id)"
            }
        }
    }

    private var visible: [CollectionRow] {
        guard !filter.isEmpty else { return rows }
        return rows.filter { $0.cells.contains { $0.localizedCaseInsensitiveContains(filter) } }
    }

    private var selected: CollectionRow? { rows.first { $0.id == selection } }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter", text: $filter).textFieldStyle(.plain)
                    Spacer()
                    Button("Add", systemImage: "plus") { sheet = .add }
                    if editForm != nil {
                        Button("Edit", systemImage: "pencil") { if let s = selected { sheet = .edit(s) } }
                            .disabled(selected == nil)
                    }
                    Button("Delete", systemImage: "minus") {
                        if let s = selected { Task { await delete(s) } }
                    }
                    .disabled(selected == nil)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Table(visible, selection: $selection) {
                    TableColumnForEach(columns.indices, id: \.self) { i in
                        TableColumn(columns[i]) { row in
                            Text(row.cells[i])
                                .lineLimit(1)
                                .font(i == 0 && columns.count > 1 ? .body.monospacedDigit() : .body)
                        }
                        .width(min: i == 0 && columns.count > 1 ? 60 : 120, ideal: i == 0 && columns.count > 1 ? 140 : 300)
                    }
                }
                .contextMenu(forSelectionType: CollectionRow.ID.self) { ids in
                    if let r = rows.first(where: { ids.contains($0.id) }) {
                        Button("Copy Value") { copyToPasteboard(r.value.displayString) }
                        if editForm != nil { Button("Edit…") { sheet = .edit(r) } }
                        Divider()
                        Button("Delete", role: .destructive) { Task { await delete(r) } }
                    }
                } primaryAction: { ids in
                    if editForm != nil, let r = rows.first(where: { ids.contains($0.id) }) { sheet = .edit(r) }
                }
                if truncated {
                    Text("Showing the first \(RedisClient.valueLimit.formatted()) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .frame(minHeight: 160)

            Group {
                if let s = selected {
                    CodeText(text: JSONFormatter.pretty(s.value) ?? s.value.displayString)
                } else {
                    Text("Select a row to see its full value")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(12)
            .frame(minHeight: 100, idealHeight: 200)
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .add:
                ItemSheet(title: "Add Item", saveTitle: "Add", fields: addForm) { await add($0) }
            case .edit(let row):
                ItemSheet(title: "Edit Item", saveTitle: "Save", fields: editForm?(row) ?? []) { await edit?(row, $0) }
            }
        }
    }
}

struct FormField {
    var label: String
    var value: String
    var locked = false
    var multiline = false

    init(_ label: String, _ value: String = "", locked: Bool = false, multiline: Bool = false) {
        self.label = label
        self.value = value
        self.locked = locked
        self.multiline = multiline
    }
}

private struct ItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let saveTitle: String
    let fields: [FormField]
    let commit: ([String]) async -> Void
    @State private var values: [String]
    @State private var saving = false

    init(title: String, saveTitle: String, fields: [FormField], commit: @escaping ([String]) async -> Void) {
        self.title = title
        self.saveTitle = saveTitle
        self.fields = fields
        self.commit = commit
        _values = State(initialValue: fields.map(\.value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(fields.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fields[i].label).font(.caption).foregroundStyle(.secondary)
                    if fields[i].multiline && !fields[i].locked {
                        TextEditor(text: $values[i])
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(.background.secondary, in: .rect(cornerRadius: 6))
                    } else {
                        TextField(fields[i].label, text: $values[i])
                            .font(.system(.body, design: .monospaced))
                            .disabled(fields[i].locked)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveTitle) {
                    saving = true
                    Task {
                        await commit(values)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

// MARK: - TTL

private struct TTLEditor: View {
    let current: Int64?
    let apply: (Int64?) -> Void
    @State private var amount = 1
    @State private var unit: Int64 = 3600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Expire key").font(.headline)
            HStack {
                ForEach([(60, "1 min"), (3600, "1 hour"), (86400, "1 day"), (604800, "1 week")], id: \.0) { s, label in
                    Button(label) { apply(Int64(s)) }
                }
            }
            HStack {
                TextField("Amount", value: $amount, format: .number)
                    .frame(width: 70)
                Picker("", selection: $unit) {
                    Text("seconds").tag(Int64(1))
                    Text("minutes").tag(Int64(60))
                    Text("hours").tag(Int64(3600))
                    Text("days").tag(Int64(86400))
                }
                .labelsHidden()
                .fixedSize()
                Button("Set") { apply(Int64(max(1, amount)) * unit) }
                    .keyboardShortcut(.defaultAction)
            }
            if current != nil {
                Divider()
                Button("Remove Expiry", systemImage: "infinity") { apply(nil) }
            }
        }
        .padding(14)
    }
}
