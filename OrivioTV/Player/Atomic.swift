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

    /// The projected value is the wrapper itself, so `$flag.mutate { … }` is
    /// reachable from the declaring type.
    var projectedValue: Atomic<Value> { self }

    /// Read-modify-write under ONE lock hold. `wrappedValue += 1` is a separate
    /// locked get and a separate locked set, so an update landing between them
    /// is lost — which is how the sample engine's pull-gap counters dropped
    /// increments whenever the feed queue bumped one while main was zeroing it.
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}
