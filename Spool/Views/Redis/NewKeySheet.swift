import SpoolKit
import SwiftUI

struct NewKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: RedisSession
    let created: (String) -> Void

    @State private var name = ""
    @State private var type: RedisKeyType = .string
    @State private var first = ""
    @State private var second = ""
    @State private var expires = false
    @State private var ttlHours = 24
    @State private var error: String?
    @State private var saving = false

    private let types: [RedisKeyType] = [.string, .hash, .list, .set, .zset, .stream]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("user:42:profile"))
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) { Text($0.label).tag($0) }
                }
                switch type {
                case .hash, .stream:
                    TextField("Field", text: $first)
                    TextField("Value", text: $second, axis: .vertical).lineLimit(3...8)
                case .zset:
                    TextField("Score", text: $first, prompt: Text("0"))
                    TextField("Member", text: $second)
                case .list, .set:
                    TextField(type == .set ? "Member" : "First item", text: $first, axis: .vertical).lineLimit(1...6)
                default:
                    TextField("Value", text: $first, axis: .vertical)
                        .lineLimit(4...12)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("Expires", isOn: $expires)
                if expires {
                    Stepper("After \(ttlHours) hour\(ttlHours == 1 ? "" : "s")", value: $ttlHours, in: 1...8760)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || saving || (type != .string && first.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 440)
    }

    private func create() async {
        saving = true
        defer { saving = false }
        error = nil
        do {
            try await session.perform { c in
                if try await c.exists(name) { throw RedisError("“\(name)” already exists.") }
                switch type {
                case .hash: try await c.hashSet(name, field: first, value: second)
                case .stream: try await c.streamAdd(name, fields: [(first, second)])
                case .zset: try await c.zsetAdd(name, second, score: Double(first) ?? 0)
                case .list: try await c.listPush(name, first)
                case .set: try await c.setAdd(name, first)
                default: try await c.setString(name, first, keepTTL: false)
                }
                if expires { try await c.expire(name, seconds: Int64(ttlHours) * 3600) }
            }
            await session.refreshKey(name)
            session.selectedKey = name
            created(name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
