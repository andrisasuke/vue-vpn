import Foundation

enum StatsPage: String, CaseIterable, Sendable { case cpu, ram, ssd, network
    var title: String {
        switch self { case .cpu: "CPU"; case .ram: "RAM"; case .ssd: "SSD"; case .network: "Network" }
    }
}

struct StatsCore: Equatable, Sendable {
    enum Kind: String, Sendable { case efficiency = "E", performance = "P", unknown = "Core" }
    var kind: Kind
    var usage: Double?
}

struct StatsCPU: Equatable, Sendable {
    var name: String? = nil
    var total: Double?
    var system: Double?
    var user: Double?
    var idle: Double?
    var cores: [StatsCore] = []
    var uptime: TimeInterval?
    var loads: [Double] = []
    var frequencyMHz: Double?
    var efficiency: Double? {
        average(.efficiency)
    }
    var performance: Double? { average(.performance) }
    private func average(_ kind: StatsCore.Kind) -> Double? {
        let values = cores.filter { $0.kind == kind }.compactMap(\.usage)
        return values.isEmpty ? nil : values.reduce(0,+)/Double(values.count)
    }
}

struct StatsRAM: Equatable, Sendable {
    var total: UInt64?
    var app: UInt64?
    var wired: UInt64?
    var compressed: UInt64?
    var free: UInt64?
    var swapUsed: UInt64?
    var swapTotal: UInt64?
    var pressure: String?
    var used: UInt64? {
        guard let app, let wired, let compressed else { return nil }
        let (first,overflow1) = app.addingReportingOverflow(wired)
        let (sum,overflow2) = first.addingReportingOverflow(compressed)
        return overflow1 || overflow2 ? nil : sum
    }
    var percent: Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(1,Double(used)/Double(total))
    }
}

struct StatsCounters: Equatable, Sendable { var read: UInt64; var write: UInt64 }
struct StatsInterface: Equatable, Sendable {
    var id: String
    var name: String
    var active: Bool
    var mac: String?
    var addresses: [String]
    var counters: StatsCounters
}
struct StatsDisk: Equatable, Sendable {
    var id: String
    var name: String
    var counters: StatsCounters?
    var total: UInt64?
    var available: UInt64?
    var reclaimable: UInt64?
    var volumeName: String? = nil
    var filesystem: String? = nil
    var used: UInt64? {
        guard let total, let available, total >= available else { return nil }
        return total - available
    }
    var percent: Double? {
        guard let used, let total, total > 0 else { return nil }
        return Double(used)/Double(total)
    }
}

struct StatsProcess: Equatable, Sendable {
    var pid: Int32
    var name: String
    var amount: Double
    var outbound: Double?
    var scope: String
}
struct StatsPoint: Equatable, Sendable {
    var time: TimeInterval
    var value: Double?
    var second: Double? = nil
    var reason: String? = nil
}
struct StatsHistory: Equatable, Sendable {
    private(set) var points: [StatsPoint] = []
    mutating func add(_ point: StatsPoint) {
        points.append(point)
        points.removeAll { point.time - $0.time > 300 }
        if points.count > 301 { points.removeFirst(points.count - 301) }
    }
}
struct StatsPublicAddress: Equatable, Sendable {
    enum State: String, Sendable { case unavailable, refreshing, current, stale, failed }
    var address: String?
    var state: State = .unavailable
    var updated: Date?
}
struct StatsConnectivity: Equatable, Sendable {
    enum State: String, Sendable { case notMonitored = "Not monitored", checking = "Checking", reachable = "Target reachable", unreachable = "Target unreachable" }
    var state: State = .notMonitored
    var latencyMS: Double?
    var jitterMS: Double?
    var failures = 0
    var target = "1.1.1.1"
    var history = StatsHistory()
}
struct SystemStatsSnapshot: Equatable, Sendable {
    var enabledPages = Set(StatsPage.allCases)
    var collectingPages: Set<StatsPage> = []
    var cpu = StatsCPU()
    var ram = StatsRAM()
    var disk = StatsDisk(id:"system",name:"Internal SSD")
    var diskReadRate: Double?
    var diskWriteRate: Double?
    var interfaces: [StatsInterface] = []
    var selectedInterface: String?
    var automaticInterface = true
    var networkDownRate: Double?
    var networkUpRate: Double?
    var networkDownTotal: UInt64 = 0
    var networkUpTotal: UInt64 = 0
    var processes: [StatsPage:[StatsProcess]] = [:]
    var cpuHistory = StatsHistory()
    var ramHistory = StatsHistory()
    var diskHistory = StatsHistory()
    var networkHistory = StatsHistory()
    var publicIPv4 = StatsPublicAddress()
    var publicIPv6 = StatsPublicAddress()
    var connectivity = StatsConnectivity()
}

enum StatsDomainReading: Sendable {
    case cpu(StatsCPU)
    case ram(StatsRAM)
    case ssd(id:String,name:String,counters:StatsCounters?)
    case network(interfaces:[StatsInterface],automaticInterface:String?)
}
struct StatsPublicResult: Sendable { var ipv4: String?; var ipv6: String?; var ipv4Error = false; var ipv6Error = false }

protocol SystemStatsEnvironment: Sendable {
    func now() -> TimeInterval
    func sample(_ page: StatsPage) async -> StatsDomainReading
    func resetBaselines(_ page: StatsPage) async
    func capacity() async -> (total: UInt64, available: UInt64, reclaimable: UInt64?)?
    func volumeMetadata() async -> (name:String?, filesystem:String?)
    func processes(_ page: StatsPage) async -> [StatsProcess]
    func frequency() async -> Double?
    func probe(_ target: String) async -> Double?
    func publicAddress() async -> StatsPublicResult
}

extension SystemStatsEnvironment {
    func volumeMetadata() async -> (name:String?, filesystem:String?) { (nil,nil) }
}
