import Foundation
import UIKit

#if DEBUG
/// Debug-only trail in `Library/Caches/debug.log` (read with `simctl get_app_container … data`).
enum DebugLog {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "debuglog")
    private static let start = Date()

    static func reset() { try? FileManager.default.removeItem(at: url) }

    /// Logs every focus move with the focused item's frame (in screen points).
    @MainActor static func traceFocus() {
        NotificationCenter.default.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            guard let ctx = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
            let f = ctx.nextFocusedItem.map { item -> String in
                let space = (item as? UIView) ?? (item.parentFocusEnvironment as? UIView)
                let r = space.map { _ in (item as? UIView)?.convert((item as! UIView).bounds, to: nil) ?? item.frame } ?? item.frame
                return "\(type(of: item)) \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
            } ?? "nil"
            write("focus → \(f) heading=\(ctx.focusHeading.rawValue)")
        }
    }

    /// `-launchTiming`: stamps the launch sequence against process start, so a
    /// slow box can be tuned from a log instead of a guess.
    static let launchTiming = PerformanceProfile.arguments.contains("-launchTiming")
    private static let startUptime = ProcessInfo.processInfo.systemUptime

    @discardableResult
    static func launchMark(_ label: String, since: CFAbsoluteTime? = nil) -> CFAbsoluteTime {
        let now = CFAbsoluteTimeGetCurrent()
        if launchTiming {
            let total = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
            if let since {
                write(String(format: "[launch] %@ +%.0f ms (t=%.0f ms)", label, (now - since) * 1000, total))
            } else {
                write(String(format: "[launch] %@ t=%.0f ms", label, total))
            }
        }
        return now
    }

    static func write(_ s: String) {
        let line = String(format: "%.2f ", Date().timeIntervalSince(start)) + s + "\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
#endif

#if DEBUG
/// `-hitchLog`: logs every main-run-loop stretch busier than 50 ms (a dropped
/// frame on a 60 Hz panel is 16.7 ms; 50 ms is a visible stutter, 250 ms a
/// "freeze"). Busy time = wake-up → about-to-sleep, measured on the main thread.
enum HitchMonitor {
    private static var observer: CFRunLoopObserver?
    private static var wokeAt: CFAbsoluteTime = 0
    private static var count = 0
    private static var total: Double = 0

    static func start() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                wokeAt = now
            } else if wokeAt > 0 {
                let busy = (now - wokeAt) * 1000
                if busy > 50 {
                    count += 1
                    total += busy
                    DebugLog.write(String(format: "[hitch] %.0f ms (n=%d, total %.1f s)", busy, count, total / 1000))
                }
                wokeAt = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
#endif

#if DEBUG && arch(arm64)
import Darwin

/// `-hitchProfile`: a tiny sampling profiler for real hardware (Instruments
/// can't always attach to a TV). While the main thread has been busy > 60 ms,
/// a watcher thread suspends it every 10 ms, walks its frame-pointer chain and
/// counts the functions on the stack. Every 20 s the heaviest app functions
/// (inclusive) are written to the debug log, mangled — demangle on the Mac.
/// No allocation happens while main is suspended (a held malloc lock would
/// deadlock the sampler).
final class HitchProfiler {
    static let shared = HitchProfiler()

    private var mainThread: thread_t = 0
    private var stackLow: UInt64 = 0
    private var stackHigh: UInt64 = 0
    private var busySince: CFAbsoluteTime = 0   // written on main, read by the watcher
    private let buffer = UnsafeMutablePointer<UInt64>.allocate(capacity: 96)
    private var counts: [UInt64: Int] = [:]    // return address → samples
    private var leaves: [UInt64: Int] = [:]    // pc (self time) → samples
    private var samples = 0
    private let lock = NSLock()
    /// The stall in progress: its runloop-iteration start and every stack sampled in it.
    private var stallSince: CFAbsoluteTime = 0
    private var stallStacks: [[UInt64]] = []

    func start() {
        // On the main thread: remember it and its stack bounds.
        mainThread = pthread_mach_thread_np(pthread_self())
        let top = UInt64(UInt(bitPattern: pthread_get_stackaddr_np(pthread_self())))
        let size = UInt64(pthread_get_stacksize_np(pthread_self()))
        stackHigh = top
        stackLow = top - size
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, a in
            self?.busySince = a == .afterWaiting ? CFAbsoluteTimeGetCurrent() : 0
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        let t = Thread { [weak self] in self?.watch() }
        t.qualityOfService = .userInteractive
        t.start()
        // Symbolising is heavy: report from a background queue, not the main thread.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async { self?.report() }
        }
    }

    private func watch() {
        while true {
            usleep(10_000)
            let since = busySince
            if since != stallSince {
                // That stall is over: a long one gets its own report.
                if stallStacks.count >= 8 {
                    let stacks = stallStacks
                    DispatchQueue.global(qos: .utility).async { Self.reportStall(stacks) }
                }
                stallStacks.removeAll(keepingCapacity: true)
                stallSince = since
            }
            guard since > 0, CFAbsoluteTimeGetCurrent() - since > 0.06 else { continue }
            let n = capture()
            guard n > 0 else { continue }
            stallStacks.append(Array(UnsafeBufferPointer(start: buffer, count: n)))
            // Inclusive: each distinct address once per sample.
            var seen = Set<UInt64>()
            lock.lock()
            for i in 0..<n where seen.insert(buffer[i]).inserted { counts[buffer[i], default: 0] += 1 }
            leaves[buffer[0], default: 0] += 1
            samples += 1
            lock.unlock()
        }
    }

    /// Suspends main, copies pc/lr + the frame chain into `buffer`, resumes.
    private func capture() -> Int {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count) }
        }
        var n = 0
        if kr == KERN_SUCCESS {
            let mask: UInt64 = 0x0000_000F_FFFF_FFFF   // strip pointer-auth bits
            buffer[n] = UInt64(state.__pc) & mask; n += 1
            buffer[n] = UInt64(state.__lr) & mask; n += 1
            var fp = UInt64(state.__fp) & mask
            while n < 96, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
                let frame = UnsafePointer<UInt64>(bitPattern: UInt(fp))!
                let ret = frame[1] & mask
                if ret == 0 { break }
                buffer[n] = ret; n += 1
                let next = frame[0] & mask
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        return n
    }

    /// One long stall: for each sample, the innermost app function on the stack
    /// (what our code was doing, directly or through SwiftUI), plus its app caller.
    private static func reportStall(_ stacks: [[UInt64]]) {
        var symCache: [UInt64: String?] = [:]
        func appSym(_ a: UInt64) -> String? {
            if let c = symCache[a] { return c }
            var info = Dl_info()
            var out: String?
            if dladdr(UnsafeRawPointer(bitPattern: UInt(a)), &info) != 0, let f = info.dli_fname,
               (String(cString: f) as NSString).lastPathComponent.hasPrefix("OrivioTV") {
                out = info.dli_sname.map { Self.short(String(cString: $0)) } ?? "?"
            }
            symCache[a] = out
            return out
        }
        var inner: [String: Int] = [:]
        for st in stacks {
            let apps = st.compactMap(appSym).filter { $0 != "main" }
            guard let first = apps.first else { inner["(no app frame)", default: 0] += 1; continue }
            inner[apps.count > 1 ? "\(first)  ← \(apps[1])" : first, default: 0] += 1
        }
        DebugLog.write("[stall] \(stacks.count * 10) ms sampled")
        for (k, c) in inner.sorted(by: { $0.value > $1.value }).prefix(12) {
            DebugLog.write(String(format: "[stall] %3d%% %@", c * 100 / stacks.count, k))
        }
        // Which frameworks: inclusive per image, and the leaf's image + symbol.
        var images: [String: Int] = [:]
        var leafs: [String: Int] = [:]
        var named: [String: Int] = [:]   // public (unredacted) system symbols, inclusive
        for st in stacks {
            var seen = Set<String>()
            for (i, a) in st.enumerated() {
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: UInt(a)), &info) != 0, let f = info.dli_fname else { continue }
                let img = (String(cString: f) as NSString).lastPathComponent
                let sym = info.dli_sname.map { String(cString: $0) } ?? "?"
                if seen.insert(img).inserted { images[img, default: 0] += 1 }
                if i == 0 { leafs["\(img) \(sym)", default: 0] += 1 }
                if sym != "<redacted>", sym != "?", !img.hasPrefix("OrivioTV"), seen.insert(sym).inserted { named["\(img) \(sym)", default: 0] += 1 }
            }
        }
        DebugLog.write("[stall] images: " + images.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value * 100 / stacks.count)%" }.joined(separator: " "))
        DebugLog.write("[stall] leaf: " + leafs.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
        for (k, c) in named.sorted(by: { $0.value > $1.value }).prefix(15) {
            DebugLog.write(String(format: "[stall] sym %3d%% %@", c * 100 / stacks.count, String(k.prefix(150))))
        }
    }

    /// Mangled Swift symbols trimmed to something readable in a log line.
    private static func short(_ s: String) -> String {
        String(s.prefix(140))
    }

    private func report() {
        lock.lock()
        let snapshot = counts
        let leafSnapshot = leaves
        let total = samples
        // Each report covers only its own window (stalls stay attributable).
        counts.removeAll(keepingCapacity: true)
        leaves.removeAll(keepingCapacity: true)
        samples = 0
        lock.unlock()
        guard total > 0 else { return }
        // Symbolize and merge by function.
        var byFunc: [String: Int] = [:]
        for (addr, c) in snapshot {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: UInt(addr)), &info) != 0, let fname = info.dli_fname else { continue }
            let image = (String(cString: fname) as NSString).lastPathComponent
            guard image.hasPrefix("OrivioTV") else { continue }
            let sym = info.dli_sname.map { String(cString: $0) } ?? "?"
            byFunc[sym] = max(byFunc[sym] ?? 0, c)
        }
        let top = byFunc.sorted { $0.value > $1.value }.prefix(60)
        DebugLog.write("[profile] samples=\(total) (10 ms each while main busy > 60 ms)")
        for (sym, c) in top { DebugLog.write(String(format: "[profile] %5.1f%% %@", Double(c) * 100 / Double(total), sym)) }
        // Framework view: inclusive time per framework image, and self time per leaf function.
        var byImage: [String: Int] = [:]
        var imageSeen: [UInt64: String] = [:]
        for (addr, _) in snapshot {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: UInt(addr)), &info) != 0, let fname = info.dli_fname else { continue }
            imageSeen[addr] = (String(cString: fname) as NSString).lastPathComponent
        }
        for (addr, c) in snapshot { if let img = imageSeen[addr] { byImage[img] = max(byImage[img] ?? 0, c) } }
        for (img, c) in byImage.sorted(by: { $0.value > $1.value }).prefix(15) {
            DebugLog.write(String(format: "[profimg] %5.1f%% %@", Double(c) * 100 / Double(total), img))
        }
        var leafBy: [String: Int] = [:]
        for (addr, c) in leafSnapshot {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: UInt(addr)), &info) != 0, let fname = info.dli_fname else { continue }
            let img = (String(cString: fname) as NSString).lastPathComponent
            let sym = info.dli_sname.map { String(cString: $0) } ?? "?"
            leafBy["\(img) \(sym)", default: 0] += c
        }
        for (k, c) in leafBy.sorted(by: { $0.value > $1.value }).prefix(40) {
            DebugLog.write(String(format: "[profleaf] %5.1f%% %@", Double(c) * 100 / Double(total), k))
        }
    }
}
#endif

#if DEBUG
/// `-bodyCount`: how often key view bodies run (logged every 10 s) — finds
/// views redrawn on every focus move.
enum BodyCounter {
    static let enabled = PerformanceProfile.arguments.contains("-bodyCount")
    private static var counts: [String: Int] = [:]
    private static var timer: Timer?

    @inline(__always) static func hit(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                let line = counts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                DebugLog.write("[bodies] \(line)")
            }
        }
    }
}
#endif
