import Foundation
import Security
import SpoolKit
import SwiftUI

enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case redis, rabbitmq
    var id: String { rawValue }

    var title: String {
        switch self {
        case .redis: "Redis"
        case .rabbitmq: "RabbitMQ"
        }
    }

    var symbol: String {
        switch self {
        case .redis: "cylinder.split.1x2"
        case .rabbitmq: "tray.full"
        }
    }

    var tint: Color {
        switch self {
        case .redis: Color(red: 0.86, green: 0.22, blue: 0.18)
        case .rabbitmq: Color(red: 1.0, green: 0.45, blue: 0.0)
        }
    }
}

/// A saved server. Passwords live in the Keychain, not here.
struct ConnectionProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ServerKind
    var host: String
    var port: Int
    var username: String = ""
    var database: Int = 0
    var tls: Bool = false
    /// Environment label shown next to the name, e.g. "prod".
    var environment: Environment = .local

    enum Environment: String, Codable, CaseIterable, Identifiable {
        case local, dev, staging, prod
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .local: .secondary
            case .dev: .blue
            case .staging: .orange
            case .prod: .red
            }
        }
    }

    static func newRedis() -> ConnectionProfile {
        ConnectionProfile(name: "Local Redis", kind: .redis, host: "localhost", port: 6379)
    }

    static func newRabbit() -> ConnectionProfile {
        ConnectionProfile(name: "Local RabbitMQ", kind: .rabbitmq, host: "localhost", port: 15672, username: "guest")
    }

    var address: String { "\(host):\(port)" }

    var password: String? {
        get { Keychain.read(account: id.uuidString) }
        nonmutating set { Keychain.write(newValue, account: id.uuidString) }
    }

    var redisOptions: RedisConnection.Options {
        RedisConnection.Options(host: host, port: port, username: username.isEmpty ? nil : username,
                                password: password, database: database, tls: tls)
    }

    var rabbitOptions: RabbitClient.Options {
        var c = URLComponents()
        c.scheme = tls ? "https" : "http"
        c.host = host
        c.port = port
        let user = username.isEmpty ? "guest" : username
        // RabbitMQ's default account is guest/guest.
        let pass = password ?? (user == "guest" ? "guest" : "")
        return RabbitClient.Options(baseURL: c.url ?? URL(string: "http://localhost:15672")!, username: user, password: pass)
    }
}

enum Keychain {
    private static let service = "com.anilipeksumer.spool"

    static func read(account: String) -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Spool connection password"
        SecItemAdd(add as CFDictionary, nil)
    }
}

@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile] = []
    private let url: URL

    init() {
        let dir = URL.applicationSupportDirectory.appending(path: "Spool", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "connections.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            profiles = saved
        }
        #if DEBUG
        // `open Spool.app --args -seedDemo 6399` adds local test servers.
        let port = UserDefaults.standard.integer(forKey: "seedDemo")
        if port > 0, profiles.isEmpty {
            var redis = ConnectionProfile.newRedis()
            redis.name = "Cache"
            redis.port = port
            var rabbit = ConnectionProfile.newRabbit()
            rabbit.name = "Order Events"
            rabbit.environment = .dev
            profiles = [redis, rabbit]
            save()
        }
        #endif
    }

    func profile(_ id: UUID?) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func upsert(_ profile: ConnectionProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func remove(_ profile: ConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        profile.password = nil
        save()
    }

    func move(from source: IndexSet, to destination: Int, kind: ServerKind) {
        var ofKind = profiles.filter { $0.kind == kind }
        ofKind.move(fromOffsets: source, toOffset: destination)
        profiles = profiles.filter { $0.kind != kind } + ofKind
        profiles.sort { ($0.kind == .redis ? 0 : 1) < ($1.kind == .redis ? 0 : 1) }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(profiles).write(to: url, options: .atomic)
    }
}
