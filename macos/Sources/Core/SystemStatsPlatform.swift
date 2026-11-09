// Native counter arithmetic adapted from exelban/Stats, commit
// 21f866bb3e8ba606c9c01769f558accbcf1fa27c (MIT, Serhiy Mytrovtsiy).
// The complete permission notice is bundled in ThirdPartyLicenses/Stats.txt.
import Foundation
import Darwin
import IOKit
import IOKit.storage
import DiskArbitration
import SystemConfiguration
import Network

final class NativeSystemStatsEnvironment: SystemStatsEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedCPUName: String??
    private var previousCPU: [[UInt32]]?
    private var cachedCoreKinds: [Int:StatsCore.Kind]?
    private var cachedDisk: (id:String,name:String,driver:io_service_t,checkedAt:TimeInterval)?
    private var processDisk: [Int32:(UInt64,UInt64,TimeInterval)] = [:]
    private var processNetwork: [Int32:(UInt64,UInt64,TimeInterval)] = [:]
    private let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 5
        return configuration
    }())
    deinit { if let cachedDisk { IOObjectRelease(cachedDisk.driver) } }

    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sample(_ page: StatsPage) async -> StatsDomainReading {
        let work = Task.detached(priority:.utility) { () -> StatsDomainReading in
            switch page {
            case .cpu: return .cpu(self.readCPU())
            case .ram: return .ram(self.readRAM())
            case .ssd:
                let disk = self.diskIdentityAndCounters()
                return .ssd(id:disk.0,name:disk.1,counters:disk.2)
            case .network:
                let links = self.readInterfaces()
                return .network(interfaces:links.0,automaticInterface:links.1)
            }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    func resetBaselines(_ page: StatsPage) async {
        lock.withLock {
            switch page {
            case .cpu: previousCPU = nil
            case .ssd:
                processDisk.removeAll()
                if let cachedDisk { IOObjectRelease(cachedDisk.driver); self.cachedDisk = nil }
            case .network: processNetwork.removeAll()
            case .ram: break
            }
        }
    }
    func capacity() async -> (total: UInt64, available: UInt64, reclaimable: UInt64?)? {
        let work = Task.detached(priority:.utility) { self.readCapacity() }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    func volumeMetadata() async -> (name:String?, filesystem:String?) {
        let work = Task.detached(priority:.utility) { () -> (String?,String?) in
            var fs = statfs()
            let valid = statfs("/",&fs) == 0
            let capacity = MemoryLayout.size(ofValue:fs.f_fstypename)
            let type: String? = valid ? withUnsafePointer(to:&fs.f_fstypename) { pointer in
                pointer.withMemoryRebound(to:CChar.self,capacity:capacity) { String(validatingUTF8:$0) }
            } : nil
            let name = try? URL(fileURLWithPath:"/").resourceValues(forKeys:[.volumeNameKey]).volumeName
            return (name,type)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    func processes(_ page: StatsPage) async -> [StatsProcess] {
        let work = Task.detached(priority:.utility) { self.readProcesses(page) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    func frequency() async -> Double? { nil } // No supported public live frequency API on Apple Silicon.
    func probe(_ target: String) async -> Double? {
        let started = now()
        let owner = StatsCancellationOwner()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let connection = NativeStatsProbeConnection(target:target)
                let gate = ProbeGate(connection:connection,continuation:continuation,started:started)
                guard owner.install({ gate.finish(nil) }) else { return }
                gate.start()
            }
        } onCancel: { owner.cancel() }
    }
    func publicAddress() async -> StatsPublicResult {
        guard !Task.isCancelled else { return StatsPublicResult(ipv4:nil,ipv6:nil) }
        let families = availableAddressFamilies()
        guard !Task.isCancelled else { return StatsPublicResult(ipv4:nil,ipv6:nil) }
        async let v4: String? = families.0 ? fetchAddress("https://api4.ipify.org",family:AF_INET) : nil
        async let v6: String? = families.1 ? fetchAddress("https://api6.ipify.org",family:AF_INET6) : nil
        let a = await v4, b = await v6
        return StatsPublicResult(ipv4:a,ipv6:b,ipv4Error:families.0 && a == nil,ipv6Error:families.1 && b == nil)
    }
    private func availableAddressFamilies() -> (Bool,Bool) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return (true,true) }
        defer { freeifaddrs(pointer) }
        var ipv4 = false,ipv6 = false,node = pointer
        while let current = node {
            if Task<Never,Never>.isCancelled { return (false,false) }
            defer { node = current.pointee.ifa_next }
            let entry = current.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_INET) { ipv4 = true }
            if address.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
                if getnameinfo(address,socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                    let text = String(decoding:host.prefix(while:{$0 != 0}).map(UInt8.init(bitPattern:)),as:UTF8.self)
                    if !text.lowercased().hasPrefix("fe80:") { ipv6 = true }
                }
            }
        }
        return (ipv4,ipv6)
    }
    private func fetchAddress(_ address: String,family: Int32) async -> String? {
        guard !Task.isCancelled, let url = URL(string:address) else { return nil }
        do {
            let (data,response) = try await session.data(from:url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,data.count <= 128,
                  let text = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) else { return nil }
            var storage = in6_addr()
            guard text.withCString({ inet_pton(family,$0,&storage) }) == 1 else { return nil }
            return text
        } catch { return nil }
    }

    private func readCPU() -> StatsCPU {
        var result = StatsCPU()
        if let cached = lock.withLock({ cachedCPUName }) { result.name = cached }
        else {
            var length = 0
            var name: String?
            if sysctlbyname("machdep.cpu.brand_string",nil,&length,nil,0) == 0, length > 1, length < 1024 {
                var bytes = [CChar](repeating:0,count:length)
                if sysctlbyname("machdep.cpu.brand_string",&bytes,&length,nil,0) == 0 { name = String(validatingUTF8:bytes) }
            }
            lock.withLock { cachedCPUName = .some(name) }; result.name = name
        }
        guard !Task<Never,Never>.isCancelled else { return result }
        result.uptime = ProcessInfo.processInfo.systemUptime
        var loads = [Double](repeating:0,count:3)
        if getloadavg(&loads,3) == 3 { result.loads = loads }
        guard !Task<Never,Never>.isCancelled else { return result }
        var count: natural_t = 0, pointer: processor_info_array_t?, slots: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&count,&pointer,&slots) == KERN_SUCCESS,
              let pointer else { return result }
        defer { vm_deallocate(mach_task_self_,vm_address_t(bitPattern:pointer),vm_size_t(Int(slots)*MemoryLayout<integer_t>.stride)) }
        let samples = (0..<Int(count)).map { index in
            (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern:pointer[index*Int(CPU_STATE_MAX)+$0]) }
        }
        guard !Task<Never,Never>.isCancelled else { return result }
        lock.lock(); let old = previousCPU; previousCPU = samples; lock.unlock()
        guard let old, old.count == samples.count else { return result }
        guard !Task<Never,Never>.isCancelled else { return result }
        var totals = [UInt64](repeating:0,count:Int(CPU_STATE_MAX))
        let kinds = coreKinds()
        for index in samples.indices {
            if Task<Never,Never>.isCancelled { return result }
            let deltas = zip(samples[index],old[index]).map { UInt64($0 &- $1) }
            for state in deltas.indices { totals[state] += deltas[state] }
            let all = deltas.reduce(0,+)
            let kind = kinds[index] ?? .unknown
            result.cores.append(.init(kind:kind,usage:all > 0 ? Double(all-deltas[Int(CPU_STATE_IDLE)])/Double(all) : nil))
        }
        let all = totals.reduce(0,+)
        if all > 0 {
            result.system = Double(totals[Int(CPU_STATE_SYSTEM)])/Double(all)
            result.user = Double(totals[Int(CPU_STATE_USER)]+totals[Int(CPU_STATE_NICE)])/Double(all)
            result.idle = Double(totals[Int(CPU_STATE_IDLE)])/Double(all)
            result.total = 1 - result.idle!
        }
        return result
    }

    private func coreKinds() -> [Int:StatsCore.Kind] {
        lock.lock()
        if let cachedCoreKinds { lock.unlock(); return cachedCoreKinds }
        lock.unlock()
        var result: [Int:StatsCore.Kind] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleARMPE"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service,kIOServicePlane,&iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                var child = IOIteratorNext(iterator)
                while child != 0 {
                    defer { IOObjectRelease(child); child = IOIteratorNext(iterator) }
                    if Task<Never,Never>.isCancelled { return result }
                    var name = [CChar](repeating:0,count:128)
                    guard IORegistryEntryGetName(child,&name) == KERN_SUCCESS else { continue }
                    let label = String(decoding:name.prefix(while:{$0 != 0}).map(UInt8.init(bitPattern:)),as:UTF8.self)
                    guard label.hasPrefix("cpu"),let index = Int(label.dropFirst(3)),
                          let raw = IORegistryEntryCreateCFProperty(child,"cluster-type" as CFString,kCFAllocatorDefault,0),
                          let data = raw.takeRetainedValue() as? Data,
                          let type = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.controlCharacters) else { continue }
                    result[index] = type == "E" ? .efficiency : ["P","M"].contains(type) ? .performance : .unknown
                }
            }
        }
        lock.lock(); cachedCoreKinds = result; lock.unlock()
        return result
    }

    private func readRAM() -> StatsRAM {
        var value = StatsRAM()
        guard !Task<Never,Never>.isCancelled else { return value }
        guard let physical = sysctlInteger64("hw.memsize"),physical > 0 else { return value }
        value.total = physical
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size/MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to:&stats) {
            $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count)
            }
        }
        guard status == KERN_SUCCESS else { return value }
        guard !Task<Never,Never>.isCancelled else { return value }
        guard let page = sysctlInteger64("hw.pagesize"),page > 0 else { return value }
        let wired = UInt64(stats.wire_count)*page
        let compressed = UInt64(stats.compressor_page_count)*page
        let active = UInt64(stats.active_count)*page
        let inactive = UInt64(stats.inactive_count)*page
        let speculative = UInt64(stats.speculative_count)*page
        let reclaimable = UInt64(stats.purgeable_count)*page + UInt64(stats.external_page_count)*page
        let occupied = active + inactive + speculative + wired + compressed
        guard occupied >= reclaimable,occupied-reclaimable <= physical else { return value }
        let used = occupied-reclaimable
        guard used >= wired+compressed else { return value }
        value.app = used-wired-compressed; value.wired = wired; value.compressed = compressed; value.free = physical-used
        var pressure: Int32 = 0, pressureSize = MemoryLayout<Int32>.size
        guard !Task<Never,Never>.isCancelled else { return value }
        if sysctlbyname("kern.memorystatus_vm_pressure_level",&pressure,&pressureSize,nil,0) == 0 {
            value.pressure = pressure == 4 ? "Critical" : pressure == 2 ? "Warning" : "Normal"
        }
        guard !Task<Never,Never>.isCancelled else { return value }
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage",&swap,&swapSize,nil,0) == 0 {
            value.swapTotal = swap.xsu_total; value.swapUsed = swap.xsu_used
        }
        return value
    }

    private func readCapacity() -> (total: UInt64, available: UInt64, reclaimable: UInt64?)? {
        guard !Task<Never,Never>.isCancelled else { return nil }
        var fs = statfs()
        guard statfs("/",&fs) == 0,fs.f_blocks > 0 else { return nil }
        let total = UInt64(fs.f_blocks)*UInt64(fs.f_bsize)
        let available = UInt64(fs.f_bavail)*UInt64(fs.f_bsize)
        return available <= total ? (total,available,nil) : nil
    }

    private func diskIdentityAndCounters() -> (String,String,StatsCounters?) {
        guard !Task<Never,Never>.isCancelled else { return ("system","Internal SSD",nil) }
        if let cachedDisk,now()-cachedDisk.checkedAt < 30 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(cachedDisk.driver,&id) == KERN_SUCCESS,
               String(id) == cachedDisk.id {
                return (cachedDisk.id,cachedDisk.name,diskCounters(cachedDisk.driver))
            }
        }
        if let cachedDisk { IOObjectRelease(cachedDisk.driver);self.cachedDisk = nil }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault,session,URL(fileURLWithPath:"/") as CFURL),
              let bsd = DADiskGetBSDName(disk) else { return ("system","Internal SSD",nil) }
        let name = String(cString:bsd)
        guard !Task<Never,Never>.isCancelled else { return (name,"Internal SSD",nil) }
        var media = IOServiceGetMatchingService(kIOMainPortDefault,IOBSDNameMatching(kIOMainPortDefault,0,bsd))
        guard media != 0 else { return (name,"Internal SSD",nil) }
        defer { IOObjectRelease(media) }
        var visited = Set<UInt64>()
        for _ in 0..<32 {
            if Task<Never,Never>.isCancelled { return (name,"Internal SSD",nil) }
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(media,&id) != KERN_SUCCESS || !visited.insert(id).inserted { break }
            if IOObjectConformsTo(media,kIOBlockStorageDriverClass) != 0 {
                IOObjectRetain(media)
                let label = "Internal SSD (\(name))"
                cachedDisk = (String(id),label,media,now())
                return (String(id),label,diskCounters(media))
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(media,kIOServicePlane,&parent) == KERN_SUCCESS else { break }
            IOObjectRelease(media); media = parent
        }
        return (name,"Internal SSD (\(name))",nil)
    }

    private func diskCounters(_ driver:io_service_t) -> StatsCounters? {
        guard !Task<Never,Never>.isCancelled else { return nil }
        let property = IORegistryEntryCreateCFProperty(driver,kIOBlockStorageDriverStatisticsKey as CFString,kCFAllocatorDefault,0)
        let stats = property?.takeRetainedValue() as? NSDictionary
        guard let read = (stats?[kIOBlockStorageDriverStatisticsBytesReadKey] as? NSNumber)?.uint64Value,
              let write = (stats?[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? NSNumber)?.uint64Value else { return nil }
        return StatsCounters(read:read,write:write)
    }

    private func readInterfaces() -> ([StatsInterface],String?) {
        guard !Task<Never,Never>.isCancelled else { return ([],nil) }
        var physical = Set<String>()
        var labels: [String:String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for item in all {
                if Task<Never,Never>.isCancelled { return ([],nil) }
                guard let bsdName = SCNetworkInterfaceGetBSDName(item),
                      let typeName = SCNetworkInterfaceGetInterfaceType(item) else { continue }
                let bsd = String(describing:bsdName)
                let type = String(describing:typeName)
                if type == (kSCNetworkInterfaceTypeEthernet as String) || type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                    physical.insert(bsd)
                    let label = SCNetworkInterfaceGetLocalizedDisplayName(item).map { String(describing:$0) } ?? type
                    labels[bsd] = "\(label) (\(bsd))"
                }
            }
        }
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard !Task<Never,Never>.isCancelled else { return ([],nil) }
        guard getifaddrs(&pointer) == 0 else { return ([],nil) }
        defer { freeifaddrs(pointer) }
        var collected: [String:StatsInterface] = [:]
        var node = pointer
        while let current = node {
            if Task<Never,Never>.isCancelled { return ([],nil) }
            defer { node = current.pointee.ifa_next }
            let entry = current.pointee, name = String(cString:entry.ifa_name)
            guard physical.contains(name),let address = entry.ifa_addr else { continue }
            var item = collected[name] ?? StatsInterface(id:name,name:labels[name] ?? name,active:false,mac:nil,addresses:[],counters:.init(read:0,write:0))
            item.active = entry.ifa_flags & UInt32(IFF_UP) != 0 && entry.ifa_flags & UInt32(IFF_RUNNING) != 0
            if address.pointee.sa_family == UInt8(AF_LINK),let data = entry.ifa_data {
                let counters = data.assumingMemoryBound(to:if_data.self).pointee
                item.counters = StatsCounters(read:UInt64(counters.ifi_ibytes),write:UInt64(counters.ifi_obytes))
                let link = UnsafeRawPointer(address).assumingMemoryBound(to:sockaddr_dl.self).pointee
                let length = Int(link.sdl_alen), offset = Int(link.sdl_nlen)
                if length == 6 {
                    let bytes = withUnsafeBytes(of:link.sdl_data) { Array($0) }
                    if offset+length <= bytes.count { item.mac = bytes[offset..<offset+length].map { String(format:"%02x",$0) }.joined(separator:":") }
                }
            } else if address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating:0,count:Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST) == 0 {
                    item.addresses.append(String(decoding:host.prefix(while:{$0 != 0}).map(UInt8.init(bitPattern:)),as:UTF8.self))
                }
            }
            collected[name] = item
        }
        let values = collected.values.map { item -> StatsInterface in
            var sorted = item;sorted.addresses.sort();return sorted
        }.sorted { $0.id < $1.id }
        guard !Task<Never,Never>.isCancelled else { return ([],nil) }
        var automatic: String?
        if let global = SCDynamicStoreCopyValue(nil,"State:/Network/Global/IPv4" as CFString) as? [String:Any],
           let primary = global["PrimaryInterface"] as? String,physical.contains(primary) { automatic = primary }
        if automatic == nil,
           let setup = SCDynamicStoreCopyValue(nil,"Setup:/Network/Global/IPv4" as CFString) as? [String:Any],
           let order = setup["ServiceOrder"] as? [String] {
            for service in order {
                if Task<Never,Never>.isCancelled { return ([],nil) }
                guard let state = SCDynamicStoreCopyValue(nil,"State:/Network/Service/\(service)/IPv4" as CFString) as? [String:Any],
                      state["Router"] != nil,let name = state["InterfaceName"] as? String,
                      physical.contains(name),collected[name]?.active == true else { continue }
                automatic = name;break
            }
        }
        if automatic == nil { automatic = values.first(where:{$0.active && !$0.addresses.isEmpty})?.id }
        return (values,automatic)
    }

    private func readProcesses(_ page: StatsPage) -> [StatsProcess] {
        if page == .network { return readNetworkProcesses() }
        let columns = page == .cpu ? "pid=,pcpu=,comm=" : page == .ram ? "pid=,rss=,comm=" : "pid=,comm="
        guard let output = run("/bin/ps",["-A","-o",columns],timeout:2) else { return [] }
        let now = self.now()
        var diskSamples: [Int32:(UInt64,UInt64,TimeInterval)] = [:]
        lock.lock(); let previousDisk = processDisk; lock.unlock()
        var result: [StatsProcess] = []
        for line in output.split(separator:"\n") {
            if Task<Never,Never>.isCancelled { return [] }
            let parts = line.split(maxSplits:page == .ssd ? 1 : 2,whereSeparator:{$0.isWhitespace})
            guard parts.count == (page == .ssd ? 2 : 3),let pid = Int32(parts[0]) else { continue }
            let name = URL(fileURLWithPath:String(parts[page == .ssd ? 1 : 2])).lastPathComponent
            switch page {
            case .cpu:
                if let value = Double(parts[1]) { result.append(.init(pid:pid,name:name,amount:value,outbound:nil,scope:"% of one core")) }
            case .ram:
                if let kib = Double(parts[1]) { result.append(.init(pid:pid,name:name,amount:kib*1024,outbound:nil,scope:"Resident memory")) }
            case .ssd:
                var usage = rusage_info_current()
                let status = withUnsafeMutablePointer(to:&usage) {
                    $0.withMemoryRebound(to:rusage_info_t?.self,capacity:1) { proc_pid_rusage(pid,RUSAGE_INFO_CURRENT,$0) }
                }
                guard status == 0 else { continue }
                let read = usage.ri_diskio_bytesread, write = usage.ri_diskio_byteswritten
                diskSamples[pid] = (read,write,now)
                if let previous = previousDisk[pid],now > previous.2,read >= previous.0,write >= previous.1 {
                    result.append(.init(pid:pid,name:name,amount:Double(read-previous.0)/(now-previous.2),
                                        outbound:Double(write-previous.1)/(now-previous.2),scope:"System-wide process I/O"))
                }
            case .network: break
            }
        }
        guard !Task<Never,Never>.isCancelled else { return [] }
        if page == .ssd { lock.lock(); processDisk = Dictionary(uniqueKeysWithValues:diskSamples.prefix(4096).map { ($0.key,$0.value) }); lock.unlock() }
        return Array(result.sorted { $0.amount + ($0.outbound ?? 0) > $1.amount + ($1.outbound ?? 0) }.prefix(5))
    }

    private func readNetworkProcesses() -> [StatsProcess] {
        // nettop output is system-wide by process and cannot be attributed to a
        // selected physical interface. It is bounded and skipped if still running.
        guard let output = run("/usr/bin/nettop",["-P","-L","1","-n","-k",
            "time,interface,state,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch"],timeout:8) else { return [] }
        let now = self.now()
        lock.lock(); let previous = processNetwork; lock.unlock()
        var current: [Int32:(UInt64,UInt64,TimeInterval)] = [:]
        let results = output.split(separator:"\n").compactMap { line -> StatsProcess? in
            guard !Task<Never,Never>.isCancelled else { return nil }
            let columns = line.split(separator:",",omittingEmptySubsequences:false)
            guard columns.count >= 3, let down = UInt64(columns[1]),let up = UInt64(columns[2]) else { return nil }
            let identity = String(columns[0]); guard let pid = Int32(identity.split(separator:".").last ?? "") else { return nil }
            current[pid] = (down,up,now)
            guard let before = previous[pid],now > before.2,down >= before.0,up >= before.1 else { return nil }
            let name = identity.split(separator:".").dropLast().joined(separator:".")
            return StatsProcess(pid:pid,name:name.isEmpty ? identity : name,amount:Double(down-before.0)/(now-before.2),
                                outbound:Double(up-before.1)/(now-before.2),scope:"System-wide process traffic")
        }
        guard !Task<Never,Never>.isCancelled else { return [] }
        lock.lock(); processNetwork = Dictionary(uniqueKeysWithValues:current.prefix(4096).map { ($0.key,$0.value) }); lock.unlock()
        return Array(results.sorted { $0.amount + ($0.outbound ?? 0) > $1.amount + ($1.outbound ?? 0) }.prefix(5))
    }
    private func run(_ path: String,_ arguments: [String],timeout: TimeInterval) -> String? {
        guard !Task<Never,Never>.isCancelled else { return nil }
        let process = Process(); process.executableURL = URL(fileURLWithPath:path); process.arguments = arguments
        if path == "/usr/bin/nettop" {
            var environment = ProcessInfo.processInfo.environment
            environment["NSUnbufferedIO"] = "YES"; environment["LC_ALL"] = "en_US.UTF-8"
            process.environment = environment
        }
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let gate = DispatchSemaphore(value:0)
        process.terminationHandler = { _ in gate.signal() }
        do { try process.run() } catch { return nil }
        let output = ProcessOutput()
        let readGate = DispatchSemaphore(value:0)
        DispatchQueue.global(qos:.utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength:8192)
                if chunk.isEmpty { break }
                output.append(chunk)
            }
            readGate.signal()
        }
        let deadline = DispatchTime.now()+timeout
        while gate.wait(timeout:.now()+0.05) == .timedOut {
            if Task<Never,Never>.isCancelled || DispatchTime.now() >= deadline {
                finishOwnedStatsProcess(NativeStatsProcessResource(process:process,exit:gate,output:readGate))
                return nil
            }
        }
        guard readGate.wait(timeout:.now()+0.5) == .success else { return nil }
        guard let data = output.value else { return nil }
        return String(data:data,encoding:.utf8)
    }
    private func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0, length = MemoryLayout<Int32>.size
        return sysctlbyname(name,&value,&length,nil,0) == 0 ? Int(value) : nil
    }
    private func sysctlInteger64(_ name: String) -> UInt64? {
        var value: UInt64 = 0, length = MemoryLayout<UInt64>.size
        return sysctlbyname(name,&value,&length,nil,0) == 0 ? value : nil
    }
}

protocol StatsProcessResource {
    func terminate()
    func forceStop()
    func waitForExit(_ duration:DispatchTimeInterval) -> Bool
    func drainOutput(_ duration:DispatchTimeInterval)
}

func finishOwnedStatsProcess(_ resource:any StatsProcessResource) {
    resource.terminate()
    if !resource.waitForExit(.seconds(1)) {
        resource.forceStop()
        _ = resource.waitForExit(.seconds(1))
    }
    resource.drainOutput(.milliseconds(500))
}

private struct NativeStatsProcessResource:StatsProcessResource {
    let process:Process
    let exit:DispatchSemaphore
    let output:DispatchSemaphore
    func terminate() { if process.isRunning { process.terminate() } }
    func forceStop() { if process.isRunning { kill(process.processIdentifier,SIGKILL) } }
    func waitForExit(_ duration:DispatchTimeInterval) -> Bool { exit.wait(timeout:.now()+duration) == .success }
    func drainOutput(_ duration:DispatchTimeInterval) { _ = output.wait(timeout:.now()+duration) }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var overflow = false
    func append(_ data:Data) {
        lock.lock();defer { lock.unlock() }
        guard !overflow else { return }
        if storage.count + data.count > 1_000_000 { storage.removeAll(keepingCapacity:false);overflow = true }
        else { storage.append(data) }
    }
    var value: Data? {
        lock.lock();defer { lock.unlock() }
        return overflow ? nil : storage
    }
}

final class StatsCancellationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cleanup: (@Sendable () -> Void)?
    func install(_ cleanup: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        let shouldStart = !cancelled
        if shouldStart { self.cleanup = cleanup }
        lock.unlock()
        if !shouldStart { cleanup() }
        return shouldStart
    }
    func cancel() {
        lock.lock(); cancelled = true; let cleanup = self.cleanup; self.cleanup = nil; lock.unlock()
        cleanup?()
    }
}

protocol StatsProbeConnection: Sendable {
    func setHandler(_ handler:(@Sendable (TimeInterval?) -> Void)?)
    func start()
    func cancel()
}

private final class NativeStatsProbeConnection: StatsProbeConnection, @unchecked Sendable {
    private let connection:NWConnection
    init(target:String) { connection = NWConnection(host:NWEndpoint.Host(target),port:443,using:.tcp) }
    func setHandler(_ handler:(@Sendable (TimeInterval?) -> Void)?) {
        guard let handler else { connection.stateUpdateHandler = nil; return }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: handler(ProcessInfo.processInfo.systemUptime)
            case .failed, .cancelled: handler(nil)
            default: break
            }
        }
    }
    func start() { connection.start(queue:DispatchQueue.global(qos:.utility)) }
    func cancel() { connection.cancel() }
}

final class ProbeGate: @unchecked Sendable {
    let connection: any StatsProbeConnection
    let continuation: CheckedContinuation<Double?,Never>
    let started: TimeInterval
    private let lock = NSLock()
    private var finished = false
    private var timeout: DispatchWorkItem?
    init(connection:any StatsProbeConnection,continuation:CheckedContinuation<Double?,Never>,started:TimeInterval) {
        self.connection = connection; self.continuation = continuation; self.started = started
    }
    func start() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        connection.setHandler { [weak self] ended in self?.finish(ended) }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        self.timeout = timeout
        connection.start()
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+3,execute:timeout)
        lock.unlock()
    }
    func finish(_ ended: TimeInterval?) {
        lock.lock(); let shouldFinish = !finished; finished = true; let timeout = self.timeout; self.timeout = nil; lock.unlock()
        guard shouldFinish else { return }
        timeout?.cancel()
        connection.setHandler(nil)
        connection.cancel()
        continuation.resume(returning:ended.map { max(0,($0-started)*1000) })
    }
}
