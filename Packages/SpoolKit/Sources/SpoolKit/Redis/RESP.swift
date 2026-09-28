import Foundation

/// A value in the Redis serialization protocol (RESP2).
public enum RESPValue: Sendable, Equatable {
    case simple(String)
    case error(String)
    case integer(Int64)
    case bulk(Data?)
    case array([RESPValue]?)

    public var string: String? {
        switch self {
        case .simple(let s): s
        case .bulk(let d?): String(decoding: d, as: UTF8.self)
        case .integer(let i): String(i)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .bulk(let d): d
        case .simple(let s): Data(s.utf8)
        default: nil
        }
    }

    public var int: Int64? {
        switch self {
        case .integer(let i): i
        case .simple(let s), .error(let s): Int64(s)
        case .bulk(let d?): Int64(String(decoding: d, as: UTF8.self))
        default: nil
        }
    }

    public var array: [RESPValue] {
        if case .array(let a?) = self { return a }
        return []
    }

    public var isNull: Bool {
        switch self {
        case .bulk(nil), .array(nil): true
        default: false
        }
    }

    /// A readable rendering, like redis-cli prints it.
    public func rendered(indent: String = "") -> String {
        switch self {
        case .simple(let s): return s
        case .error(let s): return "(error) \(s)"
        case .integer(let i): return "(integer) \(i)"
        case .bulk(nil), .array(nil): return "(nil)"
        case .bulk(let d?): return "\"\(String(decoding: d, as: UTF8.self))\""
        case .array(let a?):
            if a.isEmpty { return "(empty array)" }
            let width = String(a.count).count
            return a.enumerated().map { i, v in
                let n = String(i + 1)
                let label = String(repeating: " ", count: width - n.count) + n + ") "
                let pad = indent + String(repeating: " ", count: label.count)
                return (i == 0 ? "" : indent) + label + v.rendered(indent: pad)
            }.joined(separator: "\n")
        }
    }
}

public struct RedisError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

enum RESP {
    static func encode(_ args: [Data]) -> Data {
        var out = Data("*\(args.count)\r\n".utf8)
        for a in args {
            out.append(contentsOf: Array("$\(a.count)\r\n".utf8))
            out.append(a)
            out.append(contentsOf: [13, 10])
        }
        return out
    }

    /// Parses one value starting at `start`. Returns nil when the buffer
    /// doesn't hold a complete value yet.
    static func parse(_ buf: [UInt8], at start: Int) throws -> (RESPValue, Int)? {
        guard start < buf.count else { return nil }
        guard let lineEnd = findCRLF(buf, from: start + 1) else { return nil }
        let line = String(decoding: buf[(start + 1)..<lineEnd], as: UTF8.self)
        let next = lineEnd + 2
        switch buf[start] {
        case UInt8(ascii: "+"):
            return (.simple(line), next)
        case UInt8(ascii: "-"):
            return (.error(line), next)
        case UInt8(ascii: ":"):
            guard let i = Int64(line) else { throw RedisError("Bad integer: \(line)") }
            return (.integer(i), next)
        case UInt8(ascii: "$"):
            guard let len = Int(line) else { throw RedisError("Bad bulk length: \(line)") }
            if len < 0 { return (.bulk(nil), next) }
            guard buf.count >= next + len + 2 else { return nil }
            return (.bulk(Data(buf[next..<(next + len)])), next + len + 2)
        case UInt8(ascii: "*"):
            guard let count = Int(line) else { throw RedisError("Bad array length: \(line)") }
            if count < 0 { return (.array(nil), next) }
            var items: [RESPValue] = []
            items.reserveCapacity(count)
            var pos = next
            for _ in 0..<count {
                guard let (v, p) = try parse(buf, at: pos) else { return nil }
                items.append(v)
                pos = p
            }
            return (.array(items), pos)
        default:
            throw RedisError("Unexpected reply byte \(buf[start])")
        }
    }

    private static func findCRLF(_ buf: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < buf.count {
            if buf[i] == 13 && buf[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    /// Splits a console line into arguments, honouring quotes and escapes
    /// the way redis-cli does.
    static func tokenize(_ line: String) throws -> [String] {
        var args: [String] = []
        var cur = ""
        var quote: Character?
        var inToken = false
        var it = line.makeIterator()
        while let c = it.next() {
            if let q = quote {
                if c == "\\" && q == "\"" {
                    guard let e = it.next() else { break }
                    switch e {
                    case "n": cur.append("\n")
                    case "t": cur.append("\t")
                    case "r": cur.append("\r")
                    default: cur.append(e)
                    }
                } else if c == q {
                    quote = nil
                } else {
                    cur.append(c)
                }
            } else if c == "\"" || c == "'" {
                quote = c
                inToken = true
            } else if c.isWhitespace {
                if inToken { args.append(cur); cur = ""; inToken = false }
            } else {
                cur.append(c)
                inToken = true
            }
        }
        if quote != nil { throw RedisError("Unbalanced quotes") }
        if inToken { args.append(cur) }
        return args
    }
}
