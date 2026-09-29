import AppKit
import XCTest
import Darwin

/// CPU-time comparison of the old full-scene drawing workload and retained
/// artwork, including software compositing of every frame. No live app/window.
@MainActor final class PerformanceTests:XCTestCase {
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
