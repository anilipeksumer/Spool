import Foundation
import Testing
@testable import SpoolKit

@Suite struct RESPTests {
    func parse(_ s: String) throws -> RESPValue? {
        try RESP.parse(Array(s.utf8), at: 0)?.0
    }

    @Test func scalars() throws {
        #expect(try parse("+OK\r\n") == .simple("OK"))
        #expect(try parse("-ERR nope\r\n") == .error("ERR nope"))
        #expect(try parse(":42\r\n") == .integer(42))
        #expect(try parse("$5\r\nhello\r\n") == .bulk(Data("hello".utf8)))
        #expect(try parse("$-1\r\n") == .bulk(nil))
        #expect(try parse("$0\r\n\r\n") == .bulk(Data()))
    }

    @Test func nestedArray() throws {
        let v = try parse("*2\r\n$1\r\na\r\n*2\r\n:1\r\n+x\r\n")
        #expect(v == .array([.bulk(Data("a".utf8)), .array([.integer(1), .simple("x")])]))
    }

    @Test func incompleteReturnsNil() throws {
        #expect(try parse("$5\r\nhel") == nil)
        #expect(try parse("*2\r\n:1\r\n") == nil)
        #expect(try parse("+OK") == nil)
    }

    @Test func binarySafeBulk() throws {
        let v = try parse("$4\r\na\r\nb\r\n")
        #expect(v == .bulk(Data("a\r\nb".utf8)))
    }

    @Test func encode() {
        let d = RESP.encode([Data("SET".utf8), Data("k".utf8), Data("v v".utf8)])
        #expect(String(decoding: d, as: UTF8.self) == "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nv v\r\n")
    }

    @Test func tokenize() throws {
        #expect(try RESP.tokenize("SET  key \"hello world\"") == ["SET", "key", "hello world"])
        #expect(try RESP.tokenize("SET k 'it''s'") == ["SET", "k", "its"])
        #expect(try RESP.tokenize("SET k \"a\\nb\"") == ["SET", "k", "a\nb"])
        #expect(try RESP.tokenize("SET k \"\"") == ["SET", "k", ""])
        #expect(throws: RedisError.self) { try RESP.tokenize("GET \"x") }
    }

    @Test func rendering() {
        let v = RESPValue.array([.bulk(Data("a".utf8)), .integer(2), .array([.simple("x")])])
        #expect(v.rendered() == "1) \"a\"\n2) (integer) 2\n3) 1) x")
    }

    @Test func info() {
        let info = RedisInfo(parsing: "# Server\r\nredis_version:7.2.6\r\n\r\n# Keyspace\r\ndb0:keys=12,expires=3,avg_ttl=0\r\ndb2:keys=1,expires=0,avg_ttl=0\r\n")
        #expect(info.version == "7.2.6")
        #expect(info.sections.map(\.name) == ["Server", "Keyspace"])
        #expect(info.keyspace.map(\.db) == [0, 2])
        #expect(info.keyspace.first?.keys == 12)
    }
}

@Suite struct JSONFormatterTests {
    @Test func keepsNumbersAndOrderExactly() {
        let src = #"{"price":21.99,"big":12345678901234567890,"z":1,"a":[],"o":{},"s":"a,b:{c}\"d","n":[1,2]}"#
        let pretty = JSONFormatter.pretty(src)!
        #expect(pretty.contains("\"price\": 21.99,"))
        #expect(pretty.contains("12345678901234567890"))
        #expect(pretty.contains(#""s": "a,b:{c}\"d""#))
        #expect(pretty.range(of: "\"z\"")!.lowerBound < pretty.range(of: "\"a\"")!.lowerBound)
        #expect(pretty.contains("\"a\": [],"))
        #expect(JSONFormatter.minified(pretty) == src)
    }

    @Test func rejectsNonJSON() {
        #expect(JSONFormatter.pretty("hello") == nil)
        #expect(JSONFormatter.pretty("{broken") == nil)
        #expect(JSONFormatter.pretty("42") == nil)
    }
}

@Suite struct RabbitDecodingTests {
    @Test func keysInsideArgumentsAndHeadersStayRaw() throws {
        let json = """
        [{"name":"orders","vhost":"/","messages_ready":3,"arguments":{"x-dead-letter-exchange":"dlx","some_flag":true},
          "message_stats":{"publish_details":{"rate":1.5}}}]
        """
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom(RabbitClient.decodeKey)
        let q = try d.decode([RabbitQueue].self, from: Data(json.utf8))[0]
        #expect(q.messagesReady == 3)
        #expect(q.deadLetterExchange == "dlx")
        #expect(q.arguments?["some_flag"] == .bool(true))
        #expect(q.messageStats?.publishRate == 1.5)

        let m = """
        [{"payload_bytes":2,"redelivered":false,"exchange":"","routing_key":"q","message_count":0,
          "properties":{"content_type":"application/json","headers":{"tenant_id":"a","x-death":[{"reason":"rejected","queue":"orders","count":2}]}},
          "payload":"{}","payload_encoding":"string"}]
        """
        let msg = try d.decode([RabbitMessage].self, from: Data(m.utf8))[0]
        #expect(msg.headers["tenant_id"] == .string("a"))
        #expect(msg.propertyPairs.first?.0 == "content_type")
        #expect(msg.deathReason == "rejected in orders ×2")
    }

    @Test func pathEncoding() {
        #expect(RabbitClient.encode("/") == "%2F")
        #expect(RabbitClient.encode("a b#c") == "a%20b%23c")
    }
}
