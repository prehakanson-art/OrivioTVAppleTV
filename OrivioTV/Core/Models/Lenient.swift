import Foundation

/// Lenient decoding helpers — add-ons send numbers as strings, strings as
/// numbers, nulls, and arrays with junk elements.
extension KeyedDecodingContainer {
    func string(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s.isEmpty ? nil : s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func int(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func double(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func bool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }

    /// An array whose undecodable elements are dropped (instead of failing the whole array).
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard var container = try? nestedUnkeyedContainer(forKey: key) else {
            if let single = try? decodeIfPresent(T.self, forKey: key) { return [single] }
            return []
        }
        var out: [T] = []
        while !container.isAtEnd {
            if let v = try? container.decode(T.self) { out.append(v) } else { _ = try? container.decode(Skip.self) }
        }
        return out
    }

    /// A list of strings, accepting `"a, b"` or `["a","b"]`.
    func stringList(_ key: Key) -> [String] {
        if let arr = try? decodeIfPresent([String].self, forKey: key) { return arr.filter { !$0.isEmpty } }
        let lossy = lossyArray(String.self, key)
        if !lossy.isEmpty { return lossy }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}

private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Coding key for arbitrary dictionaries.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
}
