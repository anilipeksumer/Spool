import Foundation

public struct RateDetails: Sendable, Hashable, Codable {
    public var rate: Double
}

public struct MessageStats: Sendable, Hashable, Codable {
    public var publishDetails: RateDetails?
    public var deliverGetDetails: RateDetails?
    public var ackDetails: RateDetails?
    public var redeliverDetails: RateDetails?
    public var publishInDetails: RateDetails?
    public var publishOutDetails: RateDetails?
    public var publish: Int64?
    public var deliverGet: Int64?
    public var ack: Int64?

    public var publishRate: Double { publishDetails?.rate ?? publishInDetails?.rate ?? 0 }
    public var deliverRate: Double { deliverGetDetails?.rate ?? publishOutDetails?.rate ?? 0 }
    public var ackRate: Double { ackDetails?.rate ?? 0 }
}

public struct RabbitOverview: Sendable, Hashable, Codable {
    public struct QueueTotals: Sendable, Hashable, Codable {
        public var messages: Int64?
        public var messagesReady: Int64?
        public var messagesUnacknowledged: Int64?
    }
    public struct ObjectTotals: Sendable, Hashable, Codable {
        public var connections: Int
        public var channels: Int
        public var queues: Int
        public var exchanges: Int
        public var consumers: Int
    }
    public var rabbitmqVersion: String?
    public var erlangVersion: String?
    public var clusterName: String?
    public var node: String?
    public var messageStats: MessageStats?
    public var queueTotals: QueueTotals?
    public var objectTotals: ObjectTotals?
}

public struct RabbitQueue: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(vhost)/\(name)" }
    public var name: String
    public var vhost: String
    public var type: String?
    public var state: String?
    public var durable: Bool?
    public var autoDelete: Bool?
    public var exclusive: Bool?
    public var messages: Int64?
    public var messagesReady: Int64?
    public var messagesUnacknowledged: Int64?
    public var consumers: Int?
    public var memory: Int64?
    public var node: String?
    public var idleSince: String?
    public var arguments: [String: JSONValue]?
    public var messageStats: MessageStats?

    public var depth: Int64 { messages ?? ((messagesReady ?? 0) + (messagesUnacknowledged ?? 0)) }
    public var deadLetterExchange: String? { arguments?["x-dead-letter-exchange"]?.stringValue }
    public var deadLetterRoutingKey: String? { arguments?["x-dead-letter-routing-key"]?.stringValue }
    /// Heuristic: queues named like dead-letter queues.
    public var looksLikeDeadLetter: Bool {
        let n = name.lowercased()
        return n.hasSuffix(".dlq") || n.hasSuffix("-dlq") || n.hasSuffix("_dlq") || n.hasSuffix(".dead")
            || n.contains("deadletter") || n.contains("dead-letter") || n.contains("dead_letter") || n.hasSuffix("_error") || n.hasSuffix(".error")
    }
}

public struct RabbitExchange: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(vhost)/\(name)" }
    public var name: String
    public var vhost: String
    public var type: String
    public var durable: Bool?
    public var autoDelete: Bool?
    public var `internal`: Bool?
    public var arguments: [String: JSONValue]?
    public var messageStats: MessageStats?

    public var displayName: String { name.isEmpty ? "(AMQP default)" : name }
}

public struct RabbitBinding: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(vhost)|\(source)|\(destinationType)|\(destination)|\(propertiesKey ?? routingKey)" }
    public var source: String
    public var vhost: String
    public var destination: String
    public var destinationType: String
    public var routingKey: String
    public var propertiesKey: String?
    public var arguments: [String: JSONValue]?
}

public struct RabbitMessage: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(exchange)|\(routingKey)|\(messageCount)|\(payload.hashValue)" }
    public var payloadBytes: Int
    public var redelivered: Bool
    public var exchange: String
    public var routingKey: String
    public var messageCount: Int
    public var properties: JSONValue?
    public var payload: String
    public var payloadEncoding: String

    public var headers: [String: JSONValue] {
        if case .object(let h)? = properties?["headers"] { return h }
        return [:]
    }

    public var propertyPairs: [(String, String)] {
        guard case .object(let o)? = properties else { return [] }
        return o.filter { $0.key != "headers" }.sorted { $0.key < $1.key }.map { ($0.key, $0.value.display) }
    }

    public var payloadData: Data {
        payloadEncoding == "base64" ? (Data(base64Encoded: payload) ?? Data()) : Data(payload.utf8)
    }

    /// For dead-lettered messages, where they were originally published.
    public var originalExchange: String? {
        guard case .array(let d)? = headers["x-death"], let first = d.last else { return nil }
        return first["exchange"]?.stringValue
    }

    public var originalRoutingKey: String? {
        guard case .array(let d)? = headers["x-death"], let first = d.last,
              case .array(let keys)? = first["routing-keys"] else { return nil }
        return keys.first?.stringValue
    }

    /// Why the message was dead-lettered, from the `x-death` header.
    public var deathReason: String? {
        guard case .array(let deaths)? = headers["x-death"], let first = deaths.first else { return nil }
        let reason = first["reason"]?.display ?? "?"
        let queue = first["queue"]?.display ?? "?"
        let count = first["count"]?.display ?? "1"
        return "\(reason) in \(queue) ×\(count)"
    }
}

public struct RabbitConnectionInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var user: String?
    public var vhost: String?
    public var state: String?
    public var channels: Int?
    public var peerHost: String?
    public var peerPort: Int?
    public var protocol_: String?
    public var clientProperties: JSONValue?
    public var connectedAt: Int64?
    public var recvOctDetails: RateDetails?
    public var sendOctDetails: RateDetails?

    enum CodingKeys: String, CodingKey {
        case name, user, vhost, state, channels, peerHost, peerPort, clientProperties, connectedAt, recvOctDetails, sendOctDetails
        case protocol_ = "protocol"
    }

    public var clientName: String {
        clientProperties?["connection_name"]?.stringValue
            ?? clientProperties?["product"]?.stringValue
            ?? peerHost ?? name
    }
}

public struct RabbitConsumer: Sendable, Hashable, Codable, Identifiable {
    public struct QueueRef: Sendable, Hashable, Codable { public var name: String; public var vhost: String }
    public struct ChannelDetails: Sendable, Hashable, Codable {
        public var connectionName: String?
        public var peerHost: String?
        public var name: String?
    }
    public var id: String { "\(queue.vhost)/\(queue.name)/\(consumerTag)" }
    public var consumerTag: String
    public var queue: QueueRef
    public var channelDetails: ChannelDetails?
    public var prefetchCount: Int?
    public var ackRequired: Bool?
    public var active: Bool?
}

public struct RabbitVhost: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
}
