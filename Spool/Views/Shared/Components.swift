import Charts
import SpoolKit
import SwiftUI

extension RedisKeyType {
    var color: Color {
        switch self {
        case .string: .blue
        case .hash: .purple
        case .list: .green
        case .set: .orange
        case .zset: .pink
        case .stream: .teal
        case .json: .indigo
        case .none: .gray
        }
    }
}

struct TypeBadge: View {
    let type: RedisKeyType?

    var body: some View {
        Text(type?.short ?? "···")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(type?.color ?? .secondary)
            .frame(width: 42, height: 16)
            .background((type?.color ?? .gray).opacity(0.15), in: .capsule)
    }
}

struct EnvironmentBadge: View {
    let environment: ConnectionProfile.Environment

    var body: some View {
        if environment != .local {
            Text(environment.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(environment.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(environment.color.opacity(0.5)))
        }
    }
}

/// A labelled number, used in the overview grids.
struct StatTile<Accessory: View>: View {
    let title: String
    let value: String
    var detail: String?
    var tint: Color = .primary
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

extension StatTile where Accessory == EmptyView {
    init(title: String, value: String, detail: String? = nil, tint: Color = .primary) {
        self.init(title: title, value: value, detail: detail, tint: tint) { EmptyView() }
    }
}

/// A card with a title, for grouping sections of a dashboard.
struct Card<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

extension Card where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

struct Series: Identifiable {
    let id: String
    let color: Color
    let points: [(Date, Double)]
}

/// A small live line chart for rates and depths.
struct LiveChart: View {
    let series: [Series]
    var height: CGFloat = 140
    var unit: String = ""

    var body: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points, id: \.0) { p in
                    LineMark(x: .value("Time", p.0), y: .value(s.id, p.1), series: .value("Series", s.id))
                        .foregroundStyle(s.color)
                        .interpolationMethod(.monotone)
                    if series.count == 1 {
                        AreaMark(x: .value("Time", p.0), y: .value(s.id, p.1))
                            .foregroundStyle(.linearGradient(colors: [s.color.opacity(0.25), s.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.id), range: series.map(\.color))
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(Format.compact(d) + unit) }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .frame(height: height)
        .animation(.smooth, value: series.first?.points.count)
    }
}

/// Shown in place of content: nothing selected, no data, or an error.
struct Placeholder: View {
    let title: String
    let symbol: String
    var message: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message).textSelection(.enabled) }
        } actions: {
            if let action {
                Button(action.title, action: action.run)
            }
        }
    }
}

struct ConnectionFailedView: View {
    let profile: ConnectionProfile
    let message: String
    let retry: () -> Void
    let edit: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't connect to \(profile.name)", systemImage: "bolt.horizontal.circle")
        } description: {
            VStack(spacing: 4) {
                Text(message).textSelection(.enabled)
                Text(profile.address).font(.callout.monospaced()).foregroundStyle(.tertiary)
            }
        } actions: {
            HStack {
                Button("Try Again", action: retry).keyboardShortcut(.defaultAction)
                Button("Edit Connection…", action: edit)
            }
        }
    }
}

/// A transient message at the bottom of a view.
struct Toast: Equatable {
    var text: String
    var isError = false
}

struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                Label(toast.text, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(toast.isError ? 5 : 2.5))
                        withAnimation { self.toast = nil }
                    }
                    .onTapGesture { withAnimation { self.toast = nil } }
            }
        }
        .animation(.snappy, value: toast)
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View { modifier(ToastModifier(toast: toast)) }
}

enum Format {
    static func compact(_ v: Double) -> String {
        switch abs(v) {
        case 1_000_000_000...: String(format: "%.1fG", v / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", v / 1_000_000)
        case 10_000...: String(format: "%.0fk", v / 1_000)
        case 1_000...: String(format: "%.1fk", v / 1_000)
        case 0: "0"
        case ..<10: v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
        default: String(Int(v.rounded()))
        }
    }

    static func count(_ v: Int64?) -> String {
        guard let v else { return "–" }
        return v.formatted(.number)
    }

    static func rate(_ v: Double) -> String {
        v < 0.05 ? "0/s" : (v < 10 ? String(format: "%.1f/s", v) : "\(Int(v.rounded()))/s")
    }

    static func bytes(_ v: Int64?) -> String {
        guard let v else { return "–" }
        return ByteFormat.string(v)
    }

    static func duration(seconds: Int64) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    static func ttl(_ v: Int64?) -> String {
        guard let v else { return "∞" }
        return duration(seconds: v)
    }
}

/// Monospaced, selectable, scrollable text for values and payloads.
struct CodeText: View {
    let text: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}

extension Data {
    /// UTF-8 text when it is valid, otherwise a hex dump.
    var displayString: String {
        if let s = String(data: self, encoding: .utf8) { return s }
        return "<binary \(count) bytes> " + prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    var isText: Bool { String(data: self, encoding: .utf8) != nil }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
