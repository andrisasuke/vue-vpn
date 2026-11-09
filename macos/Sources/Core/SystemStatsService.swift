import Foundation
import Observation

/// The only monitoring owner. Construction is inert; app lifecycle calls start/stop.
/// Platform calls are async and run independently of VPN's BackendWorker.
@MainActor @Observable
final class SystemStatsService {
    private let platform: any SystemStatsEnvironment
    private(set) var snapshot = SystemStatsSnapshot()
    private(set) var running = false
    private(set) var visiblePage: StatsPage?
    private(set) var sleeping = false
    var changed: ((SystemStatsSnapshot) -> Void)?
    private var lowPower = false
    private var timer: Task<Void,Never>?
    private var sampleTasks: [StatsPage:Task<Void,Never>] = [:]
    private var drainTasks: [StatsPage:Task<Void,Never>] = [:]
    private var generations: [StatsPage:Int] = [:]
    private var readyPages = Set(StatsPage.allCases)
    private var automaticTimer = false
    private var detailPage: StatsPage?
    private var nextSample: [StatsPage:TimeInterval] = [:]
    private var samplesUntilReady: [StatsPage:Int] = [:]
    private var detailTask: Task<Void,Never>?
    private var capacityTask: Task<Void,Never>?
    private var frequencyTask: Task<Void,Never>?
    private var probeTask: Task<Void,Never>?
    private var publicTask: Task<Void,Never>?
    private var nextDetail = 0.0
    private var nextCapacity = 0.0
    private var nextProbe = 0.0
    private var nextFrequency = 0.0
    private var publicDeadline: TimeInterval?
    private var publicGeneration = 0
    private var detailGeneration = 0
    private var probeGeneration = 0
    private var runGeneration = 0
    private var lastDisk: (String, StatsCounters, TimeInterval)?
    private var networkBaseline: [String:(StatsCounters,TimeInterval)] = [:]
    private var networkTotals: [String:StatsCounters] = [:]
    private var networkSeen: [String:TimeInterval] = [:]
    private var networkContext = ""
    private var networkContextReady = true
    private var vpnContext = ""
    private var manualInterface: String?
    private var recentLatency: [Double] = []
    private var freshCPUAfterWake = false
    private var freshDetailBaseline: Set<StatsPage> = []

    init(platform: any SystemStatsEnvironment) { self.platform = platform }

    var timerScheduled: Bool { timer != nil }

    func setMonitoring(_ page:StatsPage, enabled:Bool) {
        guard snapshot.enabledPages.contains(page) != enabled else { return }
        if enabled {
            snapshot.enabledPages.insert(page); snapshot.collectingPages.insert(page)
            samplesUntilReady[page] = page == .ram ? 1 : 2
        } else {
            snapshot.enabledPages.remove(page); snapshot.collectingPages.remove(page)
            addGap(page,at:platform.now(),reason:"Disabled")
            snapshot.processes[page] = []
            switch page {
            case .cpu: snapshot.cpu = StatsCPU()
            case .ram: snapshot.ram = StatsRAM()
            case .ssd:
                snapshot.disk = StatsDisk(id:"system",name:"Internal SSD")
                snapshot.diskReadRate = nil; snapshot.diskWriteRate = nil; lastDisk = nil
            case .network:
                snapshot.interfaces = []; snapshot.selectedInterface = nil
                snapshot.networkDownRate = nil; snapshot.networkUpRate = nil
                networkBaseline.removeAll(); networkContext = ""; networkContextReady = false
                snapshot.publicIPv4 = StatsPublicAddress(); snapshot.publicIPv6 = StatsPublicAddress()
                snapshot.connectivity.state = .notMonitored
                publicDeadline = nil; publicGeneration += 1; probeGeneration += 1
            }
        }
        prepareDomain(page)
        updateTimer(); publish()
    }

    private func prepareDomain(_ page:StatsPage) {
        generations[page,default:0] += 1
        let generation = generations[page,default:0]
        readyPages.remove(page)
        var owned:[Task<Void,Never>] = []
        if let task = sampleTasks[page] { owned.append(task) }
        if detailPage == page, let task = detailTask { owned.append(task); detailGeneration += 1 }
        if page == .ssd, let task = capacityTask { owned.append(task) }
        if page == .cpu, let task = frequencyTask { owned.append(task) }
        if page == .network {
            if let task = probeTask { owned.append(task) }
            if let task = publicTask { owned.append(task) }
            publicGeneration += 1; probeGeneration += 1; publicDeadline = nil
        }
        owned.forEach { $0.cancel() }
        let prior = drainTasks[page]
        drainTasks[page] = Task { [weak self,platform] in
            await prior?.value
            for task in owned { await task.value }
            await platform.resetBaselines(page)
            guard let self, self.generations[page,default:0] == generation else { return }
            self.drainTasks[page] = nil
            guard self.snapshot.enabledPages.contains(page) else { return }
            self.readyPages.insert(page)
            let now = platform.now()
            self.nextSample[page] = now
            if self.visiblePage == page { self.nextDetail = now }
            if page == .ssd { self.lastDisk = nil; self.nextCapacity = now; self.freshDetailBaseline.insert(page) }
            if page == .cpu { self.freshCPUAfterWake = true; self.nextFrequency = now }
            if page == .network {
                self.networkBaseline.removeAll(); self.nextProbe = now; self.freshDetailBaseline.insert(page)
            }
            self.updateTimer()
        }
    }

    private func updateTimer() {
        let needed = running && !sleeping && automaticTimer && !snapshot.enabledPages.isEmpty
        if !needed { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for:.milliseconds(200),tolerance:.milliseconds(100))
            }
        }
    }

    func start(automaticTimer: Bool = true) {
        guard !running else { return }
        running = true
        runGeneration += 1
        snapshot.collectingPages = snapshot.enabledPages
        for page in snapshot.enabledPages { samplesUntilReady[page] = page == .ram ? 1 : 2 }
        let now = platform.now()
        for page in StatsPage.allCases { nextSample[page] = now }
        nextCapacity = now; nextDetail = now; nextProbe = now; nextFrequency = now
        self.automaticTimer = automaticTimer
        requestPublicAddress()
        updateTimer()
        publish()
    }

    func stop() {
        guard running else { return }
        running = false; runGeneration += 1; publicGeneration += 1; detailGeneration += 1;probeGeneration += 1
        for task in [timer,detailTask,capacityTask,frequencyTask,probeTask,publicTask] { task?.cancel() }
        for task in sampleTasks.values { task.cancel() }
        for page in snapshot.enabledPages { prepareDomain(page) }
        timer = nil; publicDeadline = nil
        visiblePage = nil
    }

    func setLowPower(_ value: Bool) {
        guard lowPower != value else { return }
        lowPower = value
        let now = platform.now()
        for page in snapshot.enabledPages { nextSample[page] = now + (value ? 2 : 1) }
        nextDetail = now + (value ? 5 : 3)
    }

    func setVisiblePage(_ page: StatsPage?) {
        guard visiblePage != page else { return }
        visiblePage = page; detailGeneration += 1;probeGeneration += 1
        detailTask?.cancel()
        frequencyTask?.cancel()
        probeTask?.cancel()
        if let page, (page == .ssd || page == .network) {
            freshDetailBaseline.insert(page)
            snapshot.processes[page] = []
        }
        if page != .cpu { snapshot.cpu.frequencyMHz = nil }
        let now = platform.now()
        nextDetail = now; nextProbe = now; nextFrequency = now
        if page == .network, snapshot.enabledPages.contains(.network),running,!sleeping { resetProbe();publish() }
        else {
            snapshot.connectivity.state = .notMonitored
            snapshot.processes.removeAll()
            if snapshot.enabledPages.contains(.network) {
                snapshot.connectivity.history.add(.init(time:now,value:nil,reason:"Not monitored"))
            }
            publish()
        }
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        let now = platform.now()
        if value {
            networkContext = ""; networkContextReady = false
            runGeneration += 1; detailGeneration += 1;probeGeneration += 1;publicGeneration += 1
            for page in snapshot.enabledPages { prepareDomain(page); addGap(page,at:now) }
            updateTimer()
            snapshot.connectivity.state = .notMonitored
            if snapshot.enabledPages.contains(.network) {
                snapshot.connectivity.history.add(.init(time:now,value:nil,reason:"Sleep"))
            }
            publish()
        } else {
            lastDisk = nil; networkBaseline.removeAll()
            freshCPUAfterWake = true; freshDetailBaseline = [.ssd,.network]
            snapshot.collectingPages = snapshot.enabledPages
            for page in snapshot.enabledPages { samplesUntilReady[page] = page == .ram ? 1 : 2 }
            for page in snapshot.enabledPages { nextSample[page] = now }
            nextDetail = now; nextCapacity = now
            nextProbe = now; nextFrequency = now
            requestPublicAddress()
            updateTimer()
            publish()
        }
    }

    func selectInterface(_ id: String?) {
        guard snapshot.enabledPages.contains(.network) else { return }
        manualInterface = id
        snapshot.automaticInterface = id == nil
        snapshot.selectedInterface = id ?? snapshot.interfaces.first(where:{$0.active})?.id
        networkRatesForSelection()
        publish()
    }

    func setVPNContext(_ value: String) {
        guard vpnContext != value else { return }
        vpnContext = value
        guard snapshot.enabledPages.contains(.network),running,!sleeping else { return }
        requestPublicAddress(); resetProbe()
    }

    @discardableResult func setProbeTarget(_ target: String) -> Bool {
        let value = target.trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.count <= 253, !value.isEmpty,
              value.range(of:"^[A-Za-z0-9][A-Za-z0-9.:-]*$",options:.regularExpression) != nil else { return false }
        guard value != snapshot.connectivity.target else { return true }
        snapshot.connectivity.target = value
        if snapshot.enabledPages.contains(.network),running,!sleeping { resetProbe() }
        publish()
        return true
    }

    func refreshPublicAddress() { requestPublicAddress(immediate:true) }

    private func requestPublicAddress(immediate: Bool = false) {
        guard running, !sleeping, snapshot.enabledPages.contains(.network), networkContextReady else { return }
        publicGeneration += 1
        publicTask?.cancel()
        publicDeadline = platform.now() + (immediate ? 0 : 0.35)
        for key in [\SystemStatsSnapshot.publicIPv4,\SystemStatsSnapshot.publicIPv6] {
            let old = snapshot[keyPath:key]
            snapshot[keyPath:key].state = old.address == nil ? .refreshing : .stale
        }
        publish()
    }

    /// One shared scheduler. A due operation starts only if its previous read finished.
    /// Missed ticks are skipped by deriving the next deadline from current time.
    func tick() {
        guard running, !sleeping else { return }
        let now = platform.now()
        for page in StatsPage.allCases where snapshot.enabledPages.contains(page) && readyPages.contains(page) {
            guard now >= (nextSample[page] ?? 0) else { continue }
            nextSample[page] = now + (lowPower ? 2 : 1)
            guard sampleTasks[page] == nil else { continue }
            let epoch = generations[page,default:0], run = runGeneration
            sampleTasks[page] = Task { [weak self,platform] in
                let reading = await platform.sample(page)
                guard let self else { return }
                self.sampleTasks[page] = nil
                guard self.running,!self.sleeping,self.runGeneration == run,
                      self.snapshot.enabledPages.contains(page),self.generations[page,default:0] == epoch,
                      !Task.isCancelled else { return }
                if let remaining = self.samplesUntilReady[page] {
                    if remaining <= 1 { self.snapshot.collectingPages.remove(page); self.samplesUntilReady[page] = nil }
                    else { self.samplesUntilReady[page] = remaining-1 }
                }
                self.accept(reading,at:platform.now())
            }
        }
        if snapshot.enabledPages.contains(.ssd), readyPages.contains(.ssd), now >= nextCapacity {
            nextCapacity = now + 30
            if capacityTask == nil {
                let epoch = runGeneration, generation = generations[.ssd,default:0]
                capacityTask = Task { [weak self,platform] in
                    let value = await platform.capacity()
                    let metadata = await platform.volumeMetadata()
                    guard let self else { return }
                    self.capacityTask = nil
                    if self.runGeneration != epoch, self.running,!self.sleeping { self.nextCapacity = platform.now() }
                    guard self.running,!self.sleeping,self.runGeneration == epoch,self.snapshot.enabledPages.contains(.ssd),self.generations[.ssd,default:0] == generation,!Task.isCancelled else { return }
                    self.snapshot.disk.total = value?.total
                    self.snapshot.disk.available = value?.available
                    self.snapshot.disk.reclaimable = value?.reclaimable
                    self.snapshot.disk.volumeName = metadata.name
                    self.snapshot.disk.filesystem = metadata.filesystem
                    self.publish()
                }
            }
        }
        if let page = visiblePage, snapshot.enabledPages.contains(page), readyPages.contains(page), now >= nextDetail {
            nextDetail = now + (lowPower ? 5 : 3)
            if detailTask == nil {
                let generation = detailGeneration, domainGeneration = generations[page,default:0]
                detailPage = page
                detailTask = Task { [weak self,platform] in
                    let values = await platform.processes(page)
                    guard let self else { return }
                    self.detailTask = nil; self.detailPage = nil
                    if self.visiblePage != page || self.detailGeneration != generation { self.nextDetail = platform.now() }
                    guard self.running,!self.sleeping,self.visiblePage == page,self.detailGeneration == generation,self.snapshot.enabledPages.contains(page),self.generations[page,default:0] == domainGeneration,!Task.isCancelled else { return }
                    if self.freshDetailBaseline.remove(page) != nil { self.snapshot.processes[page] = [];self.publish();return }
                    self.snapshot.processes[page] = Array(values.sorted { $0.amount > $1.amount }.prefix(5))
                    self.publish()
                }
            }
        }
        if visiblePage == .cpu, snapshot.enabledPages.contains(.cpu), readyPages.contains(.cpu), now >= nextFrequency {
            nextFrequency = now + (lowPower ? 2 : 1)
            if frequencyTask == nil {
                frequencyTask = Task { [weak self,platform] in
                    let value = await platform.frequency()
                    guard let self else { return }
                    self.frequencyTask = nil
                    if Task.isCancelled,self.visiblePage == .cpu { self.nextFrequency = platform.now() }
                    guard self.running,!self.sleeping,self.visiblePage == .cpu,self.snapshot.enabledPages.contains(.cpu),!Task.isCancelled else { return }
                    self.snapshot.cpu.frequencyMHz = value; self.publish()
                }
            }
        }
        if visiblePage == .network, snapshot.enabledPages.contains(.network), readyPages.contains(.network), now >= nextProbe {
            nextProbe = now + 5
            if probeTask == nil {
                let target = snapshot.connectivity.target, generation = probeGeneration
                probeTask = Task { [weak self,platform] in
                    let latency = await platform.probe(target)
                    guard let self else { return }
                    self.probeTask = nil
                    if self.probeGeneration != generation,self.visiblePage == .network { self.nextProbe = platform.now() }
                    guard self.running,!self.sleeping,self.visiblePage == .network,self.probeGeneration == generation,self.snapshot.enabledPages.contains(.network),!Task.isCancelled else { return }
                    self.acceptProbe(latency,at:platform.now())
                }
            }
        }
        if snapshot.enabledPages.contains(.network), readyPages.contains(.network), let deadline = publicDeadline, now >= deadline, publicTask == nil {
            publicDeadline = nil
            let generation = publicGeneration
            snapshot.publicIPv4.state = .refreshing; snapshot.publicIPv6.state = .refreshing; publish()
            publicTask = Task { [weak self,platform] in
                let result = await platform.publicAddress()
                guard let self else { return }
                self.publicTask = nil
                guard self.running,!self.sleeping,self.publicGeneration == generation,self.snapshot.enabledPages.contains(.network),!Task.isCancelled else { return }
                self.acceptPublic(result)
            }
        }
    }

    private func accept(_ reading: StatsDomainReading,at now: TimeInterval) {
        switch reading {
        case .cpu(let cpu):
        let previousFrequency = snapshot.cpu.frequencyMHz
        snapshot.cpu = cpu
        snapshot.cpu.frequencyMHz = previousFrequency
        if freshCPUAfterWake {
            freshCPUAfterWake = false
            snapshot.cpu.total = nil; snapshot.cpu.system = nil; snapshot.cpu.user = nil; snapshot.cpu.idle = nil
            for index in snapshot.cpu.cores.indices { snapshot.cpu.cores[index].usage = nil }
        }
        snapshot.cpuHistory.add(.init(time:now,value:snapshot.cpu.total))
        case .ram(let ram):
            snapshot.ram = ram
            snapshot.ramHistory.add(.init(time:now,value:ram.percent))
        case .ssd(let diskID,let diskName,let diskCounters):
        if snapshot.disk.id != diskID {
            snapshot.disk.total = nil; snapshot.disk.available = nil; snapshot.disk.reclaimable = nil
            snapshot.disk.volumeName = nil; snapshot.disk.filesystem = nil
            nextCapacity = now
        }
        snapshot.disk.id = diskID; snapshot.disk.name = diskName
        if let counter = diskCounters {
            if let previous = lastDisk, previous.0 == diskID, now > previous.2,
               counter.read >= previous.1.read,counter.write >= previous.1.write {
                snapshot.diskReadRate = Double(counter.read - previous.1.read)/(now-previous.2)
                snapshot.diskWriteRate = Double(counter.write - previous.1.write)/(now-previous.2)
            } else { snapshot.diskReadRate = nil; snapshot.diskWriteRate = nil }
            lastDisk = (diskID,counter,now)
        } else { lastDisk = nil; snapshot.diskReadRate = nil; snapshot.diskWriteRate = nil }
        snapshot.diskHistory.add(.init(time:now,value:snapshot.diskReadRate,second:snapshot.diskWriteRate))
        case .network(let interfaces,let automaticInterface):
        let previousIDs = Set(snapshot.interfaces.map(\.id))
        snapshot.interfaces = interfaces
        let currentIDs = Set(interfaces.map(\.id))
        networkBaseline = networkBaseline.filter { currentIDs.contains($0.key) }
        var rates: [String:(Double,Double)] = [:]
        for item in interfaces {
            networkSeen[item.id] = now
            if let previous = networkBaseline[item.id], item.counters.read >= previous.0.read,item.counters.write >= previous.0.write {
                let delta = StatsCounters(read:item.counters.read-previous.0.read,write:item.counters.write-previous.0.write)
                var total = networkTotals[item.id] ?? StatsCounters(read:0,write:0)
                total.read += delta.read; total.write += delta.write; networkTotals[item.id] = total
                if now > previous.1 {
                    rates[item.id] = (Double(delta.read)/(now-previous.1),Double(delta.write)/(now-previous.1))
                }
            }
            networkBaseline[item.id] = (item.counters,now)
        }
        if networkSeen.count > 16 {
            for id in networkSeen.sorted(by:{$0.value < $1.value}).prefix(networkSeen.count-16).map(\.key) {
                networkSeen.removeValue(forKey:id); networkTotals.removeValue(forKey:id); networkBaseline.removeValue(forKey:id)
            }
        }
        if previousIDs != currentIDs, let manualInterface, !currentIDs.contains(manualInterface) { self.manualInterface = nil }
        let selected = manualInterface ?? automaticInterface
        snapshot.selectedInterface = selected
        snapshot.automaticInterface = manualInterface == nil
        networkRatesForSelection()
        snapshot.networkDownRate = selected.flatMap { rates[$0]?.0 }
        snapshot.networkUpRate = selected.flatMap { rates[$0]?.1 }
        let selectedItem = interfaces.first { $0.id == automaticInterface }
        let context = "\(selectedItem?.id ?? "none")|\(selectedItem?.mac ?? "")|\(selectedItem?.addresses.joined(separator:",") ?? "")|\(selectedItem?.active ?? false)"
        networkContextReady = true
        if context != networkContext { networkContext = context; requestPublicAddress(); resetProbe() }
        snapshot.networkHistory.add(.init(time:now,value:snapshot.networkDownRate,second:snapshot.networkUpRate))
        }
        publish()
    }

    private func networkRatesForSelection() {
        let id = snapshot.selectedInterface
        let total = id.flatMap { networkTotals[$0] } ?? StatsCounters(read:0,write:0)
        snapshot.networkDownTotal = total.read; snapshot.networkUpTotal = total.write
        snapshot.networkDownRate = nil; snapshot.networkUpRate = nil
    }

    private func acceptProbe(_ latency: Double?,at now: TimeInterval) {
        if let latency, latency >= 0 {
            snapshot.connectivity.failures = 0
            snapshot.connectivity.state = .reachable
            snapshot.connectivity.latencyMS = latency
            recentLatency.append(latency)
            if recentLatency.count > 12 { recentLatency.removeFirst() }
            if recentLatency.count >= 2 {
                let differences = zip(recentLatency.dropFirst(),recentLatency).map { abs($0-$1) }
                snapshot.connectivity.jitterMS = differences.reduce(0,+)/Double(differences.count)
            }
            snapshot.connectivity.history.add(.init(time:now,value:latency))
        } else {
            snapshot.connectivity.failures += 1
            snapshot.connectivity.state = snapshot.connectivity.failures >= 3 ? .unreachable : .checking
            snapshot.connectivity.latencyMS = nil
            snapshot.connectivity.jitterMS = nil
            recentLatency.removeAll()
            snapshot.connectivity.history.add(.init(time:now,value:nil,reason:"Target failed"))
        }
        publish()
    }
    private func resetProbe() {
        probeGeneration += 1
        probeTask?.cancel()
        nextProbe = platform.now()
        recentLatency.removeAll()
        snapshot.connectivity.failures = 0
        snapshot.connectivity.latencyMS = nil; snapshot.connectivity.jitterMS = nil
        snapshot.connectivity.state = visiblePage == .network ? .checking : .notMonitored
        snapshot.connectivity.history.add(.init(time:platform.now(),value:nil,reason:"Context changed"))
    }
    private func acceptPublic(_ result: StatsPublicResult) {
        let date = Date()
        func update(_ value: inout StatsPublicAddress,_ address: String?,_ error: Bool) {
            if let address, !address.isEmpty { value.address = address; value.state = .current; value.updated = date }
            else { value.state = error ? .failed : .unavailable;if !error { value.address = nil } }
        }
        update(&snapshot.publicIPv4,result.ipv4,result.ipv4Error)
        update(&snapshot.publicIPv6,result.ipv6,result.ipv6Error)
        publish()
    }
    private func addGap(_ page: StatsPage,at now: TimeInterval,reason:String = "Sleep") {
        let point = StatsPoint(time:now,value:nil,reason:reason)
        switch page {
        case .cpu:snapshot.cpuHistory.add(point)
        case .ram:snapshot.ramHistory.add(point)
        case .ssd:snapshot.diskHistory.add(point)
        case .network:snapshot.networkHistory.add(point)
        }
    }
    private func publish() { changed?(snapshot) }
}
