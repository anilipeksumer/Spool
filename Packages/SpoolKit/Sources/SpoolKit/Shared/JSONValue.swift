import Foundation

/// Any JSON value, for the loosely typed parts of APIs (arguments, headers).
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Parses user input: JSON when it is JSON, otherwise a string.
    public init(guessing text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let d = t.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d) {
            self = v
        } else {
            self = .string(text)
        }
    }

    public var display: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .string(let s): return s
        case .array, .object:
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? ""
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

public enum JSONFormatter {
    /// Pretty-prints data when it is a JSON object or array; nil otherwise.
    /// Only whitespace changes: numbers, key order and escapes are kept
    /// exactly as they are, so saving a formatted value never alters data.
    public static func pretty(_ data: Data) -> String? {
        guard isContainer(data), let text = String(data: data, encoding: .utf8) else { return nil }
        return reindent(text)
    }

    public static func pretty(_ text: String) -> String? { pretty(Data(text.utf8)) }

    /// The same JSON with all insignificant whitespace removed.
    public static func minified(_ text: String) -> String? {
        guard isContainer(Data(text.utf8)) else { return nil }
        return reindent(text, indentUnit: nil)
    }

    private static func isContainer(_ data: Data) -> Bool {
        let first = data.first { !(($0 == 32) || ($0 == 10) || ($0 == 13) || ($0 == 9)) }
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    static func reindent(_ text: String, indentUnit: String? = "  ") -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var depth = 0
        var inString = false
        var escaped = false
        func newline() {
            guard let unit = indentUnit else { return }
            out.append("\n")
            for _ in 0..<depth { out.append(contentsOf: unit.unicodeScalars) }
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // Keep empty containers on one line.
                var j = i
                while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(c)
                    out.append(chars[j])
                    i = j + 1
                } else {
                    out.append(c)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(c)
                if indentUnit != nil { out.append(" ") }
            case " ", "\n", "\r", "\t":
                break
            default:
                out.append(c)
            }
        }
        return String(out)
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
