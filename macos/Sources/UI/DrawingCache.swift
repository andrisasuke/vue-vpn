import AppKit

/// Bounded LRU storage. AppKit drawing normally uses the main thread; the lock
/// also makes primitives safe for independent offscreen renderers.
final class DrawingCache<Key:Hashable,Value>: @unchecked Sendable {
    private struct Entry { let value:Value;let cost:Int;var age:UInt64 }
    private let lock = NSLock()
    private var entries:[Key:Entry] = [:]
    private var age:UInt64 = 0
    private var cost = 0
    private var enabled = true
    var isEnabled:Bool {
        get { lock.lock();defer { lock.unlock() };return enabled }
        set { lock.lock();defer { lock.unlock() };enabled = newValue }
    }
    let limit:Int
    init(limit:Int) { self.limit = limit }
    func value(for key:Key) -> Value? {
        lock.lock();defer { lock.unlock() }
        guard enabled,var entry = entries[key] else { return nil }
        age &+= 1;entry.age = age;entries[key] = entry;return entry.value
    }
    func insert(_ value:Value,for key:Key,cost newCost:Int = 1) {
        lock.lock();defer { lock.unlock() }
        guard enabled,newCost <= limit else { return }
        if let old = entries.removeValue(forKey:key) { cost -= old.cost }
        while cost+newCost > limit,let oldest = entries.min(by:{$0.value.age < $1.value.age}) {
            cost -= oldest.value.cost;entries.removeValue(forKey:oldest.key)
        }
        age &+= 1;entries[key] = Entry(value:value,cost:newCost,age:age);cost += newCost
    }
    var totalCost:Int { lock.lock();defer { lock.unlock() };return cost }
    func removeAll() { lock.lock();defer { lock.unlock() };entries.removeAll();cost = 0 }
}

enum DrawingResources {
    static let fonts = DrawingCache<String,NSFont>(limit:256)
    static let paths = DrawingCache<String,CGPath>(limit:128)
    static let images = DrawingCache<String,CGImage>(limit:32*1024*1024)
    // Used by the hostless benchmark to measure the original uncached path.
    // Only toggled by tests on the main actor, never by application UI.
    @MainActor static func clearImages() { images.removeAll() }
}
