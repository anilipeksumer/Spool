import SpoolKit
import SwiftUI

struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ConnectionProfile
    @State private var password: String
    @State private var test: TestState = .idle
    let isNew: Bool
    let save: (ConnectionProfile) -> Void

    enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    init(profile: ConnectionProfile, isNew: Bool, save: @escaping (ConnectionProfile) -> Void) {
        _profile = State(initialValue: profile)
        _password = State(initialValue: profile.password ?? "")
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $profile.name)
                    Picker("Environment", selection: $profile.environment) {
                        ForEach(ConnectionProfile.Environment.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Label(isNew ? "New \(profile.kind.title) Connection" : profile.kind.title, systemImage: profile.kind.symbol)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                Section(profile.kind == .rabbitmq ? "Management API" : "Server") {
                    TextField("Host", text: $profile.host, prompt: Text("localhost"))
                        .textContentType(.URL)
                    TextField("Port", value: $profile.port, format: .number.grouping(.never))
                    if profile.kind == .redis {
                        Stepper("Database \(profile.database)", value: $profile.database, in: 0...15)
                    }
                    Toggle(profile.kind == .rabbitmq ? "Use HTTPS" : "Use TLS", isOn: $profile.tls)
                }

                Section("Sign In") {
                    TextField("Username", text: $profile.username, prompt: Text(profile.kind == .redis ? "default" : "guest"))
                        .textContentType(.username)
                    SecureField("Password", text: $password, prompt: Text(profile.kind == .redis ? "None" : "guest"))
                        .textContentType(.password)
                }

                if profile.environment == .prod {
                    Label("Production connections are marked in red in the sidebar and when publishing.", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .onChange(of: profile.tls) { _, tls in
                if profile.kind == .rabbitmq, profile.port == 15672 || profile.port == 15671 {
                    profile.port = tls ? 15671 : 15672
                }
            }

            HStack {
                testResult
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    var p = profile
                    p.name = p.name.trimmingCharacters(in: .whitespaces)
                    if p.name.isEmpty { p.name = p.host }
                    p.password = password
                    save(p)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var testResult: some View {
        HStack(spacing: 8) {
            Button("Test") { Task { await runTest() } }
                .disabled(test == .running)
            switch test {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small)
            case .ok(let s):
                Label(s, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            case .failed(let s):
                Label(s, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(s)
            }
        }
        .font(.callout)
    }

    private func runTest() async {
        test = .running
        var p = profile
        p.id = UUID() // don't touch the saved password while testing
        p.password = password
        defer { p.password = nil }
        do {
            switch p.kind {
            case .redis:
                let c = try await RedisClient.connect(p.redisOptions)
                let rtt = try await c.ping()
                let info = try await c.info()
                c.connection.close()
                let ms = Double(rtt.components.attoseconds) / 1e15 + Double(rtt.components.seconds) * 1000
                test = .ok("Redis \(info.version) · \(String(format: "%.1f", ms)) ms")
            case .rabbitmq:
                let o = try await RabbitClient(p.rabbitOptions).overview()
                test = .ok("RabbitMQ \(o.rabbitmqVersion ?? "")")
            }
        } catch {
            test = .failed(error.localizedDescription)
        }
    }
}
