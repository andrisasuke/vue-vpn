import AppKit
import XCTest
import Darwin

/// CPU-time comparison of the old full-scene drawing workload and retained
/// artwork, including software compositing of every frame. No live app/window.
@MainActor final class PerformanceTests:XCTestCase {
    func testStatsAggregateSnapshotAndMenuCPUTimeIsReportedSeparatelyFromDetail() throws {
        let samples = 300
        var stats = SystemStatsSnapshot()
        let start = Double(clock())/Double(CLOCKS_PER_SEC)
        for second in 0..<samples {
            stats.cpu.total = Double(second%100)/100
            stats.ram.total = 16_000_000_000
            stats.ram.app = UInt64(second%8)*1_000_000_000
            stats.ram.wired = 2_000_000_000
            stats.ram.compressed = 1_000_000_000
            stats.disk.total = 500_000_000_000
            stats.disk.available = 200_000_000_000
            stats.networkDownRate = Double(second)*1000
            stats.networkUpRate = Double(second)*500
            stats.cpuHistory.add(.init(time:Double(second),value:stats.cpu.total))
            _ = StatsMenuPresentation.metrics(stats)
        }
        let aggregateCPU = Double(clock())/Double(CLOCKS_PER_SEC)-start
        let state = WorkspacePresentation(snapshot:Snapshot(profiles:[],sessions:[],helper:HelperStatus("disabled","Disabled"),logs:[]),
            selectedID:"",screen:.cpu,palette:.light,statsNavigation:true)
        stats.processes[.cpu] = (0..<5).map { .init(pid:Int32($0),name:"Synthetic process \($0)",amount:Double($0),outbound:nil,scope:"% of one core") }
        let detailStart = Double(clock())/Double(CLOCKS_PER_SEC)
        let context = try XCTUnwrap(CGContext(data:nil,width:766,height:1000,bitsPerComponent:8,bytesPerRow:766*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x:0,y:1000);context.scaleBy(x:1,y:-1)
        for _ in 0..<30 {
            let scene = WorkspaceContent.make(state,width:766,clock:0,connection:.init(),stats:stats)
            scene.draw(in:context)
        }
        let detailCPU = Double(clock())/Double(CLOCKS_PER_SEC)-detailStart
        let report:[String:Any] = ["aggregateSamples":samples,"aggregateSnapshotAndMenuCPUSeconds":aggregateCPU,
            "visibleDetailFrames":30,"visibleDetailCPUSeconds":detailCPU,
            "historyPoints":stats.cpuHistory.points.count,"historyLimit":301,"imageCacheBytes":DrawingResources.images.totalCost,
            "imageCacheLimitBytes":DrawingResources.images.limit,"interfaceStateLimit":16,"processBaselineLimit":4096,
            "scope":"Hostless synthetic snapshot/history and menu formatting versus visible CPU page with processes. No native reads, subprocesses, live app, WindowServer, battery or Energy Impact measurement."]
        let output = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/migration/energy")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("stats-benchmark.json"))
        XCTAssertEqual(stats.cpuHistory.points.count,300)
        XCTAssertGreaterThanOrEqual(aggregateCPU,0)
        XCTAssertGreaterThanOrEqual(detailCPU,0)
    }

    func testRetainedRenderingReducesCPUWorkByAtLeastEightyPercent() throws {
        struct Fixture:Decodable { let snapshot:Snapshot }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("References/overview-connected.json")))
        let state = WorkspacePresentation(snapshot:fixture.snapshot,selectedID:fixture.snapshot.profiles[0].id)
        let size = CGSize(width:766,height:629),scale:CGFloat = 2,frames = 90
        var connection = ConnectionPresentation(status:.connected,address:"10.8.0.2",duration:"00:01:40",bytesIn:1_500_000,bytesOut:10_000_000)
        let ctx = try XCTUnwrap(CGContext(data:nil,width:Int(size.width*scale),height:Int(size.height*scale),bitsPerComponent:8,
            bytesPerRow:Int(size.width*scale)*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x:scale,y:scale);ctx.translateBy(x:0,y:size.height);ctx.scaleBy(x:1,y:-1)
        func seconds() -> Double { Double(clock())/Double(CLOCKS_PER_SEC) }
        func caches(_ enabled:Bool) {
            DrawingResources.fonts.isEnabled = enabled;DrawingResources.paths.isEnabled = enabled;DrawingResources.images.isEnabled = enabled
        }
        defer { caches(true) }
        // Original rendering had neither retained artwork nor resource caches.
        caches(false)
        let oldStart = seconds()
        for frame in 0..<frames {
            connection.phase = Double(frame)/30
            connection.duration = "00:01:\(40+frame/30)"
            connection.bytesIn = UInt64(1_500_000+frame/30*1000)
            let scene = WorkspaceContent.make(state,width:size.width,clock:1,connection:connection)
            ctx.setFillColor(VPNDrawing.color(state.palette.background));ctx.fill(CGRect(origin:.zero,size:size))
            scene.draw(in:ctx)
        }
        let oldCPU = seconds()-oldStart
        DrawingResources.fonts.removeAll();DrawingResources.paths.removeAll();DrawingResources.images.removeAll()
        caches(true)
        let retainedStart = seconds()
        let scene = WorkspaceContent.make(state,width:size.width,clock:1,connection:connection,retainedConnection:true)
        let panel = try XCTUnwrap(scene.connectionPanel)
        let page = try XCTUnwrap(ConnectionLayers.raster(size:size,scale:scale) { context in
            context.setFillColor(VPNDrawing.color(state.palette.background));context.fill(CGRect(origin:.zero,size:size));scene.draw(in:context)
        })
        let layers = ConnectionLayers()
        for frame in 0..<frames {
            connection.phase = Double(frame)/30
            connection.duration = "00:01:\(40+frame/30)"
            connection.bytesIn = UInt64(1_500_000+frame/30*1000)
            layers.update(connection,size:panel.size,palette:state.palette,scale:scale,epoch:1)
            layers.setPhase(connection.phase)
            ctx.saveGState();ctx.translateBy(x:0,y:size.height);ctx.scaleBy(x:1,y:-1)
            ctx.draw(page,in:CGRect(origin:.zero,size:size));ctx.restoreGState()
            ctx.saveGState();ctx.translateBy(x:panel.minX,y:panel.minY);layers.root.render(in:ctx);ctx.restoreGState()
        }
        let retainedCPU = seconds()-retainedStart,reduction = 1-retainedCPU/oldCPU
        let report:[String:Any] = ["frames":frames,"scale":scale,"width":size.width,"height":size.height,
            "legacyCPUSeconds":oldCPU,"retainedCPUSeconds":retainedCPU,"reductionPercent":100*reduction,
            "staticBuilds":layers.staticBuilds,"metricBuilds":layers.metricBuilds,
            "scope":"Hostless process CPU time; includes retained setup and software compositing. Not live GPU, WindowServer, energy or battery measurement."]
        let output = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/migration/energy")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("benchmark.json"))
        XCTAssertEqual(layers.staticBuilds,1);XCTAssertEqual(layers.metricBuilds,3)
        XCTAssertGreaterThanOrEqual(reduction,0.8,"Hostless rendering CPU reduction was \(reduction*100)%")
    }
}
