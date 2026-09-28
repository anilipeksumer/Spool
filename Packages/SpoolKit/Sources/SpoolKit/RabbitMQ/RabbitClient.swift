import Foundation

public struct RabbitError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let status: Int?
    public init(_ message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }
    public var errorDescription: String? { message }
}

/// A client for the RabbitMQ management HTTP API.
public final class RabbitClient: Sendable {
    public struct Options: Sendable, Hashable, Codable {
        /// e.g. http://localhost:15672
        public var baseURL: URL
        public var username: String
        public var password: String

        public init(baseURL: URL, username: String = "guest", password: String = "guest") {
            self.baseURL = baseURL
            self.username = username
            self.password = password
        }
    }

    public let options: Options
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom(RabbitClient.decodeKey)
        return d
    }()

    public init(_ options: Options) {
        self.options = options
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "Authorization": "Basic " + Data("\(options.username):\(options.password)".utf8).base64EncodedString(),
        ]
        session = URLSession(configuration: config)
    }

    // MARK: Transport

    /// snake_case → camelCase, except inside free-form maps such as queue
    /// arguments and message headers, whose keys must stay as they are.
    @Sendable static func decodeKey(_ path: [CodingKey]) -> CodingKey {
        let raw = path.last!.stringValue
        let freeForm: Set<String> = ["arguments", "properties", "headers", "clientProperties", "client_properties"]
        if path.dropLast().contains(where: { freeForm.contains($0.stringValue) }) { return AnyKey(raw) }
        let parts = raw.split(separator: "_")
        guard parts.count > 1 else { return AnyKey(raw) }
        return AnyKey(parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined())
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    static func encode(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    private func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        let path = "/api/" + segments.map(Self.encode).joined(separator: "/")
        var c = URLComponents(url: options.baseURL, resolvingAgainstBaseURL: false)!
        let base = c.percentEncodedPath.hasSuffix("/") ? String(c.percentEncodedPath.dropLast()) : c.percentEncodedPath
        c.percentEncodedPath = base + path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    @discardableResult
    private func request(_ method: String, _ segments: [String], query: [URLQueryItem] = [], body: (any Encodable)? = nil) async throws -> Data {
        var req = URLRequest(url: url(segments, query: query))
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost:
                throw RabbitError("Can't reach \(options.baseURL.host() ?? "the server") — is the management plugin enabled?")
            case .timedOut: throw RabbitError("Timed out")
            case .cannotFindHost: throw RabbitError("Host not found")
            default: throw RabbitError(e.localizedDescription)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { throw RabbitError("Wrong username or password", status: 401) }
            var reason = HTTPURLResponse.localizedString(forStatusCode: status)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let r = obj["reason"] as? String {
                reason = r
            }
            throw RabbitError(reason, status: status)
        }
        return data
    }

    private func get<T: Decodable>(_ type: T.Type, _ segments: [String], query: [URLQueryItem] = []) async throws -> T {
        let data = try await request("GET", segments, query: query)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RabbitError("Unexpected response from /\(segments.joined(separator: "/")): \(error)")
        }
    }

    // MARK: Reads

    public func overview() async throws -> RabbitOverview {
        try await get(RabbitOverview.self, ["overview"])
    }

    public func whoAmI() async throws -> String {
        struct Me: Decodable { var name: String }
        return try await get(Me.self, ["whoami"]).name
    }

    public func vhosts() async throws -> [RabbitVhost] {
        try await get([RabbitVhost].self, ["vhosts"])
    }

    public func queues(vhost: String? = nil) async throws -> [RabbitQueue] {
        let segs = vhost.map { ["queues", $0] } ?? ["queues"]
        return try await get([RabbitQueue].self, segs, query: [URLQueryItem(name: "disable_stats", value: "false")])
    }

    public func queue(vhost: String, name: String) async throws -> RabbitQueue {
        try await get(RabbitQueue.self, ["queues", vhost, name])
    }

    public func exchanges(vhost: String? = nil) async throws -> [RabbitExchange] {
        try await get([RabbitExchange].self, vhost.map { ["exchanges", $0] } ?? ["exchanges"])
    }

    public func bindings(forQueue name: String, vhost: String) async throws -> [RabbitBinding] {
        try await get([RabbitBinding].self, ["queues", vhost, name, "bindings"])
    }

    public func bindings(fromExchange name: String, vhost: String) async throws -> [RabbitBinding] {
        try await get([RabbitBinding].self, ["exchanges", vhost, name, "bindings", "source"])
    }

    public func connections() async throws -> [RabbitConnectionInfo] {
        try await get([RabbitConnectionInfo].self, ["connections"])
    }

    public func consumers(vhost: String? = nil) async throws -> [RabbitConsumer] {
        try await get([RabbitConsumer].self, vhost.map { ["consumers", $0] } ?? ["consumers"])
    }

    // MARK: Messages

    public enum AckMode: String, Sendable {
        /// Look at messages and put them back.
        case peek = "ack_requeue_true"
        /// Take messages off the queue.
        case take = "ack_requeue_false"
    }

    /// Fetches up to `count` messages. `.peek` requeues them (they come back
    /// marked redelivered, at the head of the queue).
    public func getMessages(queue: String, vhost: String, count: Int = 20, mode: AckMode = .peek) async throws -> [RabbitMessage] {
        struct Body: Encodable {
            var count: Int
            var ackmode: String
            var encoding = "auto"
            var truncate = 50_000
        }
        let data = try await request("POST", ["queues", vhost, queue, "get"], body: Body(count: count, ackmode: mode.rawValue))
        return try decoder.decode([RabbitMessage].self, from: data)
    }

    public struct PublishProperties: Sendable, Hashable {
        public var contentType: String?
        public var deliveryMode: Int = 2
        public var headers: [String: JSONValue] = [:]
        public var messageId: String?
        public var correlationId: String?
        public var type: String?
        public init(contentType: String? = nil, headers: [String: JSONValue] = [:]) {
            self.contentType = contentType
            self.headers = headers
        }
    }

    /// Publishes a message. Returns whether it was routed to any queue.
    @discardableResult
    public func publish(exchange: String, vhost: String, routingKey: String, payload: String,
                        properties: PublishProperties = PublishProperties()) async throws -> Bool {
        var props: [String: JSONValue] = ["delivery_mode": .number(Double(properties.deliveryMode))]
        if let ct = properties.contentType, !ct.isEmpty { props["content_type"] = .string(ct) }
        if !properties.headers.isEmpty { props["headers"] = .object(properties.headers) }
        if let v = properties.messageId, !v.isEmpty { props["message_id"] = .string(v) }
        if let v = properties.correlationId, !v.isEmpty { props["correlation_id"] = .string(v) }
        if let v = properties.type, !v.isEmpty { props["type"] = .string(v) }
        let body: JSONValue = .object([
            "properties": .object(props),
            "routing_key": .string(routingKey),
            "payload": .string(payload),
            "payload_encoding": .string("string"),
        ])
        let data = try await request("POST", ["exchanges", vhost, exchange.isEmpty ? "amq.default" : exchange, "publish"], body: body)
        struct Routed: Decodable { var routed: Bool }
        return (try? decoder.decode(Routed.self, from: data).routed) ?? false
    }

    // MARK: Changes

    public func purge(queue: String, vhost: String) async throws {
        try await request("DELETE", ["queues", vhost, queue, "contents"])
    }

    public func deleteQueue(_ name: String, vhost: String) async throws {
        try await request("DELETE", ["queues", vhost, name])
    }

    public func declareQueue(_ name: String, vhost: String, durable: Bool = true, type: String = "classic",
                             arguments: [String: JSONValue] = [:]) async throws {
        var args = arguments
        if type != "classic" { args["x-queue-type"] = .string(type) }
        let body: JSONValue = .object(["durable": .bool(durable), "auto_delete": .bool(false), "arguments": .object(args)])
        try await request("PUT", ["queues", vhost, name], body: body)
    }

    public func declareExchange(_ name: String, vhost: String, type: String, durable: Bool = true) async throws {
        let body: JSONValue = .object(["type": .string(type), "durable": .bool(durable), "auto_delete": .bool(false), "internal": .bool(false), "arguments": .object([:])])
        try await request("PUT", ["exchanges", vhost, name], body: body)
    }

    public func deleteExchange(_ name: String, vhost: String) async throws {
        try await request("DELETE", ["exchanges", vhost, name])
    }

    public func bind(queue: String, to exchange: String, vhost: String, routingKey: String) async throws {
        let body: JSONValue = .object(["routing_key": .string(routingKey), "arguments": .object([:])])
        try await request("POST", ["bindings", vhost, "e", exchange, "q", queue], body: body)
    }

    public func unbind(_ binding: RabbitBinding) async throws {
        let kind = binding.destinationType == "queue" ? "q" : "e"
        try await request("DELETE", ["bindings", binding.vhost, "e", binding.source, kind, binding.destination,
                                     binding.propertiesKey ?? binding.routingKey])
    }

    // MARK: Moving messages

    /// Whether the shovel plugin is available, which moving messages needs.
    public func canMoveMessages() async -> Bool {
        do {
            try await request("GET", ["shovels"])
            return true
        } catch {
            return false
        }
    }

    /// Moves every message currently in `queue` to `target` with a one-off
    /// dynamic shovel, the same way the management UI does. Messages are
    /// only removed from the source once the target has them.
    public func moveMessages(from queue: String, to target: String, vhost: String) async throws {
        let name = "spool-move-\(UUID().uuidString.prefix(8))"
        let body: JSONValue = .object([
            "value": .object([
                "src-protocol": .string("amqp091"),
                "src-uri": .string("amqp:///\(Self.encode(vhost))"),
                "src-queue": .string(queue),
                "src-delete-after": .string("queue-length"),
                "dest-protocol": .string("amqp091"),
                "dest-uri": .string("amqp:///\(Self.encode(vhost))"),
                "dest-queue": .string(target),
                "ack-mode": .string("on-confirm"),
            ]),
        ])
        do {
            try await request("PUT", ["parameters", "shovel", vhost, name], body: body)
        } catch let e as RabbitError where e.status == 400 || e.status == 404 {
            throw RabbitError("Moving messages needs the shovel plugins: rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management", status: e.status)
        }
    }
}
