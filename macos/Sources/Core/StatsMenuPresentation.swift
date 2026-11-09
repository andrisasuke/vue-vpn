import Foundation

@MainActor protocol StatsMonitoringStore {
    func readMonitoring(_ page:StatsPage) -> Bool?
    func writeMonitoring(_ enabled:Bool,for page:StatsPage)
}
@MainActor struct UserDefaultsStatsMonitoringStore:StatsMonitoringStore {
    let defaults:UserDefaults
    private func key(_ page:StatsPage) -> String { "stats.monitoring.enabled.\(page.rawValue)" }
    func readMonitoring(_ page:StatsPage) -> Bool? { (defaults.object(forKey:key(page)) as? NSNumber)?.boolValue }
    func writeMonitoring(_ enabled:Bool,for page:StatsPage) { defaults.set(enabled,forKey:key(page)) }
}
@MainActor final class StatsMonitoringSettings {
    private let store:any StatsMonitoringStore
    private(set) var enabledPages:Set<StatsPage>
    init(store:any StatsMonitoringStore) {
        self.store = store
        enabledPages = Set(StatsPage.allCases.filter { store.readMonitoring($0) ?? true })
    }
    func toggle(_ page:StatsPage) {
        let enabled = !enabledPages.contains(page)
        if enabled { enabledPages.insert(page) } else { enabledPages.remove(page) }
        store.writeMonitoring(enabled,for:page)
    }
}

struct StatsMenuMetric: Equatable, Sendable {
    var page: StatsPage
    var top: String
    var bottom: String
    var tooltip: String
    var accessibilityLabel: String
}

enum StatsMenuPresentation {
    static let order: [StatsPage] = [.ram,.ssd,.network,.cpu]
    static func visibleMetrics(_ metrics:[StatsMenuMetric],in pages:Set<StatsPage>) -> [StatsMenuMetric] {
        metrics.filter { pages.contains($0.page) }
    }
    static func metrics(_ stats: SystemStatsSnapshot) -> [StatsMenuMetric] {
        order.map { page in
            let top: String
            let bottom: String
            let detail: String
            switch page {
            case .ram:
                top = "RAM"; bottom = percent(stats.ram.percent); detail = bottom
            case .ssd:
                top = "SSD"; bottom = percent(stats.disk.percent); detail = bottom
            case .cpu:
                top = "CPU"; bottom = percent(stats.cpu.total); detail = bottom
            case .network:
                let down = rate(stats.networkDownRate)
                let up = rate(stats.networkUpRate)
                top = "↓\(down)"; bottom = "↑\(up)"
                detail = "Download \(down), upload \(up)"
            }
            return StatsMenuMetric(page:page,top:top,bottom:bottom,
                tooltip:"VueVPN Stats · \(page.title)",
                accessibilityLabel:"VueVPN Stats \(page.title), \(detail)")
        }
    }
    private static func percent(_ value: Double?) -> String {
        guard let value,value.isFinite else { return "—" }
        return "\(Int((min(1,max(0,value))*100).rounded()))%"
    }
    private static func rate(_ value: Double?) -> String {
        guard let value,value.isFinite,value >= 0 else { return "—" }
        let units = ["B/s","KB/s","MB/s","GB/s"]
        var amount = value, index = 0
        // Round across a unit boundary before a four-digit value can appear.
        while amount >= 999.5,index < units.count-1 { amount /= 1000; index += 1 }
        if index == units.count-1 && amount >= 999.5 { return "999+GB/s" }
        return String(format:amount < 10 && index > 0 ? "%.1f%@" : "%.0f%@",amount,units[index])
    }
}

/// Decides tray changes without creating AppKit status items. Hidden metrics
/// retain their latest formatted value but never request artwork updates.
struct StatsMenuBarState {
    enum Change:Equatable {
        case metric(StatsMenuMetric)
        case visibility(StatsPage,Bool)
    }
    private(set) var visiblePages = Set(StatsPage.allCases)
    private var latest:[StatsPage:StatsMenuMetric] = [:]
    private(set) var styles:[StatsPage:StatsMenuStyle] = [:]
    mutating func setStyles(_ next:[StatsPage:StatsMenuStyle]) -> [Change] {
        let previous = styles; styles = next
        return StatsMenuPresentation.order.compactMap { page in
            guard (previous[page] ?? .label) != (next[page] ?? .label), visiblePages.contains(page), let metric = latest[page] else { return nil }
            return .metric(metric)
        }
    }
    func refreshVisible() -> [Change] { visibleMetrics.map { .metric($0) } }
    var visibleMetrics:[StatsMenuMetric] {
        StatsMenuPresentation.visibleMetrics(
            StatsMenuPresentation.order.compactMap { latest[$0] },in:visiblePages)
    }
    mutating func setVisiblePages(_ pages:Set<StatsPage>) -> [Change] {
        guard visiblePages != pages else { return [] }
        let previous = visiblePages
        visiblePages = pages
        var changes:[Change] = []
        for page in StatsMenuPresentation.order where previous.contains(page) != pages.contains(page) {
            if pages.contains(page),let metric = latest[page] { changes.append(.metric(metric)) }
            changes.append(.visibility(page,pages.contains(page)))
        }
        return changes
    }
    mutating func update(_ snapshot:SystemStatsSnapshot) -> [Change] {
        var changes:[Change] = []
        for metric in StatsMenuPresentation.metrics(snapshot) {
            guard latest[metric.page] != metric else { continue }
            latest[metric.page] = metric
            if visiblePages.contains(metric.page) { changes.append(.metric(metric)) }
        }
        return changes
    }
}

@MainActor protocol StatsMenuVisibilityStore {
    func read(_ page:StatsPage) -> Bool?
    func write(_ visible:Bool,for page:StatsPage)
}

@MainActor struct UserDefaultsStatsMenuVisibilityStore:StatsMenuVisibilityStore {
    let defaults:UserDefaults
    private func key(_ page:StatsPage) -> String { "stats.menu.visible.\(page.rawValue)" }
    func read(_ page:StatsPage) -> Bool? { (defaults.object(forKey:key(page)) as? NSNumber)?.boolValue }
    func write(_ visible:Bool,for page:StatsPage) { defaults.set(visible,forKey:key(page)) }
}

/// A tray presentation preference; it never changes system-stat collection.
@MainActor final class StatsMenuVisibilitySettings {
    private let store:any StatsMenuVisibilityStore
    private(set) var visiblePages:Set<StatsPage>
    init(store:any StatsMenuVisibilityStore) {
        self.store = store
        visiblePages = Set(StatsPage.allCases.filter { store.read($0) ?? true })
    }
    func isVisible(_ page:StatsPage) -> Bool { visiblePages.contains(page) }
    @discardableResult func toggle(_ page:StatsPage) -> Bool {
        let visible = !isVisible(page)
        if visible { visiblePages.insert(page) } else { visiblePages.remove(page) }
        store.write(visible,for:page)
        return visible
    }
}


enum StatsMenuStyle:String, CaseIterable, Sendable { case label, icon }

@MainActor protocol StatsMenuStyleStore {
    func readStyle(_ page:StatsPage) -> String?
    func writeStyle(_ value:String,for page:StatsPage)
}
@MainActor struct UserDefaultsStatsMenuStyleStore:StatsMenuStyleStore {
    let defaults:UserDefaults
    private func key(_ page:StatsPage) -> String { "stats.menu.style.\(page.rawValue)" }
    func readStyle(_ page:StatsPage) -> String? { defaults.string(forKey:key(page)) }
    func writeStyle(_ value:String,for page:StatsPage) { defaults.set(value,forKey:key(page)) }
}
@MainActor final class StatsMenuStyleSettings {
    private let store:any StatsMenuStyleStore
    private(set) var styles:[StatsPage:StatsMenuStyle]
    init(store:any StatsMenuStyleStore) {
        self.store = store
        styles = Dictionary(uniqueKeysWithValues:StatsPage.allCases.map { ($0,store.readStyle($0).flatMap(StatsMenuStyle.init(rawValue:)) ?? .label) })
    }
    func select(_ style:StatsMenuStyle,for page:StatsPage) {
        guard styles[page] != style else { return }
        styles[page] = style; store.writeStyle(style.rawValue,for:page)
    }
}
