import AppKit

@MainActor enum StatsFormat {
    static func percent(_ value: Double?) -> String {
        guard let value,value.isFinite,value >= 0,value <= 1 else { return "Unavailable" }
        return String(format:"%.0f%%",value*100)
    }
    static func bytes(_ value: Double?) -> String {
        guard let value,value.isFinite,value >= 0 else { return "Unavailable" }
        let units = ["B","KB","MB","GB","TB"]
        var amount = value, index = 0
        while amount >= 1000 && index < units.count-1 { amount /= 1000; index += 1 }
        return String(format:amount < 10 && index > 0 ? "%.1f %@" : "%.0f %@",amount,units[index])
    }
    static func bytes(_ value: UInt64?) -> String { bytes(value.map { Double($0) }) }
    static func rate(_ value: Double?) -> String { guard let value,value.isFinite,value >= 0 else { return "Unavailable" }; return "\(bytes(value))/s" }
    static func decimal(_ value: Double?,unit:String = "") -> String {
        guard let value,value.isFinite else { return "Unavailable" }
        return String(format:"%.1f",value) + unit
    }
}

/// Scene geometry is retained by WorkspaceView; changing samples refreshes only
/// the content canvas. Charts have a fixed five-minute, 301-point input bound.
@MainActor enum StatsPanel {
    static func accessibilitySummary(_ page:StatsPage,_ value:SystemStatsSnapshot) -> String {
        if !value.enabledPages.contains(page) { return "\(page.title) monitoring is disabled" }
        if value.collectingPages.contains(page) { return "\(page.title) monitoring is collecting" }
        let metric: String, history: StatsHistory
        switch page {
        case .cpu:
            metric = "\(value.cpu.name ?? "Processor"), CPU total \(StatsFormat.percent(value.cpu.total)), system \(StatsFormat.percent(value.cpu.system)), user \(StatsFormat.percent(value.cpu.user)), idle \(StatsFormat.percent(value.cpu.idle))"
            history = value.cpuHistory
        case .ram:
            metric = "RAM used \(StatsFormat.bytes(value.ram.used)), total \(StatsFormat.bytes(value.ram.total)), app \(StatsFormat.bytes(value.ram.app)), wired \(StatsFormat.bytes(value.ram.wired)), compressed \(StatsFormat.bytes(value.ram.compressed)), free \(StatsFormat.bytes(value.ram.free)), pressure \(value.ram.pressure ?? "Unavailable")"
            history = value.ramHistory
        case .ssd:
            metric = "\(value.disk.volumeName ?? value.disk.name), \(value.disk.filesystem ?? "Filesystem unavailable"), SSD used \(StatsFormat.bytes(value.disk.used)), \(StatsFormat.percent(value.disk.percent)), available now \(StatsFormat.bytes(value.disk.available)), total \(StatsFormat.bytes(value.disk.total)), read \(StatsFormat.rate(value.diskReadRate)), write \(StatsFormat.rate(value.diskWriteRate))"
            history = value.diskHistory
        case .network:
            metric = "\(value.interfaces.first { $0.id == value.selectedInterface }?.name ?? "No interface"), download \(StatsFormat.rate(value.networkDownRate)), upload \(StatsFormat.rate(value.networkUpRate)), \(value.connectivity.state.rawValue)"
            history = value.networkHistory
        }
        let gaps = history.points.filter { $0.value == nil }.count
        let processes = (value.processes[page] ?? []).prefix(5).map { "\($0.name) \($0.scope)" }.joined(separator:", ")
        let failures = page == .network ? value.connectivity.history.points.filter { $0.reason == "Target failed" }.count : 0
        let unmonitored = page == .network ? value.connectivity.history.points.filter { $0.reason == "Not monitored" }.count : 0
        return "\(metric). Five-minute history: \(history.points.count) samples, \(gaps) gaps. Target failures: \(failures). Unmonitored intervals: \(unmonitored). Top processes: \(processes.isEmpty ? "Unavailable" : processes)."
    }
    static func append(to scene: inout WorkspaceScene,page:StatsPage,snapshot:SystemStatsSnapshot,
                       visibleInMenuBar:Bool,style:StatsMenuStyle,
                       x:CGFloat,y:CGFloat,width:CGFloat,retainedCharts:Bool = false) -> CGFloat {
        let palette = scene.palette
        scene.text("SYSTEM STATS",x:x,y:y+11,size:9,weight:650,color:palette.secondaryText,tracking:1.4)
        scene.text(page.title,x:x,y:y+47,size:30,weight:700)
        scene.text("Mac-wide readings · current app session",x:x,y:y+68,size:11,color:palette.secondaryText)
        let enabled = snapshot.enabledPages.contains(page)
        let monitoring = CGRect(x:x+width-180,y:y-8,width:180,height:31)
        let monitoringAction = WorkspaceAction.toggleStatsMonitoring(page)
        scene.interactive(monitoringAction,in:monitoring) { context,feedback in
            if feedback.hovered { VPNDrawing.rounded(monitoring,radius:7,fill:palette[.hover,light:0xf1f4ed],in:context) }
            let check = CGRect(x:monitoring.minX+5,y:monitoring.minY+7,width:16,height:16)
            VPNDrawing.rounded(check,radius:5,fill:enabled ? palette[.primaryButton,light:0x25674d] : palette.surface,
                border:enabled ? palette[.primaryButton,light:0x25674d] : palette[.controlBorder,light:0x808080],in:context)
            if enabled { VPNIcon.check.draw(in:check.insetBy(dx:2,dy:2),color:palette[.onAccent,light:0xffffff],context:context) }
            VPNDrawing.text("Enable monitoring",in:context,at:CGPoint(x:monitoring.minX+29,y:monitoring.minY+20),size:11,weight:550,color:palette.text)
        }
        scene.hits.append(.init(rect:monitoring,title:"Enable \(page.title) monitoring",action:monitoringAction,role:.checkbox,checked:enabled))
        let toggle = CGRect(x:x+width-180,y:y+25,width:180,height:31)
        let action = WorkspaceAction.toggleStatsMenu(page)
        scene.interactive(action,in:toggle) { context,feedback in
            context.saveGState();defer { context.restoreGState() }
            if feedback.pressed { context.translateBy(x:0,y:1) }
            if feedback.hovered && enabled {
                VPNDrawing.rounded(toggle,radius:7,fill:palette[.hover,light:0xf1f4ed],in:context)
            }
            let check = CGRect(x:toggle.minX+5,y:toggle.minY+7,width:16,height:16)
            VPNDrawing.rounded(check,radius:5,
                fill:visibleInMenuBar && enabled ? palette[.primaryButton,light:0x25674d] : palette.surface,
                border:visibleInMenuBar && enabled ? palette[.primaryButton,light:0x25674d] : palette[.controlBorder,light:0x808080],in:context)
            if visibleInMenuBar {
                VPNIcon.check.draw(in:check.insetBy(dx:2,dy:2),color:enabled ? palette[.onAccent,light:0xffffff] : palette.secondaryText,context:context)
            }
            VPNDrawing.text("Show in menu bar",in:context,at:CGPoint(x:toggle.minX+29,y:toggle.minY+20),
                size:11,weight:550,color:enabled ? palette.text : palette.secondaryText)
        }
        scene.hits.append(.init(rect:toggle,title:"Show \(page.title) in menu bar",action:action,
            enabled:enabled,role:.checkbox,checked:visibleInMenuBar))
        scene.text("Menu bar style:",x:x,y:y+103,size:11,color:palette.secondaryText)
        for (index,choice) in StatsMenuStyle.allCases.enumerated() {
            let rect = CGRect(x:x+95+CGFloat(index)*67,y:y+83,width:64,height:28)
            let action = WorkspaceAction.statsMenuStyle(page,choice)
            scene.interactive(action,in:rect) { context,feedback in
                VPNDrawing.rounded(rect,radius:6,fill:choice == style && enabled ? palette[.primaryButton,light:0x25674d] : (feedback.hovered && enabled ? palette[.hover,light:0xf1f4ed] : palette.surface),border:palette.border,in:context)
                VPNDrawing.text(choice == .label ? "Label" : "Icon",in:context,at:CGPoint(x:rect.minX+13,y:rect.minY+18),size:11,weight:550,color:!enabled ? palette.secondaryText : choice == style ? palette[.onAccent,light:0xffffff] : palette.text)
            }
            scene.hits.append(.init(rect:rect,title:"\(page.title) menu bar style \(choice == .label ? "Label" : "Icon")",action:action,enabled:enabled,role:.radio,checked:choice == style))
        }
        var cursor = y+122
        if !enabled {
            scene.text("\(page.title) monitoring is disabled",x:x,y:cursor+20,size:14,weight:650)
            scene.text("Enable monitoring to use display settings and see readings.",x:x,y:cursor+43,size:11,color:palette.secondaryText)
            return cursor+65
        }
        if snapshot.collectingPages.contains(page) {
            scene.text("Collecting \(page.title) readings…",x:x,y:cursor+20,size:14,weight:650)
            return cursor+50
        }
        switch page {
        case .cpu:
            let cpu = snapshot.cpu
            let counts = cpu.cores.filter { $0.kind == .efficiency }.count
            let performance = cpu.cores.filter { $0.kind == .performance }.count
            let topology = cpu.cores.isEmpty || cpu.cores.contains { $0.kind == .unknown } ? "Core topology unavailable" : "\(counts) efficiency · \(performance) performance"
            cursor = summary(&scene,title:cpu.name ?? "Processor",subtitle:topology,center:StatsFormat.percent(cpu.total),
                labels:[("System",StatsFormat.percent(cpu.system)),("User",StatsFormat.percent(cpu.user)),("Idle",StatsFormat.percent(cpu.idle))],
                fractions:cpu.total.flatMap { total in guard let system = cpu.system, let user = cpu.user, total.isFinite, abs(total-system-user) <= 0.001 else { return nil }; return StatsSummarySurface.composition([system,user,cpu.idle],total:1) },colorIndices:[1,0,3],x:x,y:cursor,width:width,retained:retainedCharts)
            cursor = card(&scene,title:"Processor details",rows:[
                ("Efficiency cores",StatsFormat.percent(cpu.efficiency)),("Performance cores",StatsFormat.percent(cpu.performance)),
                ("Frequency",StatsFormat.decimal(cpu.frequencyMHz,unit:" MHz")),
                ("Uptime",cpu.uptime.map { "\(Int($0/3600))h \(Int($0/60)%60)m" } ?? "Unavailable"),
                ("Load 1 / 5 / 15",cpu.loads.count == 3 ? cpu.loads.map { String(format:"%.2f",$0) }.joined(separator:" / ") : "Unavailable")],x:x,y:cursor,width:width)
            if !snapshot.cpu.cores.isEmpty {
                scene.text("CORES · E / P",x:x,y:cursor+23,size:10,weight:650,color:palette.secondaryText,tracking:0.9)
                cursor += 34
                let barWidth = max(12,(width-8*CGFloat(snapshot.cpu.cores.count-1))/CGFloat(snapshot.cpu.cores.count))
                for (index,core) in snapshot.cpu.cores.enumerated() {
                    let bx = x+CGFloat(index)*(barWidth+8), rect = CGRect(x:bx,y:cursor,width:barWidth,height:50)
                    scene.box(rect,radius:5,fill:palette.raised)
                    if let usage = core.usage {
                        let height = 50*min(1,max(0,usage))
                        scene.box(CGRect(x:bx,y:cursor+50-height,width:barWidth,height:height),radius:5,fill:palette.accent)
                    }
                    scene.text("\(core.kind.rawValue)\(index+1)",x:bx,y:cursor+66,size:9,color:palette.secondaryText)
                }
                cursor += 80
            }
            cursor = chart(&scene,title:"CPU usage · 5 minutes",history:snapshot.cpuHistory,percent:true,x:x,y:cursor,width:width,retained:retainedCharts)
        case .ram:
            let ram = snapshot.ram
            cursor = summary(&scene,title:"Used \(StatsFormat.bytes(ram.used))",subtitle:"Total \(StatsFormat.bytes(ram.total))",center:StatsFormat.percent(ram.percent),
                labels:[("App",StatsFormat.bytes(ram.app)),("Wired",StatsFormat.bytes(ram.wired)),("Compressed",StatsFormat.bytes(ram.compressed)),("Free",StatsFormat.bytes(ram.free))],
                fractions:StatsSummarySurface.composition([ram.app.map { Double($0) },ram.wired.map { Double($0) },ram.compressed.map { Double($0) },ram.free.map { Double($0) }],total:ram.total.map { Double($0) }),colorIndices:[0,1,2,3],x:x,y:cursor,width:width,retained:retainedCharts)
            cursor = card(&scene,title:"Memory details",rows:[("Pressure",ram.pressure ?? "Unavailable"),
                ("Swap used / total","\(StatsFormat.bytes(ram.swapUsed)) / \(StatsFormat.bytes(ram.swapTotal))")],x:x,y:cursor,width:width)
            cursor = chart(&scene,title:"Memory used · 5 minutes",history:snapshot.ramHistory,percent:true,x:x,y:cursor,width:width,retained:retainedCharts)
        case .ssd:
            let disk = snapshot.disk
            cursor = summary(&scene,title:disk.volumeName ?? disk.name,subtitle:[disk.filesystem,StatsFormat.bytes(disk.total)].compactMap { $0 }.joined(separator:" · "),center:StatsFormat.percent(disk.percent),
                labels:[("Used",StatsFormat.bytes(disk.used)),("Available now",StatsFormat.bytes(disk.available))],
                fractions:StatsSummarySurface.composition([disk.used.map { Double($0) },disk.available.map { Double($0) }],total:disk.total.map { Double($0) }),colorIndices:[0,3],x:x,y:cursor,width:width,retained:retainedCharts)
            cursor = card(&scene,title:"Disk activity",rows:[("Reclaimable estimate",StatsFormat.bytes(disk.reclaimable)),
                ("Read ↓",StatsFormat.rate(snapshot.diskReadRate)),("Write ↑",StatsFormat.rate(snapshot.diskWriteRate))],x:x,y:cursor,width:width)
            cursor = chart(&scene,title:"SSD read ↓ / write ↑ · 5 minutes",history:snapshot.diskHistory,percent:false,x:x,y:cursor,width:width,retained:retainedCharts)
        case .network:
            let selected = snapshot.interfaces.first { $0.id == snapshot.selectedInterface }
            let choice = snapshot.automaticInterface ? "Auto: \(selected?.name ?? "Unavailable")" : "\(selected?.name ?? "Unavailable") (manual)"
            scene.button("Interface: \(choice)",x:x,y:cursor,action:.selectStatsInterface,style:.secondary,fontSize:10)
            cursor += 55
            cursor = networkSummary(&scene,down:snapshot.networkDownRate,up:snapshot.networkUpRate,x:x,y:cursor,width:width)
            cursor = card(&scene,title:"Physical interface",rows:[
                ("Selected",selected?.name ?? "Unavailable"),("Status",selected.map { $0.active ? "Active" : "Inactive" } ?? "Unavailable"),
                ("Hardware address",selected?.mac ?? "Unavailable"),("Local addresses",selected?.addresses.joined(separator:", ") ?? "Unavailable"),
                ("Observed received",StatsFormat.bytes(snapshot.networkDownTotal)),("Observed sent",StatsFormat.bytes(snapshot.networkUpTotal))],x:x,y:cursor,width:width)
            cursor = chart(&scene,title:"Download ↓ / upload ↑ · 5 minutes",history:snapshot.networkHistory,percent:false,x:x,y:cursor,width:width,retained:retainedCharts)
            let v4 = snapshot.publicIPv4, v6 = snapshot.publicIPv6
            cursor = card(&scene,title:"Public IP · current routed egress",rows:[
                ("IPv4",publicText(v4)),("IPv6",publicText(v6)),
                ("Last updated",[v4.updated,v6.updated].compactMap{$0}.max().map { DateFormatter.localizedString(from:$0,dateStyle:.none,timeStyle:.medium) } ?? "Never")],x:x,y:cursor,width:width)
            scene.button("Refresh public IP",x:x,y:cursor,action:.refreshPublicAddress,style:.secondary,fontSize:10)
            cursor += 53
            let probe = snapshot.connectivity
            cursor = card(&scene,title:"Connectivity · target \(probe.target)",rows:[
                ("Status",probe.state.rawValue),("Latency",StatsFormat.decimal(probe.latencyMS,unit:" ms")),
                ("Jitter",StatsFormat.decimal(probe.jitterMS,unit:" ms"))],x:x,y:cursor,width:width)
            scene.button("Change probe target",x:x,y:cursor,action:.editProbeTarget,style:.secondary,fontSize:10)
            cursor += 53
            cursor = chart(&scene,title:"Target latency · 5 minutes",history:probe.history,percent:false,x:x,y:cursor,width:width,retained:retainedCharts)
            let failed = probe.history.points.filter { $0.reason == "Target failed" }.count
            let unmonitored = probe.history.points.filter { $0.reason == "Not monitored" }.count
            scene.text("Orange marks: failed checks \(failed) · Unmonitored gaps \(unmonitored)",x:x,y:cursor-4,size:10,color:palette.secondaryText)
            cursor += 18
        }
        let processTitle = page == .cpu ? "Top CPU processes · % of one core" : page == .ram ? "Top memory processes" : page == .ssd ? "Top disk processes · system-wide I/O" : "Top network processes · system-wide traffic"
        scene.text(processTitle,x:x,y:cursor+20,size:12,weight:650)
        cursor += 32
        let processes = snapshot.processes[page] ?? []
        if processes.isEmpty {
            scene.text("Unavailable",x:x,y:cursor+18,size:11,color:palette.secondaryText)
            cursor += 34
        } else {
            for process in processes.prefix(5) {
                let rowY = cursor
                scene.box(CGRect(x:x,y:cursor,width:width,height:37),radius:7,fill:palette.surface,border:palette.border)
                scene.custom { VPNDrawing.truncatedText(process.name,width:max(100,width-260),in:$0,at:CGPoint(x:x+12,y:rowY+23),size:10,weight:500,color:palette.text) }
                let amount = page == .cpu ? String(format:"%.1f%%",process.amount) : page == .ram ? StatsFormat.bytes(process.amount) : "↓ \(StatsFormat.rate(process.amount))  ↑ \(StatsFormat.rate(process.outbound))"
                let textWidth = VPNDrawing.textWidth(amount,size:10,weight:500)
                scene.text(amount,x:x+width-12-textWidth,y:cursor+23,size:10,weight:500,color:palette.secondaryText)
                cursor += 44
            }
        }
        scene.text(page == .ssd || page == .network ? "Process I/O is system-wide and may include other devices or interfaces." : "Only processes accessible to this user are shown.",
                   x:x,y:cursor+7,size:9,color:palette.secondaryText)
        return cursor+28
    }

    private static func summary(_ scene:inout WorkspaceScene,title:String,subtitle:String,center:String,labels:[(String,String)],fractions:[Double]?,colorIndices:[Int],x:CGFloat,y:CGFloat,width:CGFloat,retained:Bool) -> CGFloat {
        let palette = scene.palette, rect = CGRect(x:x,y:y,width:width,height:150)
        scene.box(rect,radius:12,fill:palette.surface,border:palette.border)
        let surface = StatsSummarySurface(rect:rect,fractions:fractions,colors:colorIndices.map { palette.statsColors[$0] })
        scene.statsSummaries.append(surface)
        if !retained { scene.custom { surface.draw(in:$0,palette:palette) } }
        let centerSize:CGFloat = center == "Unavailable" ? 9 : 18
        let baseline = VPNDrawing.centeredTextBaseline(center,center:CGPoint(x:x+60,y:y+68),size:centerSize,weight:700)
        scene.text(center,x:baseline.x,y:baseline.y,size:centerSize,weight:700)
        let left = x+124, available = width-140
        scene.custom { VPNDrawing.truncatedText(title,width:available*0.5,in:$0,at:CGPoint(x:left,y:y+34),size:13,weight:650,color:palette.text) }
        let subtitleWidth = min(available*0.48,VPNDrawing.textWidth(subtitle,size:10,weight:500))
        scene.custom { VPNDrawing.truncatedText(subtitle,width:subtitleWidth,in:$0,at:CGPoint(x:x+width-16-subtitleWidth,y:y+34),size:10,weight:500,color:palette.secondaryText) }
        let columns = labels.count == 3 ? 3 : min(labels.count,2)
        for (index,label) in labels.enumerated() {
            let lx = left+CGFloat(index%columns)*available/CGFloat(columns), ly = y+91+CGFloat(index/columns)*24
            scene.box(CGRect(x:lx,y:ly-9,width:9,height:9),radius:2,fill:palette.statsColors[colorIndices[index]])
            let text = "\(label.0): \(label.1)"
            scene.custom { VPNDrawing.truncatedText(text,width:available/CGFloat(columns)-16,in:$0,at:CGPoint(x:lx+14,y:ly),size:10,weight:550,color:palette.text) }
        }
        if fractions == nil { scene.text("Composition unavailable",x:left,y:y+138,size:9,color:palette.secondaryText) }
        return rect.maxY+15
    }
    private static func networkSummary(_ scene:inout WorkspaceScene,down:Double?,up:Double?,x:CGFloat,y:CGFloat,width:CGFloat) -> CGFloat {
        let palette = scene.palette, rect = CGRect(x:x,y:y,width:width,height:120)
        scene.box(rect,radius:12,fill:palette.surface,border:palette.border)
        for (index,item) in [("Download",down),("Upload",up)].enumerated() {
            let center = x+width*(CGFloat(index)*0.5+0.25)
            let formatted = StatsFormat.rate(item.1)
            let parts = formatted.split(separator:" ",maxSplits:1).map(String.init)
            let number = parts.first ?? "Unavailable", unit = parts.count == 2 ? parts[1] : ""
            let numberSize:CGFloat = unit.isEmpty ? 12 : 22
            let verticalOffset:CGFloat = unit.isEmpty ? -5 : 0
            let numberBounds = VPNDrawing.textBounds(number,size:numberSize,weight:700)
            let unitBounds = VPNDrawing.textBounds(unit,size:11,weight:550)
            let gap:CGFloat = unit.isEmpty ? 0 : 4
            let valueWidth = numberBounds.width+gap+unitBounds.width
            let valueLeft = center-valueWidth/2
            scene.text(number,x:valueLeft-numberBounds.minX,y:y+60+verticalOffset,size:numberSize,weight:700)
            if !unit.isEmpty {
                scene.text(unit,x:valueLeft+numberBounds.width+gap-unitBounds.minX,y:y+60,size:11,weight:550,color:palette.secondaryText)
            }
            let labelBounds = VPNDrawing.textBounds(item.0,size:11,weight:550)
            let labelLeft = center-(9+5+labelBounds.width)/2
            scene.box(CGRect(x:labelLeft,y:y+70+verticalOffset,width:9,height:9),radius:3,fill:palette.statsColors[index])
            scene.text(item.0,x:labelLeft+14-labelBounds.minX,y:y+79+verticalOffset,size:11,weight:550,color:palette.text)
        }
        return rect.maxY+15
    }

    private static func publicText(_ value:StatsPublicAddress) -> String {
        "\(value.address ?? "Unavailable") · \(value.state.rawValue.capitalized)"
    }
    private static func card(_ scene: inout WorkspaceScene,title:String,rows:[(String,String)],x:CGFloat,y:CGFloat,width:CGFloat) -> CGFloat {
        let palette = scene.palette, rowHeight:CGFloat = 27
        let height = 45+CGFloat(rows.count)*rowHeight+12
        scene.box(CGRect(x:x,y:y,width:width,height:height),radius:12,fill:palette.surface,border:palette.border)
        scene.custom { VPNDrawing.truncatedText(title,width:width-32,in:$0,at:CGPoint(x:x+16,y:y+28),size:14,weight:650,color:palette.text) }
        for (index,row) in rows.enumerated() {
            let line = y+57+CGFloat(index)*rowHeight
            scene.text(row.0,x:x+16,y:line,size:10,color:palette.secondaryText)
            let available = width*0.58
            scene.custom { VPNDrawing.truncatedText(row.1,width:available,in:$0,at:CGPoint(x:x+width-16-min(available,VPNDrawing.textWidth(row.1,size:10,weight:550)),y:line),size:10,weight:550,color:palette.text) }
        }
        return y+height+15
    }
    private static func chart(_ scene: inout WorkspaceScene,title:String,history:StatsHistory,percent:Bool,x:CGFloat,y:CGFloat,width:CGFloat,retained:Bool) -> CGFloat {
        let palette = scene.palette
        let rect = CGRect(x:x,y:y+32,width:width,height:112)
        scene.text(title,x:x,y:y+19,size:12,weight:650)
        scene.box(rect,radius:9,fill:palette.surface,border:palette.border)
        scene.statsCharts.append(.init(rect:rect,history:history,percent:percent))
        if retained { return rect.maxY+18 }
        let points = history.points
        scene.custom { context in
            guard let last = points.last else { return }
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to:rect.insetBy(dx:2,dy:2))
            let maximum = percent ? 1 : max(1,points.compactMap(\.value).max() ?? 0,points.compactMap(\.second).max() ?? 0)
            for (index,color) in [palette.accent,palette.warning].enumerated() {
                var path = CGMutablePath(),drawing = false
                for point in points {
                    let value = index == 0 ? point.value : point.second
                    guard let value else { drawing = false; continue }
                    let px = rect.maxX-CGFloat((last.time-point.time)/300)*rect.width
                    let py = rect.maxY-4-CGFloat(min(1,max(0,value/maximum)))*(rect.height-8)
                    if drawing { path.addLine(to:CGPoint(x:px,y:py)) } else { path.move(to:CGPoint(x:px,y:py)); drawing = true }
                }
                context.addPath(path); context.setStrokeColor(VPNDrawing.color(color)); context.setLineWidth(2); context.strokePath()
            }
            let failures = CGMutablePath()
            for point in points where point.reason == "Target failed" {
                let px = rect.maxX-CGFloat((last.time-point.time)/300)*rect.width
                failures.move(to:CGPoint(x:px,y:rect.maxY-15));failures.addLine(to:CGPoint(x:px,y:rect.maxY-4))
            }
            context.addPath(failures);context.setStrokeColor(VPNDrawing.color(palette.warning));context.setLineWidth(3);context.strokePath()
        }
        return rect.maxY+18
    }
}
