import Foundation

/// Lock-guarded property wrapper for cross-thread flags and counters.
/// (Extracted from the retired DVRemuxer.swift — the sample engine and
/// thumbnailer share it.)
@propertyWrapper
final class Atomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(wrappedValue: Value) { value = wrappedValue }
    var wrappedValue: Value {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}
