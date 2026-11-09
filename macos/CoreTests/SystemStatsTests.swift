import XCTest

private final class FakeStatsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 0.0
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: Double) { lock.lock(); time = value; lock.unlock() }
}

private final class CleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class FakeProbeConnection:StatsProbeConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var handler:(@Sendable (TimeInterval?) -> Void)?
    private var starts = 0, cancels = 0
    func setHandler(_ handler:(@Sendable (TimeInterval?) -> Void)?) { lock.withLock { self.handler = handler } }
    func start() { lock.withLock { starts += 1 } }
    func cancel() { lock.withLock { cancels += 1 } }
    func emit(_ value:TimeInterval?) { let callback = lock.withLock { handler }; callback?(value) }
    var counts:(Int,Int) { lock.withLock { (starts,cancels) } }
}

private final class FakeProcessResource:StatsProcessResource {
    var events:[String] = []
    var exits:[Bool]
    init(exits:[Bool]) { self.exits = exits }
    func terminate() { events.append("terminate") }
    func forceStop() { events.append("kill") }
    func waitForExit(_ duration:DispatchTimeInterval) -> Bool { events.append("wait"); return exits.removeFirst() }
    func drainOutput(_ duration:DispatchTimeInterval) { events.append("drain") }
}

private struct StatsAggregateReading: Sendable {
    var cpu:StatsCPU; var ram:StatsRAM; var diskID:String; var diskName:String
    var diskCounters:StatsCounters?; var interfaces:[StatsInterface]; var automaticInterface:String?
}

private actor FakeStatsEnvironment: SystemStatsEnvironment {
    nonisolated let clock = FakeStatsClock()
    var reading = StatsAggregateReading(cpu:StatsCPU(total:0.25,system:0.1,user:0.15,idle:0.75),
        ram:StatsRAM(total:1000,app:300,wired:100,compressed:100,free:500),
        diskID:"disk0",diskName:"SSD",diskCounters:.init(read:100,write:100),
        interfaces:[StatsInterface(id:"en0",name:"Wi-Fi",active:true,mac:nil,addresses:["192.0.2.1"],counters:.init(read:100,write:100))],automaticInterface:"en0")
    var aggregateCount = 0, capacityCount = 0, processCount = 0, frequencyCount = 0, probeCount = 0, publicCount = 0
    var metadataCount = 0
    func volumeMetadata() async -> (name:String?,filesystem:String?) { metadataCount += 1;return ("Test volume","testfs") }
    var holdAggregate = false
    var pendingAggregate: CheckedContinuation<StatsAggregateReading,Never>?
    var holdProcesses = false
    var pendingProcesses: CheckedContinuation<[StatsProcess],Never>?
    var holdCapacity = false, holdFrequency = false
    var pendingCapacity: CheckedContinuation<Void,Never>?
    var pendingFrequency: CheckedContinuation<Void,Never>?
    var cancelledOperations:Set<String> = []
    var pendingPublic: CheckedContinuation<StatsPublicResult,Never>?
    var holdProbe = false
    var pendingProbe: CheckedContinuation<Double?,Never>?
    var probeValues: [Double?] = []
    var processValues: [StatsProcess] = []
    nonisolated func now() -> TimeInterval { clock.now() }
    var domainCounts:[StatsPage:Int] = [:]
    var heldPages:Set<StatsPage> = []
    var pendingDomains:[StatsPage:CheckedContinuation<Void,Never>] = [:]
    var resets:[StatsPage:Int] = [:]
    var cancelledDomains:Set<StatsPage> = []
    func hold(_ page:StatsPage) { heldPages.insert(page) }
    func release(_ page:StatsPage) { heldPages.remove(page); pendingDomains.removeValue(forKey:page)?.resume() }
    func sample(_ page:StatsPage) async -> StatsDomainReading {
        domainCounts[page,default:0] += 1
        if heldPages.contains(page) { await withCheckedContinuation { pendingDomains[page] = $0 } }
        if Task.isCancelled { cancelledDomains.insert(page) }
        if page == .cpu {
            aggregateCount += 1
            let value:StatsAggregateReading
            if holdAggregate { value = await withCheckedContinuation { pendingAggregate = $0 } }
            else { value = reading }
            return .cpu(value.cpu)
        }
        switch page {
        case .cpu: fatalError()
        case .ram: return .ram(reading.ram)
        case .ssd: return .ssd(id:reading.diskID,name:reading.diskName,counters:reading.diskCounters)
        case .network: return .network(interfaces:reading.interfaces,automaticInterface:reading.automaticInterface)
        }
    }
    func resetBaselines(_ page:StatsPage) async { resets[page,default:0] += 1 }
    func releaseAggregate() { pendingAggregate?.resume(returning:reading);pendingAggregate = nil }
    func setHoldAggregate(_ value:Bool) { holdAggregate = value }
    func capacity() async -> (total:UInt64,available:UInt64,reclaimable:UInt64?)? {
        capacityCount += 1
        if holdCapacity { await withCheckedContinuation { pendingCapacity = $0 } }
        if Task.isCancelled { cancelledOperations.insert("capacity") }
        return (1000,250,nil)
    }
    func processes(_ page:StatsPage) async -> [StatsProcess] {
        processCount += 1
        if holdProcesses {
            let result = await withCheckedContinuation { pendingProcesses = $0 }
            if Task.isCancelled { cancelledOperations.insert("processes") }
            return result
        }
        return processValues
    }
    func releaseProcesses() { pendingProcesses?.resume(returning:processValues);pendingProcesses = nil }
    func frequency() async -> Double? {
        frequencyCount += 1
        if holdFrequency { await withCheckedContinuation { pendingFrequency = $0 } }
        if Task.isCancelled { cancelledOperations.insert("frequency") }
        return nil
    }
    func probe(_ target:String) async -> Double? {
        probeCount += 1
        if holdProbe {
            let result = await withCheckedContinuation { pendingProbe = $0 }
            if Task.isCancelled { cancelledOperations.insert("probe") }
            return result
        }
        return probeValues.isEmpty ? nil : probeValues.removeFirst()
    }
    func setHoldProbe(_ value:Bool) { holdProbe = value }
    func releaseProbe(_ value:Double?) { pendingProbe?.resume(returning:value);pendingProbe = nil }
    func publicAddress() async -> StatsPublicResult {
        publicCount += 1
        let result = await withCheckedContinuation { pendingPublic = $0 }
        if Task.isCancelled { cancelledOperations.insert("public") }
        return result
    }
    func releasePublic(_ result: StatsPublicResult) { pendingPublic?.resume(returning:result);pendingPublic = nil }
    func holdDetails() { holdProcesses = true; holdCapacity = true; holdFrequency = true; holdProbe = true }
    func releaseDetails() {
        pendingProcesses?.resume(returning:[]); pendingProcesses = nil
        pendingCapacity?.resume(); pendingCapacity = nil
        pendingFrequency?.resume(); pendingFrequency = nil
        pendingProbe?.resume(returning:20); pendingProbe = nil
        pendingPublic?.resume(returning:.init(ipv4:"198.51.100.1",ipv6:nil)); pendingPublic = nil
    }
    func setReading(_ value:StatsAggregateReading) { reading = value }
    func setProcesses(_ values:[StatsProcess],hold:Bool = false) { processValues = values;holdProcesses = hold }
    func setProbeValues(_ values:[Double?]) { probeValues = values }
}

@MainActor final class SystemStatsTests: XCTestCase {
    func testOwnedProcessCleanupDrainsAndEscalatesOnlyOnTimeout() {
        let normal = FakeProcessResource(exits:[true])
        finishOwnedStatsProcess(normal)
        XCTAssertEqual(normal.events,["terminate","wait","drain"])
        let stalled = FakeProcessResource(exits:[false,true])
        finishOwnedStatsProcess(stalled)
        XCTAssertEqual(stalled.events,["terminate","wait","kill","wait","drain"])
    }
    func testProbeGateCancelsConnectionAndCompletesExactlyOnce() async {
        let connection = FakeProbeConnection()
        let result:Double? = await withCheckedContinuation { continuation in
            let gate = ProbeGate(connection:connection,continuation:continuation,started:10)
            gate.start()
            connection.emit(10.025)
            gate.finish(nil); connection.emit(nil)
        }
        XCTAssertEqual(result ?? 0,25,accuracy:0.001)
        XCTAssertEqual(connection.counts.0,1);XCTAssertEqual(connection.counts.1,1)
        let cancelled = FakeProbeConnection(), owner = StatsCancellationOwner()
        owner.cancel()
        let cancelledResult:Double? = await withCheckedContinuation { continuation in
            let gate = ProbeGate(connection:cancelled,continuation:continuation,started:0)
            XCTAssertFalse(owner.install { gate.finish(nil) })
            gate.start();gate.finish(2)
        }
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(cancelled.counts.0,0);XCTAssertEqual(cancelled.counts.1,1)
    }
    private final class MonitoringStore:StatsMonitoringStore {
        var values:[StatsPage:Bool] = [:]
        func readMonitoring(_ page:StatsPage) -> Bool? { values[page] }
        func writeMonitoring(_ enabled:Bool,for page:StatsPage) { values[page] = enabled }
    }
    func testMonitoringPreferencesDefaultAndPersistIndependently() {
        let store = MonitoringStore(), monitoring = StatsMonitoringSettings(store:store)
        let visibility = StatsMenuVisibilitySettings(store:MenuVisibilityStore())
        let styles = StatsMenuStyleSettings(store:MenuStyleStore())
        XCTAssertEqual(monitoring.enabledPages,Set(StatsPage.allCases))
        visibility.toggle(.cpu); styles.select(.icon,for:.cpu)
        monitoring.toggle(.cpu); monitoring.toggle(.network)
        XCTAssertEqual(StatsMonitoringSettings(store:store).enabledPages,Set([.ram,.ssd]))
        XCTAssertFalse(visibility.isVisible(.cpu)); XCTAssertEqual(styles.styles[.cpu],.icon)
        monitoring.toggle(.cpu)
        XCTAssertFalse(visibility.isVisible(.cpu)); XCTAssertEqual(styles.styles[.cpu],.icon)
        XCTAssertFalse(monitoring.enabledPages.intersection(visibility.visiblePages).contains(.network))
    }

    func testAllMonitoringCombinationsOnlyRequestEnabledDomains() async {
        let pages = StatsPage.allCases
        for mask in 0..<16 {
            let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
            let enabled = Set(pages.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
            for page in pages where !enabled.contains(page) { service.setMonitoring(page,enabled:false) }
            service.start(automaticTimer:false); service.tick()
            if !enabled.isEmpty {
                await eventually { await fake.domainCounts.values.reduce(0,+) == enabled.count }
                await eventually {
                    enabled.allSatisfy { page in
                        switch page {
                        case .cpu: return !service.snapshot.cpuHistory.points.isEmpty
                        case .ram: return !service.snapshot.ramHistory.points.isEmpty
                        case .ssd: return !service.snapshot.diskHistory.points.isEmpty
                        case .network: return !service.snapshot.networkHistory.points.isEmpty
                        }
                    }
                }
            }
            let counts = await fake.domainCounts
            for page in pages { XCTAssertEqual(counts[page,default:0],enabled.contains(page) ? 1 : 0,"mask \(mask), \(page)") }
            let capacity = await fake.capacityCount
            XCTAssertEqual(capacity,enabled.contains(.ssd) ? 1 : 0)
            for page in pages where !enabled.contains(page) {
                service.setVisiblePage(page);service.tick()
            }
            fake.clock.set(0.4);service.tick()
            if enabled.contains(.network) { await eventually { await fake.publicCount == 1 }; await fake.releasePublic(.init(ipv4:nil,ipv6:nil)) }
            let networkRequests = await fake.publicCount, detailRequests = await fake.processCount
            XCTAssertEqual(networkRequests,enabled.contains(.network) ? 1 : 0)
            XCTAssertEqual(detailRequests,0)
            for page in pages where !enabled.contains(page) {
                let history:StatsHistory
                switch page {
                case .cpu: history = service.snapshot.cpuHistory
                case .ram: history = service.snapshot.ramHistory
                case .ssd: history = service.snapshot.diskHistory
                case .network: history = service.snapshot.networkHistory
                }
                XCTAssertEqual(history.points.count,1)
                XCTAssertEqual(history.points.first?.reason,"Disabled")
            }
            XCTAssertFalse(service.timerScheduled)
            service.stop()
        }
    }

    func testDisabledNetworkEventsAndResumeExcludeTraffic() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        service.start(automaticTimer:false); service.tick()
        await eventually { service.snapshot.interfaces.count == 1 }
        var reading = await fake.reading
        reading.interfaces[0].counters = .init(read:300,write:200)
        await fake.setReading(reading); fake.clock.set(1); service.tick()
        await eventually { service.snapshot.networkDownTotal == 200 }
        service.setMonitoring(.network,enabled:false)
        await fake.releasePublic(.init(ipv4:nil,ipv6:nil))
        let historyCount = service.snapshot.networkHistory.points.count
        let before = await fake.domainCounts[.network,default:0]
        let publicBefore = await fake.publicCount, probeBefore = await fake.probeCount, processBefore = await fake.processCount
        service.setVisiblePage(.network);service.setVPNContext("vpn changed");service.refreshPublicAddress()
        service.setLowPower(true);service.setSleeping(true); fake.clock.set(100);service.setSleeping(false)
        service.tick()
        let networkAfter = await fake.domainCounts[.network,default:0]
        let publicAfter = await fake.publicCount, probeAfter = await fake.probeCount, processAfter = await fake.processCount
        XCTAssertEqual(networkAfter,before)
        XCTAssertEqual(publicAfter,publicBefore); XCTAssertEqual(probeAfter,probeBefore)
        XCTAssertEqual(processAfter,processBefore)
        XCTAssertEqual(service.snapshot.networkHistory.points.count,historyCount)
        service.setVisiblePage(nil)
        reading.interfaces[0].counters = .init(read:10_000,write:10_000);await fake.setReading(reading)
        service.setMonitoring(.network,enabled:true)
        await eventually { service.tick(); return await fake.domainCounts[.network,default:0] == before+1 }
        await eventually { service.snapshot.selectedInterface == "en0" }
        XCTAssertEqual(service.snapshot.networkDownTotal,200);XCTAssertNil(service.snapshot.networkDownRate)
        fake.clock.set(100.4);service.tick()
        await eventually { await fake.publicCount == publicBefore+1 }
        let hiddenProbeCount = await fake.probeCount
        XCTAssertEqual(hiddenProbeCount,probeBefore)
        await fake.releasePublic(.init(ipv4:"203.0.113.3",ipv6:nil))
        service.setVisiblePage(.network);service.tick()
        await eventually { await fake.probeCount == probeBefore+1 }
        fake.clock.set(102);reading.interfaces[0].counters = .init(read:10_100,write:10_040);await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.networkDownTotal == 300 }
        XCTAssertEqual(service.snapshot.networkDownRate,50)
        service.stop()
    }

    func testResumedDiskAndProcessRatesUseFreshBaselines() async {
        let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
        service.setMonitoring(.network,enabled:false)
        var reading = await fake.reading
        await fake.setProcesses([.init(pid:1,name:"Synthetic",amount:42,outbound:2,scope:"System-wide process I/O")])
        service.start(automaticTimer:false);service.setVisiblePage(.ssd);service.tick()
        await eventually { service.snapshot.diskHistory.points.count == 1 && service.snapshot.ramHistory.points.count == 1 }
        fake.clock.set(3);reading.diskCounters = .init(read:400,write:250);await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.diskReadRate == 100 && service.snapshot.processes[.ssd]?.count == 1 }
        service.setMonitoring(.ssd,enabled:false)
        fake.clock.set(100);reading.diskCounters = .init(read:100_000,write:100_000);await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.ramHistory.points.last?.time == 100 }
        service.setMonitoring(.ssd,enabled:true)
        await eventually { service.tick(); return await fake.domainCounts[.ssd,default:0] == 3 }
        await eventually { service.snapshot.diskHistory.points.last?.time == 100 }
        await eventually { await fake.processCount == 3 }
        XCTAssertNil(service.snapshot.diskReadRate)
        XCTAssertEqual(service.snapshot.processes[.ssd] ?? [],[])
        fake.clock.set(103);reading.diskCounters = .init(read:100_030,write:100_060);await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.diskReadRate == 10 && service.snapshot.processes[.ssd]?.count == 1 }
        XCTAssertEqual(service.snapshot.diskWriteRate,20)
        XCTAssertNotNil(service.snapshot.ram.percent)
        XCTAssertTrue(service.snapshot.diskHistory.points.contains { $0.reason == "Disabled" })
        service.stop()
    }

    func testPersistedMixedAndAllOffSettingsAreAppliedBeforeStart() async {
        for allOff in [false,true] {
            let store = MonitoringStore()
            for page in StatsPage.allCases where allOff || page == .network || page == .cpu { store.values[page] = false }
            let settings = StatsMonitoringSettings(store:store)
            let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
            for page in StatsPage.allCases where !settings.enabledPages.contains(page) { service.setMonitoring(page,enabled:false) }
            service.start(automaticTimer:false);service.tick()
            if !allOff { await eventually { await fake.domainCounts.values.reduce(0,+) == 2 } }
            fake.clock.set(10);service.setVPNContext("changed");service.refreshPublicAddress();service.setVisiblePage(.network);service.tick()
            let counts = await fake.domainCounts, requests = await fake.publicCount
            XCTAssertEqual(counts[.cpu,default:0],0);XCTAssertEqual(counts[.network,default:0],0)
            XCTAssertEqual(requests,0);XCTAssertFalse(service.timerScheduled)
            if allOff { XCTAssertTrue(counts.isEmpty) }
            service.stop()
        }
    }

    func testDisablingEachDomainCancelsAndDrainsItsOwnedOperations() async {
        for page in StatsPage.allCases {
            let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
            for other in StatsPage.allCases where other != page { service.setMonitoring(other,enabled:false) }
            await fake.hold(page);await fake.holdDetails()
            service.start(automaticTimer:false);service.setVisiblePage(page)
            fake.clock.set(0.4);service.tick()
            await eventually {
                let counts = await (fake.domainCounts[page,default:0],fake.processCount,fake.capacityCount,fake.frequencyCount,fake.probeCount,fake.publicCount)
                return counts.0 == 1 && counts.1 == 1 && (page != .ssd || counts.2 == 1)
                    && (page != .cpu || counts.3 == 1) && (page != .network || (counts.4 == 1 && counts.5 == 1))
            }
            service.setMonitoring(page,enabled:false);service.setMonitoring(page,enabled:true)
            fake.clock.set(10);service.tick()
            let before = await fake.domainCounts[page,default:0]
            XCTAssertEqual(before,1)
            // Complete detail resources before the older headline read. The new
            // generation must stay blocked until every owned operation drains.
            await fake.releaseDetails()
            await eventually { await fake.cancelledOperations.contains("processes") }
            service.tick()
            let stillDraining = await fake.domainCounts[page,default:0]
            XCTAssertEqual(stillDraining,1)
            XCTAssertNil(service.snapshot.publicIPv4.address)
            await fake.release(page)
            await eventually {
                let cancelled = await fake.cancelledOperations
                let domain = await fake.cancelledDomains.contains(page)
                return domain && cancelled.contains("processes")
                    && (page != .ssd || cancelled.contains("capacity"))
                    && (page != .cpu || cancelled.contains("frequency"))
                    && (page != .network || (cancelled.contains("probe") && cancelled.contains("public")))
            }
            await eventually { await fake.resets[page,default:0] >= 2 }
            XCTAssertNil(service.snapshot.publicIPv4.address)
            XCTAssertEqual(service.snapshot.processes[page] ?? [],[])
            service.setMonitoring(page,enabled:false);service.stop()
        }
    }

    func testRapidToggleDrainsOldDomainBeforeNewReadAndStopsTimer() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        for page in StatsPage.allCases where page != .cpu { service.setMonitoring(page,enabled:false) }
        await fake.hold(.cpu)
        service.start(automaticTimer:false);service.tick()
        await eventually { await fake.domainCounts[.cpu,default:0] == 1 }
        service.setMonitoring(.cpu,enabled:false);service.setMonitoring(.cpu,enabled:true)
        fake.clock.set(50);service.tick()
        let duringDrain = await fake.domainCounts[.cpu,default:0]
        XCTAssertEqual(duringDrain,1)
        await fake.release(.cpu)
        await eventually { service.tick(); return await fake.domainCounts[.cpu,default:0] == 2 }
        let cancelled = await fake.cancelledDomains.contains(.cpu)
        XCTAssertTrue(cancelled)
        await eventually { service.snapshot.cpuHistory.points.last?.time == 50 }
        XCTAssertNil(service.snapshot.cpu.total)
        service.setMonitoring(.cpu,enabled:false);service.stop()
        let automatic = SystemStatsService(platform:FakeStatsEnvironment())
        for page in StatsPage.allCases { automatic.setMonitoring(page,enabled:false) }
        automatic.start();XCTAssertFalse(automatic.timerScheduled)
        automatic.setVisiblePage(.network);automatic.setSleeping(true);automatic.setSleeping(false)
        XCTAssertFalse(automatic.timerScheduled)
        automatic.setMonitoring(.ram,enabled:true);XCTAssertTrue(automatic.timerScheduled)
        automatic.setMonitoring(.ram,enabled:false);XCTAssertFalse(automatic.timerScheduled)
        automatic.stop()
        automatic.setMonitoring(.cpu,enabled:true);XCTAssertFalse(automatic.timerScheduled)
    }

    func testCancellationOwnerCleansUpOnceBeforeOrAfterInstallation() {
        let before = StatsCancellationOwner(), after = StatsCancellationOwner()
        let first = CleanupCounter(), second = CleanupCounter()
        before.cancel()
        XCTAssertFalse(before.install { first.increment() })
        before.cancel()
        XCTAssertEqual(first.value,1)
        XCTAssertTrue(after.install { second.increment() })
        after.cancel(); after.cancel()
        XCTAssertEqual(second.value,1)
    }
    private final class MenuVisibilityStore:StatsMenuVisibilityStore {
        var saved:[StatsPage:Bool] = [:]
        var writes:[String] = []
        func read(_ page:StatsPage) -> Bool? { saved[page] }
        func write(_ visible:Bool,for page:StatsPage) {
            saved[page] = visible
            writes.append("\(page.rawValue)=\(visible)")
        }
    }
    private final class MenuStyleStore:StatsMenuStyleStore {
        var saved:[StatsPage:String] = [:]
        func readStyle(_ page:StatsPage) -> String? { saved[page] }
        func writeStyle(_ value:String,for page:StatsPage) { saved[page] = value }
    }
    func testStylesPersistIndependentlyAndRefreshOnlyVisibleArtwork() {
        let store = MenuStyleStore()
        store.saved[.ssd] = "invalid"
        let settings = StatsMenuStyleSettings(store:store)
        XCTAssertTrue(StatsPage.allCases.allSatisfy { settings.styles[$0] == .label })
        settings.select(.icon,for:.cpu); settings.select(.icon,for:.network)
        XCTAssertEqual(StatsMenuStyleSettings(store:store).styles,settings.styles)
        XCTAssertEqual(store.saved[.ssd],"invalid")
        var state = StatsMenuBarState()
        var sample = SystemStatsSnapshot(); sample.cpu.total = 0.54
        _ = state.update(sample)
        _ = state.setVisiblePages([.cpu])
        XCTAssertEqual(state.setStyles(settings.styles),[.metric(StatsMenuPresentation.metrics(sample)[3])])
        XCTAssertTrue(state.setStyles(settings.styles).isEmpty)
        XCTAssertTrue(state.update(sample).isEmpty)
        XCTAssertEqual(state.refreshVisible(),[.metric(StatsMenuPresentation.metrics(sample)[3])])
        sample.networkDownRate = 1000
        XCTAssertTrue(state.update(sample).isEmpty)
        XCTAssertEqual(state.setVisiblePages([.cpu,.network]).first,.metric(StatsMenuPresentation.metrics(sample)[2]))
    }
    private func eventually(_ condition: @escaping () async -> Bool,file:StaticString = #filePath,line:UInt = #line) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for:.milliseconds(1))
        }
        XCTFail("Timed out waiting for service publication",file:file,line:line)
    }
    func testMenuVisibilityDefaultsPersistAndProjectIndependently() {
        let store = MenuVisibilityStore()
        let settings = StatsMenuVisibilitySettings(store:store)
        XCTAssertEqual(settings.visiblePages,Set(StatsPage.allCases))
        XCTAssertTrue(store.writes.isEmpty)
        settings.toggle(.ram)
        XCTAssertFalse(settings.isVisible(.ram))
        XCTAssertTrue(settings.isVisible(.cpu))
        XCTAssertTrue(settings.isVisible(.ssd))
        XCTAssertTrue(settings.isVisible(.network))
        let metrics = StatsMenuPresentation.metrics(.init())
        XCTAssertEqual(StatsMenuPresentation.visibleMetrics(metrics,in:settings.visiblePages).map(\.page),
            [.ssd,.network,.cpu])
        for page in [StatsPage.ssd,.network,.cpu] { settings.toggle(page) }
        XCTAssertTrue(settings.visiblePages.isEmpty)
        XCTAssertTrue(StatsMenuPresentation.visibleMetrics(metrics,in:settings.visiblePages).isEmpty)
        let restored = StatsMenuVisibilitySettings(store:store)
        XCTAssertTrue(restored.visiblePages.isEmpty)
        restored.toggle(.network)
        XCTAssertEqual(restored.visiblePages,Set([.network]))
        XCTAssertEqual(StatsMenuPresentation.visibleMetrics(metrics,in:restored.visiblePages).map(\.page),[.network])
        XCTAssertEqual(store.writes,["ram=false","ssd=false","network=false","cpu=false","network=true"])
    }

    func testMenuBarStateSkipsHiddenArtworkAndRestoresLatestWithoutDuplicateChanges() {
        var state = StatsMenuBarState()
        var initial = SystemStatsSnapshot()
        initial.cpu.total = 0.1
        initial.ram = StatsRAM(total:100,app:9,wired:0,compressed:0,free:91)
        let first = state.update(initial)
        XCTAssertEqual(first.count,4)
        XCTAssertEqual(state.visibleMetrics.map(\.page),StatsMenuPresentation.order)
        XCTAssertTrue(state.update(initial).isEmpty)
        XCTAssertEqual(state.setVisiblePages([.cpu]),[
            .visibility(.ram,false),.visibility(.ssd,false),.visibility(.network,false)])
        var next = initial
        next.cpu.total = 0.2
        next.ram.app = 85
        let metrics = StatsMenuPresentation.metrics(next)
        XCTAssertEqual(state.update(next),[.metric(metrics[3])])
        XCTAssertEqual(state.setVisiblePages([.cpu,.ram]),[
            .metric(metrics[0]),.visibility(.ram,true)])
        XCTAssertEqual(state.visibleMetrics.map(\.page),[.ram,.cpu])
        XCTAssertTrue(state.setVisiblePages([.cpu,.ram]).isEmpty)
        XCTAssertTrue(state.update(next).isEmpty)
        XCTAssertEqual(state.setVisiblePages([]),[.visibility(.ram,false),.visibility(.cpu,false)])
        next.cpu.total = 0.7
        XCTAssertTrue(state.update(next).isEmpty)
        XCTAssertTrue(state.visibleMetrics.isEmpty)
        let restored = state.setVisiblePages([.cpu])
        XCTAssertEqual(restored,[.metric(StatsMenuPresentation.metrics(next)[3]),.visibility(.cpu,true)])
    }

    func testAllTrayMetricsHiddenStillPublishesAggregateHistoryAndLatestValueOnRestore() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        let visibility = StatsMenuVisibilitySettings(store:MenuVisibilityStore())
        service.start(automaticTimer:false);service.tick()
        await eventually { service.snapshot.cpu.total == 0.25 && service.snapshot.cpuHistory.points.count == 1 }
        for page in StatsPage.allCases { visibility.toggle(page) }
        XCTAssertTrue(visibility.visiblePages.isEmpty)
        var reading = await fake.reading
        reading.cpu.total = 0.5
        reading.interfaces[0].counters = .init(read:300,write:250)
        fake.clock.set(1);await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.cpu.total == 0.5 && service.snapshot.networkDownRate == 200 }
        XCTAssertGreaterThanOrEqual(service.snapshot.cpuHistory.points.count,2)
        XCTAssertEqual(service.snapshot.networkDownTotal,200)
        XCTAssertTrue(StatsMenuPresentation.visibleMetrics(
            StatsMenuPresentation.metrics(service.snapshot),in:visibility.visiblePages).isEmpty)
        visibility.toggle(.network)
        let shown = StatsMenuPresentation.visibleMetrics(
            StatsMenuPresentation.metrics(service.snapshot),in:visibility.visiblePages)
        XCTAssertEqual(shown.map(\.page),[.network])
        XCTAssertEqual(shown.first?.top,"↓200B/s")
        XCTAssertEqual(service.snapshot.networkDownTotal,200)
        let before = service.snapshot
        let counts = await (fake.aggregateCount,fake.capacityCount,fake.processCount,fake.frequencyCount,fake.probeCount,fake.publicCount)
        let styles = StatsMenuStyleSettings(store:MenuStyleStore())
        var menu = StatsMenuBarState(); _ = menu.update(before)
        for page in StatsPage.allCases { styles.select(.icon,for:page); _ = menu.setStyles(styles.styles) }
        XCTAssertEqual(service.snapshot,before)
        let after = await (fake.aggregateCount,fake.capacityCount,fake.processCount,fake.frequencyCount,fake.probeCount,fake.publicCount)
        XCTAssertEqual([counts.0,counts.1,counts.2,counts.3,counts.4,counts.5],[after.0,after.1,after.2,after.3,after.4,after.5])
        service.stop()
    }

    func testPageNavigationKeepsPublishedAggregateMetricsUntilNextSample() async {
        for lowPower in [false,true] {
            let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
            var reading = await fake.reading
            reading.diskID = "system"
            await fake.setReading(reading)
            service.start(automaticTimer:false)
            service.tick()
            await eventually { service.snapshot.cpuHistory.points.count == 1 }
            service.setLowPower(lowPower)

            let interval = lowPower ? 2.0 : 1.0
            fake.clock.set(interval)
            let secondCounters = StatsCounters(read:100 + UInt64(200 * interval),write:100 + UInt64(200 * interval))
            reading.diskCounters = secondCounters
            reading.interfaces[0].counters = secondCounters
            await fake.setReading(reading)
            service.tick()
            await eventually { service.snapshot.networkDownRate == 200 && service.snapshot.diskReadRate == 200 }

            let original = service.snapshot
            var publications: [SystemStatsSnapshot] = []
            service.changed = { publications.append($0) }
            for page in [StatsPage.cpu,.ram,.ssd,.network,nil,.cpu,.network,.ssd,.ram,nil] {
                let before = publications.count
                service.setVisiblePage(page)
                XCTAssertEqual(publications.count,before + 1)
                guard let published = publications.last else { continue }
                let metrics = StatsMenuPresentation.metrics(published)
                XCTAssertEqual(metrics.first(where: { $0.page == .cpu })?.bottom,"25%")
                XCTAssertEqual(metrics.first(where: { $0.page == .network })?.top,"↓200B/s")
                XCTAssertEqual(metrics.first(where: { $0.page == .network })?.bottom,"↑200B/s")
                XCTAssertEqual(published.diskReadRate,original.diskReadRate)
                XCTAssertEqual(published.diskWriteRate,original.diskWriteRate)
                XCTAssertEqual(published.networkDownTotal,original.networkDownTotal)
                XCTAssertEqual(published.networkUpTotal,original.networkUpTotal)
                XCTAssertEqual(published.selectedInterface,original.selectedInterface)
                XCTAssertEqual(published.cpuHistory,original.cpuHistory)
                XCTAssertEqual(published.diskHistory,original.diskHistory)
                XCTAssertEqual(published.networkHistory,original.networkHistory)
                if page == nil { XCTAssertEqual(published.connectivity.state,.notMonitored) }
            }
            let beforeNextSample = await fake.aggregateCount
            XCTAssertEqual(beforeNextSample,2)
            reading.cpu.total = 0.5
            let nextCounters = StatsCounters(read:100 + UInt64(600 * interval),write:100 + UInt64(600 * interval))
            reading.diskCounters = nextCounters
            reading.interfaces[0].counters = nextCounters
            await fake.setReading(reading)
            fake.clock.set(interval * 2)
            service.tick()
            await eventually { service.snapshot.cpu.total == 0.5 && service.snapshot.networkDownRate == 400 }
            XCTAssertEqual(service.snapshot.diskReadRate,400)
            XCTAssertEqual(service.snapshot.networkDownTotal,UInt64(600 * interval))
            XCTAssertEqual(service.snapshot.cpuHistory.points.count,3)
            let afterNextSample = await fake.aggregateCount
            XCTAssertEqual(afterNextSample,3)
            service.stop()
        }
    }

    func testConstructionCadenceLowPowerAndSleep() async {
        let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
        XCTAssertFalse(service.running)
        let initialCount = await fake.aggregateCount; XCTAssertEqual(initialCount,0)
        service.start(automaticTimer:false); service.start(automaticTimer:false);service.tick()
        await eventually { await fake.aggregateCount == 1 && service.snapshot.cpu.total == 0.25 }
        fake.clock.set(0.5);service.tick();let halfSecondCount = await fake.aggregateCount;XCTAssertEqual(halfSecondCount,1)
        fake.clock.set(1);service.tick();await eventually { await fake.aggregateCount == 2 }
        service.setLowPower(true)
        fake.clock.set(2);service.tick();let lowPowerCount = await fake.aggregateCount;XCTAssertEqual(lowPowerCount,2)
        fake.clock.set(3);service.tick();await eventually { await fake.aggregateCount == 3 }
        service.setSleeping(true)
        fake.clock.set(100);service.tick();let sleepingCount = await fake.aggregateCount;XCTAssertEqual(sleepingCount,3)
        XCTAssertNil(service.snapshot.cpuHistory.points.last?.value)
        service.setSleeping(false);service.tick();await eventually { service.tick(); return await fake.aggregateCount == 4 }
        service.stop();fake.clock.set(200);service.tick();let stoppedCount = await fake.aggregateCount;XCTAssertEqual(stoppedCount,4)
        XCTAssertLessThanOrEqual(service.snapshot.cpuHistory.points.count,301)
    }

    func testRatesTotalsSwitchAndCounterReset() async {
        let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
        var reading = await fake.reading
        reading.interfaces.append(.init(id:"en1",name:"Ethernet",active:true,mac:nil,addresses:[],counters:.init(read:50,write:50)))
        await fake.setReading(reading)
        service.start(automaticTimer:false);service.tick()
        await eventually { await fake.aggregateCount == 1 && service.snapshot.interfaces.count == 2 }
        XCTAssertNil(service.snapshot.networkDownRate)
        fake.clock.set(1.5)
        reading.interfaces[0].counters = .init(read:250,write:160)
        reading.interfaces[1].counters = .init(read:95,write:80)
        await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.networkDownRate == 100 }
        XCTAssertEqual(service.snapshot.networkDownTotal,150)
        service.selectInterface("en1")
        XCTAssertEqual(service.snapshot.networkDownTotal,45)
        fake.clock.set(3.5)
        reading.interfaces[0].counters = .init(read:350,write:200)
        reading.interfaces[1].counters = .init(read:135,write:100)
        await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.networkDownRate == 20 }
        XCTAssertEqual(service.snapshot.networkDownTotal,85)
        service.selectInterface(nil)
        XCTAssertEqual(service.snapshot.networkDownTotal,250)
        fake.clock.set(5.5);reading.interfaces[0].counters = .init(read:10,write:10)
        await fake.setReading(reading);service.tick()
        await eventually { await fake.aggregateCount == 4 }
        XCTAssertNil(service.snapshot.networkDownRate)
        XCTAssertEqual(service.snapshot.networkDownTotal,250)
        service.stop()
    }

    func testVisibleDetailsNoOverlapAndTopFive() async {
        let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
        await fake.setProcesses((1...8).map { .init(pid:Int32($0),name:"Process \($0)",amount:Double($0),outbound:nil,scope:"% of one core") },hold:true)
        service.start(automaticTimer:false);service.tick()
        service.setVisiblePage(.cpu);service.tick()
        await eventually { await fake.processCount == 1 }
        fake.clock.set(20);service.tick();let slowCount = await fake.processCount;XCTAssertEqual(slowCount,1)
        await fake.releaseProcesses()
        await eventually { service.snapshot.processes[.cpu]?.count == 5 }
        XCTAssertEqual(service.snapshot.processes[.cpu]?.first?.pid,8)
        service.setVisiblePage(nil)
        fake.clock.set(30);service.tick();let hiddenCount = await fake.processCount;XCTAssertEqual(hiddenCount,1)
        service.setVisiblePage(.ram);service.tick()
        await eventually { await fake.processCount == 2 }
        service.stop()
    }

    func testProbeThreeFailuresRecoveryAndHiddenGap() async {
        let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
        await fake.setProbeValues([nil,nil,nil,100,120])
        service.start(automaticTimer:false);service.tick()
        await eventually { service.snapshot.interfaces.count == 1 }
        service.setVisiblePage(.network)
        for index in 0..<3 {
            fake.clock.set(Double(index)*5);service.tick()
            await eventually { await fake.probeCount == index+1 && service.snapshot.connectivity.failures == index+1 }
        }
        XCTAssertEqual(service.snapshot.connectivity.state,.unreachable)
        XCTAssertEqual(service.snapshot.connectivity.history.points.filter { $0.reason == "Target failed" }.count,3)
        fake.clock.set(15);service.tick()
        await eventually { service.snapshot.connectivity.state == .reachable }
        XCTAssertNil(service.snapshot.connectivity.jitterMS)
        fake.clock.set(20);service.tick()
        await eventually { service.snapshot.connectivity.jitterMS == 20 }
        service.setVisiblePage(nil)
        XCTAssertEqual(service.snapshot.connectivity.state,.notMonitored)
        XCTAssertNil(service.snapshot.connectivity.history.points.last?.value)
        XCTAssertEqual(service.snapshot.connectivity.history.points.last?.reason,"Not monitored")
        fake.clock.set(40);service.tick();let hiddenProbeCount = await fake.probeCount;XCTAssertEqual(hiddenProbeCount,5)
        XCTAssertFalse(service.setProbeTarget("example.com;rm"))
        XCTAssertTrue(service.setProbeTarget("example.com"))
        service.stop()
    }

    func testObsoletePublicReplyCannotReplaceNewContext() async {
        let fake = FakeStatsEnvironment(), service = SystemStatsService(platform:fake)
        service.start(automaticTimer:false)
        fake.clock.set(0.4);service.tick()
        await eventually { await fake.publicCount == 1 }
        service.setVPNContext("connected")
        XCTAssertEqual(service.snapshot.publicIPv4.state,.refreshing)
        await fake.releasePublic(.init(ipv4:"198.51.100.1",ipv6:nil))
        await eventually { service.snapshot.publicIPv4.address == nil }
        fake.clock.set(1);service.tick()
        await eventually { service.tick(); return await fake.publicCount == 2 }
        await fake.releasePublic(.init(ipv4:"203.0.113.2",ipv6:nil))
        await eventually { service.snapshot.publicIPv4.address == "203.0.113.2" }
        XCTAssertEqual(service.snapshot.publicIPv4.state,.current)
        XCTAssertEqual(service.snapshot.publicIPv6.state,.unavailable)
        service.refreshPublicAddress();service.tick()
        await eventually { await fake.publicCount == 3 }
        await fake.releasePublic(.init(ipv4:nil,ipv6:nil,ipv4Error:true,ipv6Error:false))
        await eventually { service.snapshot.publicIPv4.state == .failed }
        XCTAssertEqual(service.snapshot.publicIPv4.address,"203.0.113.2")
        XCTAssertEqual(service.snapshot.publicIPv6.state,.unavailable)
        service.stop()
    }

    func testCapacityCadenceDiskRateAndFreshWakeBaseline() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        var reading = await fake.reading
        reading.diskID = "system"
        await fake.setReading(reading)
        service.start(automaticTimer:false);service.tick()
        await eventually { let capacity = await fake.capacityCount,aggregate = await fake.aggregateCount;return capacity == 1 && aggregate == 1 }
        await eventually { service.snapshot.disk.volumeName == "Test volume" }
        XCTAssertEqual(service.snapshot.disk.filesystem,"testfs")
        XCTAssertEqual(service.snapshot.disk.percent,0.75)
        fake.clock.set(1)
        reading.diskCounters = .init(read:500,write:300)
        await fake.setReading(reading);service.tick()
        await eventually { service.snapshot.diskReadRate == 400 }
        XCTAssertEqual(service.snapshot.diskWriteRate,200)
        fake.clock.set(29);service.tick()
        let beforeCapacity = await fake.capacityCount;XCTAssertEqual(beforeCapacity,1)
        let beforeMetadata = await fake.metadataCount;XCTAssertEqual(beforeMetadata,1)
        fake.clock.set(30);service.tick()
        await eventually { await fake.metadataCount == 2 }
        service.setSleeping(true);fake.clock.set(100);service.setSleeping(false);service.tick()
        await eventually { service.tick();return service.snapshot.cpuHistory.points.last?.time == 100 }
        XCTAssertNil(service.snapshot.diskReadRate)
        XCTAssertNil(service.snapshot.cpu.total)
        service.stop()
    }

    func testAggregateSlowReadSkipsMissedTicks() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        await fake.setHoldAggregate(true)
        service.start(automaticTimer:false);service.tick()
        await eventually { await fake.aggregateCount == 1 }
        for time in [1.0,2,10] { fake.clock.set(time);service.tick() }
        let slowCount = await fake.aggregateCount;XCTAssertEqual(slowCount,1)
        await fake.setHoldAggregate(false);await fake.releaseAggregate()
        await eventually { service.snapshot.cpu.total == 0.25 }
        fake.clock.set(11);service.tick()
        await eventually { await fake.aggregateCount == 2 }
        service.stop()
    }

    func testFiveMinuteHistoryHasHardAndTimeBounds() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        service.start(automaticTimer:false)
        for second in 0...350 {
            fake.clock.set(Double(second));service.tick()
            await eventually { service.snapshot.cpuHistory.points.last?.time == Double(second) }
        }
        XCTAssertLessThanOrEqual(service.snapshot.cpuHistory.points.count,301)
        XCTAssertGreaterThanOrEqual(service.snapshot.cpuHistory.points.first?.time ?? 0,50)
        XCTAssertEqual(service.snapshot.cpuHistory.points.last?.time,350)
        service.stop()
    }

    func testOldTargetProbeCannotUpdateNewTarget() async {
        let fake = FakeStatsEnvironment(),service = SystemStatsService(platform:fake)
        service.start(automaticTimer:false);service.tick()
        await eventually { service.snapshot.interfaces.count == 1 }
        await fake.setHoldProbe(true)
        service.setVisiblePage(.network);service.tick()
        await eventually { await fake.probeCount == 1 }
        XCTAssertTrue(service.setProbeTarget("example.com"))
        await fake.releaseProbe(80)
        await eventually { service.tick();return await fake.probeCount == 2 }
        XCTAssertNil(service.snapshot.connectivity.latencyMS)
        await fake.releaseProbe(40)
        await eventually { service.snapshot.connectivity.latencyMS == 40 }
        XCTAssertEqual(service.snapshot.connectivity.target,"example.com")
        service.stop()
    }
}
