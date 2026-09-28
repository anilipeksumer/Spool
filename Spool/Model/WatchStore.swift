import Foundation
import SpoolKit
import UserNotifications

/// Queues shown in the menu bar, with an alert when they grow past a limit.
@Observable
final class WatchStore {
    struct Watch: Codable, Hashable, Identifiable {
        var id: String { "\(profileID)|\(vhost)|\(queue)" }
        var profileID: UUID
        var vhost: String
        var queue: String
        var threshold: Int64
    }

    private(set) var watches: [Watch] = []
    /// Watches that are over their limit right now, so we alert once per crossing.
    @ObservationIgnored private var alerting: Set<String> = []
    private let key = "watches"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let w = try? JSONDecoder().decode([Watch].self, from: d) {
            watches = w
        }
    }

    var profileIDs: Set<UUID> { Set(watches.map(\.profileID)) }

    func isWatched(_ q: RabbitQueue, profile: UUID) -> Bool {
        watches.contains { $0.profileID == profile && $0.queue == q.name && $0.vhost == q.vhost }
    }

    func toggle(_ q: RabbitQueue, profile: ConnectionProfile) {
        if isWatched(q, profile: profile.id) {
            watches.removeAll { $0.profileID == profile.id && $0.queue == q.name && $0.vhost == q.vhost }
        } else {
            let limit: Int64 = q.looksLikeDeadLetter ? 1 : max(100, q.depth * 2)
            watches.append(Watch(profileID: profile.id, vhost: q.vhost, queue: q.name, threshold: limit))
            requestNotificationPermission()
        }
        save()
    }

    func setThreshold(_ value: Int64, for watch: Watch) {
        guard let i = watches.firstIndex(of: watch) else { return }
        watches[i].threshold = max(1, value)
        save()
    }

    func remove(_ watch: Watch) {
        watches.removeAll { $0.id == watch.id }
        save()
    }

    func remove(profile: UUID) {
        watches.removeAll { $0.profileID == profile }
        save()
    }

    /// Called after each refresh of a RabbitMQ session.
    func evaluate(_ session: RabbitSession) {
        for w in watches where w.profileID == session.profile.id {
            guard let q = session.queues.first(where: { $0.name == w.queue && $0.vhost == w.vhost }) else { continue }
            if q.depth >= w.threshold {
                if alerting.insert(w.id).inserted { notify(w, depth: q.depth, server: session.profile.name) }
            } else {
                alerting.remove(w.id)
            }
        }
    }

    func isAlerting(_ w: Watch) -> Bool { alerting.contains(w.id) }

    private func notify(_ w: Watch, depth: Int64, server: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(w.queue) has \(depth.formatted()) messages"
        content.body = "Over your limit of \(w.threshold.formatted()) on \(server)."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: w.id, content: content, trigger: nil))
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(watches) { UserDefaults.standard.set(d, forKey: key) }
    }
}
