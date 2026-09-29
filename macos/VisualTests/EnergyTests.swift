import AppKit
import XCTest

@MainActor final class EnergyTests:XCTestCase {
    private struct NoBackend:BackendExecuting {
        func execute(_ command:BackendCommand) async -> BackendResult { XCTFail("Rendering must not call backend");return BackendResult() }
    }
    private func fixture() throws -> Snapshot {
        struct Fixture:Decodable { let snapshot:Snapshot }
        let path = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("References/overview-connected.json")
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:path)).snapshot
    }
    private var output:URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/migration/energy")
    }
    private func context(_ size:CGSize,scale:CGFloat = 2) throws -> CGContext {
        let ctx = try XCTUnwrap(CGContext(data:nil,width:Int(ceil(size.width*scale)),height:Int(ceil(size.height*scale)),bitsPerComponent:8,
            bytesPerRow:Int(ceil(size.width*scale))*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x:scale,y:scale);return ctx
    }
    private func save(_ image:CGImage,_ name:String) throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(name+".png"))
    }
    private func similarity(_ a:CGContext,_ b:CGContext) -> Double {
        let lhs = a.data!.assumingMemoryBound(to:UInt8.self),rhs = b.data!.assumingMemoryBound(to:UInt8.self)
        var significant = 0
        for i in stride(from:0,to:a.bytesPerRow*a.height,by:4) {
            if abs(Int(lhs[i])-Int(rhs[i])) > 2 || abs(Int(lhs[i+1])-Int(rhs[i+1])) > 2 ||
               abs(Int(lhs[i+2])-Int(rhs[i+2])) > 2 || abs(Int(lhs[i+3])-Int(rhs[i+3])) > 2 { significant += 1 }
        }
        return 1-Double(significant)/Double(a.width*a.height)
    }

    func testVisibilityPolicyStopsInvisibleWorkButKeepsLowPowerAnimation() {
        let active = RenderingEnvironment(windowVisible:true,occluded:false,panelVisible:true,overview:true,activeConnection:true)
        XCTAssertTrue(active.rendersWorkspace);XCTAssertTrue(active.animates)
        for key in [\RenderingEnvironment.occluded,\.minimized,\.applicationHidden,\.displayAsleep,\.coveredByModal] {
            var state = active;state[keyPath:key] = true
            XCTAssertFalse(state.rendersWorkspace);XCTAssertFalse(state.animates)
        }
        var state = active;state.windowVisible = false;XCTAssertFalse(state.animates)
        state = active;state.panelVisible = false;XCTAssertTrue(state.rendersWorkspace);XCTAssertFalse(state.animates)
        state = active;state.overview = false;XCTAssertFalse(state.animates)
        state = active;state.reduceMotion = true;XCTAssertFalse(state.animates)
        state = active;state.lowPowerMode = true;XCTAssertTrue(state.animates)
    }

    func testCacheEvictsOldEntriesAndBoundsMemory() {
        let cache = DrawingCache<String,Int>(limit:10)
        cache.insert(1,for:"a",cost:4);cache.insert(2,for:"b",cost:4)
        XCTAssertEqual(cache.value(for:"a"),1)
        cache.insert(3,for:"c",cost:4)
        XCTAssertNil(cache.value(for:"b"));XCTAssertEqual(cache.totalCost,8)
        cache.insert(4,for:"huge",cost:11);XCTAssertNil(cache.value(for:"huge"))
        cache.insert(5,for:"a",cost:2);XCTAssertEqual(cache.totalCost,6)
        XCTAssertEqual(DrawingResources.images.limit,32*1024*1024)
    }

    func testFontAndShadowCachesReuseIdenticalInputs() throws {
        let a = VPNDrawing.systemFont(size:12,weight:400),b = VPNDrawing.systemFont(size:12,weight:400)
        XCTAssertTrue(a === b)
        DrawingResources.images.removeAll()
        let ctx = try context(CGSize(width:200,height:120))
        func draw(_ color:UInt32) { VPNDrawing.shadow(CGRect(x:30,y:30,width:60,height:40),radius:9,blur:5,offset:.zero,color:color,alpha:0.4,in:ctx) }
        draw(0x123456);let cost = DrawingResources.images.totalCost
        draw(0x123456);XCTAssertEqual(DrawingResources.images.totalCost,cost)
        draw(0x456789);XCTAssertGreaterThan(DrawingResources.images.totalCost,cost)
    }

    func testMetricUpdatesAndAnimationFramesReuseStaticLayers() {
        let layers = ConnectionLayers(),size = CGSize(width:718,height:278)
        var state = ConnectionPresentation(status:.connected)
        layers.update(state,size:size,palette:.light,scale:2,epoch:1)
        let rasterizations = layers.rasterizations,staticBuilds = layers.staticBuilds
        for i in 0..<90 { layers.setPhase(Double(i)/30) }
        XCTAssertEqual(layers.rasterizations,rasterizations)
        for i in 1...3 {
            state.bytesIn = UInt64(i*100);state.duration = "00:00:0\(i)"
            layers.update(state,size:size,palette:.light,scale:2,epoch:1)
        }
        XCTAssertEqual(layers.staticBuilds,staticBuilds)
        XCTAssertEqual(layers.rasterizations,rasterizations+6)
        let after = layers.rasterizations
        layers.update(state,size:size,palette:.light,scale:2,epoch:1);XCTAssertEqual(layers.rasterizations,after)
        state.duration = "00:00:04"
        layers.update(state,size:size,palette:.light,scale:2,epoch:1)
        XCTAssertEqual(layers.rasterizations,after+1,"Duration must not redraw traffic or statistic labels")
        XCTAssertTrue(layers.hasVisibleAnimation(in:CGRect(x:510,y:1,width:200,height:100)))
        XCTAssertFalse(layers.hasVisibleAnimation(in:CGRect(x:0,y:230,width:718,height:48)),"Only statistics are visible after scrolling")
        XCTAssertFalse(layers.hasVisibleAnimation(in:.zero))
        layers.setRunning(true);XCTAssertTrue(layers.animationRunning)
        layers.setRunning(false);XCTAssertFalse(layers.animationRunning);XCTAssertEqual(layers.root.speed,0)
        layers.setRunning(true);XCTAssertEqual(layers.root.speed,1)
    }

    func testThemeResizeAndScaleInvalidateLayersWithoutChangingEpoch() {
        let layers = ConnectionLayers(),state = ConnectionPresentation(status:.connecting)
        layers.update(state,size:CGSize(width:718,height:301),palette:.light,scale:2,epoch:42)
        let initial = layers.rasterizations
        layers.update(state,size:CGSize(width:718,height:301),palette:.dark,scale:2,epoch:42)
        XCTAssertGreaterThan(layers.rasterizations,initial)
        let dark = layers.rasterizations
        layers.update(state,size:CGSize(width:558,height:301),palette:.dark,scale:1,epoch:42)
        XCTAssertGreaterThan(layers.rasterizations,dark)
        func animations(_ layer:CALayer) -> [CAAnimation] {
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey:$0) } + (layer.sublayers ?? []).flatMap(animations)
        }
        XCTAssertTrue(animations(layers.root).allSatisfy { $0.beginTime == 42 })
        var reduced = state;reduced.reduceMotion = true
        layers.update(reduced,size:CGSize(width:558,height:301),palette:.dark,scale:1,epoch:42)
        layers.setRunning(true);XCTAssertFalse(layers.animationRunning);XCTAssertTrue(animations(layers.root).isEmpty)
    }

    func testWorkspaceDefersHiddenRenderingAndReusesControlsForTraffic() throws {
        var environment = RenderingEnvironment(windowVisible:true,occluded:false)
        let model = WorkspaceModel(backend:NoBackend()),view = WorkspaceView(frame:CGRect(x:0,y:0,width:960,height:720),environment:{ environment })
        var snapshot = try fixture();model.accept(snapshot)
        view.update(model);view.layoutSubtreeIfNeeded()
        let builds = view.sceneBuilds,artwork = try XCTUnwrap(view.panelArtwork),staticBuilds = artwork.staticBuilds
        for i in 1...10 { snapshot.sessions[0].bytesIn = UInt64(i*100);model.accept(snapshot);view.update(model) }
        XCTAssertEqual(view.sceneBuilds,builds);XCTAssertEqual(artwork.staticBuilds,staticBuilds)
        XCTAssertTrue(view.panelArtwork === artwork)
        environment.occluded = true;view.refreshAnimation()
        let rasters = artwork.rasterizations
        snapshot.profiles[0].name = "Changed while hidden";model.accept(snapshot)
        for _ in 0..<10 { view.update(model) }
        XCTAssertEqual(view.sceneBuilds,builds);XCTAssertEqual(artwork.rasterizations,rasters)
        environment.occluded = false;view.refreshAnimation();XCTAssertEqual(view.sceneBuilds,builds+1)
        view.setCoveredByModal(true)
        let modalRasters = artwork.rasterizations
        snapshot.sessions[0].bytesIn += 100;model.accept(snapshot);view.update(model)
        XCTAssertEqual(artwork.rasterizations,modalRasters)
        view.setCoveredByModal(false);XCTAssertGreaterThan(artwork.rasterizations,modalRasters)
        let resumedBuilds = view.sceneBuilds
        environment.lowPowerMode = true;view.refreshAnimation()
        XCTAssertTrue(artwork.animationRunning)
        XCTAssertEqual(view.sceneBuilds,resumedBuilds)
        environment.reduceMotion = true;view.refreshAnimation();XCTAssertFalse(artwork.animationRunning)
        environment.reduceMotion = false;view.refreshAnimation();XCTAssertTrue(artwork.animationRunning)
        XCTAssertNil(view.window);view.dispose()
    }

    func testAppKitPanelLayerTreeMatchesStandaloneArtworkWithoutWindow() throws {
        let state = ConnectionPresentation(status:.connected),size = CGSize(width:718,height:278)
        let view = ConnectionPanelView(frame:CGRect(origin:.zero,size:size))
        view.update(state,palette:.light,epoch:1)
        let actual = try context(size),expected = try context(size)
        for ctx in [actual,expected] {
            ctx.translateBy(x:0,y:size.height);ctx.scaleBy(x:1,y:-1)
            ctx.setFillColor(VPNDrawing.color(ThemePalette.light.background));ctx.fill(CGRect(origin:.zero,size:size))
        }
        ConnectionPanel.draw(state,in:CGRect(origin:.zero,size:size),context:expected)
        try XCTUnwrap(view.layer).render(in:actual)
        try save(try XCTUnwrap(actual.makeImage()),"appkit-layer-tree")
        XCTAssertGreaterThanOrEqual(similarity(expected,actual),0.95)
        let cached = try context(size)
        cached.translateBy(x:0,y:size.height);cached.scaleBy(x:1,y:-1)
        cached.setFillColor(VPNDrawing.color(ThemePalette.light.background));cached.fill(CGRect(origin:.zero,size:size))
        view.displayIgnoringOpacity(view.bounds,in:NSGraphicsContext(cgContext:cached,flipped:true))
        try save(try XCTUnwrap(cached.makeImage()),"appkit-cached-panel")
        XCTAssertGreaterThanOrEqual(similarity(expected,cached),0.95,"AppKit backdrop capture must include retained artwork")
        XCTAssertNil(view.window)
    }

    func testRetainedPanelsMatchImmediateRendererAcrossThemesSizesAndPhases() throws {
        var scores:[String:Double] = [:]
        for theme in ResolvedTheme.allCases {
            let palette = ThemePalette(theme:theme)
            for width:CGFloat in [718,558] {
                for status in [SessionStatus.disconnected,.connected,.connecting] {
                    for phase in [0.0,0.35,0.75] {
                        let state = ConnectionPresentation(status:status,buttonDisabled:status == .connecting,address:"10.8.0.2",duration:"00:01:40",bytesIn:1_500_000,bytesOut:10_000_000,phase:phase)
                        let size = CGSize(width:width,height:ConnectionPanel.height(state,width:width))
                        let expected = try context(size),actual = try context(size)
                        for ctx in [expected,actual] { ctx.setFillColor(VPNDrawing.color(palette.background));ctx.fill(CGRect(origin:.zero,size:size)) }
                        expected.translateBy(x:0,y:size.height);expected.scaleBy(x:1,y:-1)
                        ConnectionPanel.draw(state,in:CGRect(origin:.zero,size:size),context:expected,palette:palette)
                        let layers = ConnectionLayers();layers.update(state,size:size,palette:palette,scale:2,epoch:1);layers.setPhase(phase)
                        actual.translateBy(x:0,y:size.height);actual.scaleBy(x:1,y:-1)
                        layers.root.render(in:actual)
                        let key = "\(theme)-\(width)-\(status)-\(phase)"
                        let score = similarity(expected,actual);scores[key] = score
                        if phase == 0 || score < 0.95 {
                            try save(try XCTUnwrap(actual.makeImage()),key+"-retained")
                            try save(try XCTUnwrap(expected.makeImage()),key+"-immediate")
                        }
                        XCTAssertGreaterThanOrEqual(score,0.95,key)
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject:scores,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("similarity.json"))
    }
}
