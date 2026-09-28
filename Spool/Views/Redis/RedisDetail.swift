import SpoolKit
import SwiftUI

struct RedisDetail: View {
    @Bindable var session: RedisSession
    let tab: RedisTab
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
                switch tab {
                case .keys: KeysView(session: session)
                case .server: RedisServerView(session: session)
                case .console: ConsoleView(session: session)
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
        if session.profile.database != 0 { s += " · db\(session.profile.database)" }
        if let v = session.info?.version { s += " · Redis \(v)" }
        return s
    }
}
