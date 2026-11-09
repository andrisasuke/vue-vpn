import AppKit
import XCTest

@MainActor final class StatsPresentationTests: XCTestCase {
    private struct NoBackend:BackendExecuting {
        func execute(_ command:BackendCommand) async -> BackendResult { XCTFail("Stats rendering called VPN backend");return BackendResult() }
    }
    private func state(_ page:StatsPage,palette:ThemePalette = .light) -> WorkspacePresentation {
        WorkspacePresentation(snapshot:Snapshot(profiles:[],sessions:[],helper:HelperStatus("not_registered","VPN helper disabled"),logs:[]),
            selectedID:"",screen:WorkspaceScreen(rawValue:page.rawValue)!,palette:palette,statsNavigation:true)
    }
    private func snapshot() -> SystemStatsSnapshot {
        var value = SystemStatsSnapshot()
        value.cpu = StatsCPU(total:0.42,system:0.12,user:0.3,idle:0.58,
            cores:[.init(kind:.efficiency,usage:0.2),.init(kind:.performance,usage:0.8)],uptime:7200,loads:[1,2,3])
        value.ram = StatsRAM(total:16_000_000_000,app:6_000_000_000,wired:2_000_000_000,
            compressed:1_000_000_000,free:7_000_000_000,swapUsed:100_000_000,swapTotal:2_000_000_000,pressure:"Normal")
        value.disk = StatsDisk(id:"disk0",name:"Internal SSD",counters:nil,total:500_000_000_000,available:200_000_000_000)
        value.diskReadRate = 1_200_000; value.diskWriteRate = 900_000
        value.interfaces = [.init(id:"en0",name:"Wi-Fi",active:true,mac:"02:00:00:00:00:01",addresses:["192.0.2.2"],counters:.init(read:0,write:0))]
        value.selectedInterface = "en0";value.networkDownRate = 1_200_000;value.networkUpRate = 300_000
        value.networkDownTotal = 10_000_000;value.networkUpTotal = 2_000_000
        value.publicIPv4 = .init(address:"203.0.113.2",state:.current)
        value.connectivity.state = .reachable;value.connectivity.latencyMS = 20
        for time in 0..<20 {
            value.cpuHistory.add(.init(time:Double(time),value:Double(time)/20))
            value.networkHistory.add(.init(time:Double(time),value:Double(time)*1000,second:nil))
        }
        value.processes[.cpu] = [.init(pid:1,name:String(repeating:"Long process name ",count:10),amount:32,outbound:nil,scope:"% of one core")]
        return value
    }

    func testMonitoringControlsAndStatesAtBothSizesAndThemes() throws {
        for palette in [ThemePalette.light,.dark] { for width:CGFloat in [606,766] { for page in StatsPage.allCases {
            var presentation = state(page,palette:palette)
            presentation.statsMenuStyles[page] = .icon
            var value = snapshot(); value.enabledPages.remove(page)
            let disabled = WorkspaceContent.make(presentation,width:width,clock:0,connection:.init(),stats:value)
            let enable = try XCTUnwrap(disabled.hits.first { $0.action == .toggleStatsMonitoring(page) })
            XCTAssertTrue(enable.enabled);XCTAssertFalse(enable.checked);XCTAssertEqual(enable.role,.checkbox)
            XCTAssertLessThanOrEqual(enable.rect.maxX,width)
            let display = try XCTUnwrap(disabled.hits.first { $0.action == .toggleStatsMenu(page) })
            XCTAssertTrue(display.checked);XCTAssertFalse(display.enabled)
            let icon = try XCTUnwrap(disabled.hits.first { $0.action == .statsMenuStyle(page,.icon) })
            XCTAssertTrue(icon.checked);XCTAssertFalse(icon.enabled)
            XCTAssertTrue(disabled.statsCharts.isEmpty)
            XCTAssertFalse(disabled.hits.contains { $0.action == .refreshPublicAddress || $0.action == .selectStatsInterface || $0.action == .editProbeTarget })
            XCTAssertEqual(StatsPanel.accessibilitySummary(page,value),"\(page.title) monitoring is disabled")
            let button = SceneActionButton(region:enable) {}
            XCTAssertEqual(button.accessibilityRole(),.checkBox);XCTAssertEqual(button.accessibilityValue() as? Int,0)
            value.enabledPages.insert(page);value.collectingPages.insert(page)
            let collecting = WorkspaceContent.make(presentation,width:width,clock:0,connection:.init(),stats:value)
            XCTAssertTrue(collecting.statsCharts.isEmpty)
            XCTAssertEqual(StatsPanel.accessibilitySummary(page,value),"\(page.title) monitoring is collecting")
            for scene in [disabled,collecting] {
                XCTAssertTrue(scene.hits.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= width && $0.rect.maxY <= scene.height })
                let context = try XCTUnwrap(CGContext(data:nil,width:Int(width),height:Int(ceil(scene.height)),bitsPerComponent:8,
                    bytesPerRow:Int(width)*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.translateBy(x:0,y:scene.height);context.scaleBy(x:1,y:-1)
                scene.draw(in:context);XCTAssertNotNil(context.makeImage())
            }
            value.collectingPages.remove(page); value = SystemStatsSnapshot()
            XCTAssertTrue(StatsPanel.accessibilitySummary(page,value).contains("Unavailable"))
        } } }
    }

    func testIconStylesHaveFixedColumnsAndColoredReadableArtwork() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dark in [false,true] { for scale in [1,2] { for page in StatsPage.allCases {
            let values = page == .network ? ["0B/s","999B/s","1.0KB/s","999KB/s","1.0MB/s","999MB/s","1.0GB/s","999+GB/s","—"] : ["0%","9%","10%","20%","54%","76%","86%","99%","100%","—"]
            var expectedGreen:CGRect?; var expectedInkRight:Int?; var expectedRows:[Int]?
            for value in values {
                let metric = StatsMenuMetric(page:page,top:page == .network ? "↓"+value : page.title,
                    bottom:page == .network ? "↑"+value : value,tooltip:"",accessibilityLabel:"")
                let image = StatsMenuArtwork.image(for:metric,style:.icon,dark:dark)
                XCTAssertEqual(image.size,StatsMenuArtwork.size(for:page,style:.icon)); XCTAssertFalse(image.isTemplate)
                let w = Int(ceil(image.size.width))*scale, h = Int(image.size.height)*scale
                let context = try XCTUnwrap(CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor); context.fill(CGRect(x:0,y:0,width:w,height:h))
                context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
                image.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
                NSGraphicsContext.restoreGraphicsState()
                if value == (page == .network ? "999+GB/s" : "54%") {
                    let png = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
                    try png.write(to:root.appendingPathComponent("artifacts/migration/stats-icon-\(page.rawValue)-\(dark ? "dark" : "light")-\(scale)x.png"))
                }
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
                var greenX:[Int] = [], greenY:[Int] = [], inkX:[Int] = [], rowInk:[[Int]] = [[],[]]
                for y in 0..<h { for x in 0..<w {
                    let i = (y*w+x)*4, r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
                    if g > r+8 && g > b+4 { greenX.append(x); greenY.append(y) }
                    else if dark ? r > 50 : r < 205 { inkX.append(x); rowInk[y < h/2 ? 0 : 1].append(x) }
                }}
                let left = try XCTUnwrap(greenX.min()), right = try XCTUnwrap(greenX.max())
                let bottom = try XCTUnwrap(greenY.min()), top = try XCTUnwrap(greenY.max())
                let inkRight = try XCTUnwrap(inkX.max())
                let bounds = CGRect(x:left,y:bottom,width:right-left+1,height:top-bottom+1)
                if let expectedGreen { XCTAssertEqual(bounds,expectedGreen,"\(page) \(value)") } else { expectedGreen = bounds }
                XCTAssertGreaterThan(try XCTUnwrap(inkX.min()),0,"\(page) \(value) text clipped")
                if page == .network {
                    let rows = try rowInk.map { try XCTUnwrap($0.max()) }
                    if let expectedRows {
                        for i in 0..<2 { XCTAssertLessThanOrEqual(abs(rows[i]-expectedRows[i]),scale,"network row \(i) \(value)") }
                    } else { expectedRows = rows }
                } else {
                    if let expectedInkRight { XCTAssertLessThanOrEqual(abs(inkRight-expectedInkRight),scale,"\(page) \(value)") } else { expectedInkRight = inkRight }
                }
                XCTAssertGreaterThanOrEqual(bounds.width/CGFloat(scale),page == .ssd ? 13 : 15,"\(page) glyph width")
                XCTAssertGreaterThanOrEqual(bounds.height/CGFloat(scale),page == .ram ? 10 : 15,"\(page) glyph height")
                let gap = CGFloat(left-inkRight-1)/CGFloat(scale)
                XCTAssertGreaterThanOrEqual(gap,1,"\(page) \(value) overlaps")
                XCTAssertLessThanOrEqual(gap,6,"\(page) \(value) visible gap")
                XCTAssertGreaterThan(left,0); XCTAssertLessThan(right,w-1)
                XCTAssertGreaterThan(bottom,0); XCTAssertLessThan(top,h-1)
            }
        } } }
    }

    private struct ReferenceMask {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        enum Channel { case alpha, luminance }

        static func from(_ image: CGImage, channel: Channel) throws -> ReferenceMask {
            let width = image.width
            let height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var pixels = [UInt8](repeating: 0, count: width * height)
            for index in pixels.indices {
                let offset = index * 4
                pixels[index] = channel == .alpha
                    ? rgba[offset + 3]
                    : max(rgba[offset], max(rgba[offset + 1], rgba[offset + 2]))
            }
            return ReferenceMask(width: width, height: height, pixels: pixels)
        }

        func normalized() -> ReferenceMask {
            let visible = pixels.indices.filter { pixels[$0] >= 32 }
            guard let first = visible.first else { return self }
            let minX = visible.map { $0 % width }.min()!
            let maxX = visible.map { $0 % width }.max()!
            let minY = visible.map { $0 / width }.min()!
            let maxY = visible.map { $0 / width }.max()!
            let cropWidth = maxX - minX + 1
            let cropHeight = maxY - minY + 1
            var crop = [UInt8](repeating: 0, count: cropWidth * cropHeight)
            for y in 0..<cropHeight {
                for x in 0..<cropWidth {
                    crop[y * cropWidth + x] = pixels[(minY + y) * width + minX + x]
                }
            }
            let factor = 256.0 / CGFloat(max(cropWidth, cropHeight))
            let scaledWidth = max(1, Int((CGFloat(cropWidth) * factor).rounded()))
            let scaledHeight = max(1, Int((CGFloat(cropHeight) * factor).rounded()))
            var output = [UInt8](repeating: 0, count: 256 * 256)
            let offsetX = (256 - scaledWidth) / 2
            let offsetY = (256 - scaledHeight) / 2
            for y in 0..<scaledHeight {
                let sourceY = (CGFloat(y) + 0.5) / factor - 0.5
                let y0 = max(0, min(cropHeight - 1, Int(floor(sourceY))))
                let y1 = max(0, min(cropHeight - 1, y0 + 1))
                let fy = sourceY - floor(sourceY)
                for x in 0..<scaledWidth {
                    let sourceX = (CGFloat(x) + 0.5) / factor - 0.5
                    let x0 = max(0, min(cropWidth - 1, Int(floor(sourceX))))
                    let x1 = max(0, min(cropWidth - 1, x0 + 1))
                    let fx = sourceX - floor(sourceX)
                    let top = CGFloat(crop[y0 * cropWidth + x0]) * (1 - fx)
                        + CGFloat(crop[y0 * cropWidth + x1]) * fx
                    let bottom = CGFloat(crop[y1 * cropWidth + x0]) * (1 - fx)
                        + CGFloat(crop[y1 * cropWidth + x1]) * fx
                    output[(offsetY + y) * 256 + offsetX + x] = UInt8(max(0, min(255, (top * (1 - fy) + bottom * fy).rounded())))
                }
            }
            return ReferenceMask(width: 256, height: 256, pixels: output)
        }
    }

    private func statsIcon(for page: StatsPage) -> VPNIcon {
        switch page {
        case .cpu: .chip
        case .ram: .memory
        case .ssd: .ssd
        case .network: .network
        }
    }

    private func renderStatsIconCrop(_ image: NSImage, page: StatsPage, scale: Int) throws -> CGImage {
        let width = Int(ceil(StatsMenuArtwork.size(for: page, style: .icon).width)) * scale
        let height = Int(StatsMenuArtwork.height) * scale
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let rect = StatsMenuArtwork.iconRect(for: page)
        let crop = CGRect(x: rect.minX * CGFloat(scale), y: CGFloat(height) - rect.maxY * CGFloat(scale),
                          width: rect.width * CGFloat(scale), height: rect.height * CGFloat(scale))
        return try XCTUnwrap(context.makeImage()?.cropping(to: crop))
    }

    private func renderCanonicalStatsIcon(_ page: StatsPage, scale: Int) throws -> CGImage {
        let size = 20 * scale
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(size))
            context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            statsIcon(for: page).draw(in: CGRect(x: 0, y: 0, width: 20, height: 20),
                                      color: 0x308F4D, context: context)
            return try XCTUnwrap(context.makeImage())
        }
    }

    private func bitmapPixels(_ image: CGImage) throws -> [UInt8] {
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.samplesPerPixel, 4)
        guard let data = bitmap.bitmapData else {
            throw NSError(domain: "StatsPresentationTests", code: 1)
        }
        var result = [UInt8]()
        result.reserveCapacity(image.width * image.height * 4)
        for y in 0..<image.height {
            let row = data.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<image.width {
                let pixel = row.advanced(by: x * bitmap.samplesPerPixel)
                result.append(contentsOf: UnsafeBufferPointer(start: pixel, count: 4))
            }
        }
        return result
    }

    func testStatsMenuArtworkIconsMatchSidebarOrientationAndConnectedGreen() throws {
        let metrics = StatsPage.allCases.map {
            StatsMenuMetric(page: $0, top: $0 == .network ? "↓1.0MB/s" : $0.title,
                            bottom: $0 == .network ? "↑300KB/s" : "54%", tooltip: "", accessibilityLabel: "")
        }
        for dark in [false, true] {
            for scale in [1, 2] {
                for metric in metrics {
                    let image = StatsMenuArtwork.image(for: metric, style: .icon, dark: dark)
                    let actualPixels = try bitmapPixels(renderStatsIconCrop(image, page: metric.page, scale: scale))
                    let canonicalPixels = try bitmapPixels(renderCanonicalStatsIcon(metric.page, scale: scale))
                    let expected = stride(from: 3, to: canonicalPixels.count, by: 4).map { canonicalPixels[$0] >= 128 }
                    let rendered = stride(from: 3, to: actualPixels.count, by: 4).map { actualPixels[$0] >= 128 }
                    let intersection = zip(expected, rendered).reduce(0) { $0 + ($1.0 && $1.1 ? 1 : 0) }
                    let union = zip(expected, rendered).reduce(0) { $0 + ($1.0 || $1.1 ? 1 : 0) }
                    let iou = Double(intersection) / Double(union)
                    XCTAssertGreaterThanOrEqual(iou, 0.99,
                        "\(metric.page) \(dark ? "dark" : "light") \(scale)x orientation IoU was \(iou)")

                    var opaquePixels = 0
                    for index in stride(from: 0, to: actualPixels.count, by: 4) where actualPixels[index + 3] == 255 {
                        opaquePixels += 1
                        XCTAssertEqual(Array(actualPixels[index..<(index + 3)]), [48, 143, 77],
                            "\(metric.page) \(dark ? "dark" : "light") \(scale)x icon color")
                    }
                    XCTAssertGreaterThan(opaquePixels, 0, "\(metric.page) icon had no opaque pixels")
                }
            }
        }
    }

    func testStatsIconsMatchIndependentReferenceMasksAtHighResolution() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("References")
        let cases: [(StatsPage, VPNIcon, String)] = [
            (.cpu, .chip, "cpu"), (.ram, .memory, "ram"), (.ssd, .ssd, "ssd"), (.network, .network, "network")
        ]
        for (_, icon, name) in cases {
            let source = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("stats-icon-\(name)-mask.png")))
            var proposed = NSRect(origin: .zero, size: source.size)
            let referenceImage = try XCTUnwrap(source.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
            let reference = try ReferenceMask.from(referenceImage, channel: .luminance)
            let pixels = 256
            var buffer = [UInt8](repeating: 0, count: pixels * pixels * 4)
            let actualImage: CGImage = try buffer.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: pixels, height: pixels,
                    bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.translateBy(x: 0, y: CGFloat(pixels))
                context.scaleBy(x: 2, y: -2)
                icon.draw(in: CGRect(x: 0, y: 0, width: 128, height: 128), color: 0xffffff, context: context, snap: false)
                return try XCTUnwrap(context.makeImage())
            }
            let actual = try ReferenceMask.from(actualImage, channel: .alpha).normalized()
            let expected = reference.pixels.map { $0 >= 128 }
            let rendered = actual.pixels.map { $0 >= 128 }
            let intersection = zip(expected, rendered).reduce(0) { $0 + ($1.0 && $1.1 ? 1 : 0) }
            let union = zip(expected, rendered).reduce(0) { $0 + ($1.0 || $1.1 ? 1 : 0) }
            let iou = Double(intersection) / Double(union)
            XCTAssertGreaterThanOrEqual(iou, 0.95, "\(name) normalized reference-mask IoU was \(iou)")
        }
    }

    func testAdjacentArtworkUsesCompactStableCells() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pages = StatsMenuPresentation.order
        let combinations:[[StatsMenuStyle]] = [Array(repeating:.label,count:4),Array(repeating:.icon,count:4),[.icon,.label,.icon,.label],[.label,.icon,.label,.icon]]
        let percentages = ["0%","9%","10%","54%","99%","100%","—"]
        let rates = ["0B/s","999B/s","1.0KB/s","999KB/s","1.0MB/s","999MB/s","1.0GB/s","999+GB/s","—"]
        var measurements:[String] = []
        for dark in [false,true] { for scale in [1,2] { for (combination,styles) in combinations.enumerated() {
            for sample in 0..<rates.count {
                let metrics = pages.map { page in
                    StatsMenuMetric(page:page,top:page == .network ? "↓"+rates[sample] : page.title,
                        bottom:page == .network ? "↑"+rates[rates.count-1-sample] : percentages[sample % percentages.count],tooltip:"",accessibilityLabel:"")
                }
                let images = zip(metrics,styles).map { StatsMenuArtwork.image(for:$0.0,style:$0.1,dark:dark) }
                let lengths = zip(pages,styles).map { StatsMenuArtwork.statusLength(for:$0.0,style:$0.1) }
                func render(extra:CGFloat) throws -> (gaps:[Int],width:Int) {
                    let widths = lengths.map { $0+extra }
                    let width = Int(widths.reduce(0,+))*scale, height = Int(StatsMenuArtwork.height)*scale
                    let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
                    var x:CGFloat = 0
                    for (index,image) in images.enumerated() {
                        image.draw(at:CGPoint(x:x+extra/2,y:0),from:.zero,operation:.sourceOver,fraction:1)
                        if dark && styles[index] == .label {
                            context.saveGState(); context.setBlendMode(.sourceAtop); context.setFillColor(NSColor.white.cgColor)
                            context.fill(CGRect(x:x,y:0,width:widths[index],height:StatsMenuArtwork.height)); context.restoreGState()
                        }
                        x += widths[index]
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
                    var bounds:[(Int,Int)] = []; var start = 0
                    for cellWidth in widths {
                        let end = start+Int(cellWidth)*scale
                        var ink:[Int] = []
                        for y in 0..<height { for px in start..<end where pixels[(y*width+px)*4+3] > 30 { ink.append(px) } }
                        let left = try XCTUnwrap(ink.min()), right = try XCTUnwrap(ink.max())
                        XCTAssertGreaterThan(left,start); XCTAssertLessThan(right,end-1)
                        bounds.append((left,right)); start = end
                    }
                    if sample == 3 && combination == 2 {
                        context.saveGState(); context.setBlendMode(.destinationOver)
                        context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
                        context.fill(CGRect(x:0,y:0,width:CGFloat(width)/CGFloat(scale),height:StatsMenuArtwork.height))
                        context.restoreGState()
                        let png = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
                        try png.write(to:root.appendingPathComponent("artifacts/migration/stats-spacing-\(extra == 0 ? "after" : "before")-\(dark ? "dark" : "light")-\(scale)x.png"))
                    }
                    return (zip(bounds,bounds.dropFirst()).map { $1.0-$0.1-1 },width)
                }
                let before = try render(extra:4), after = try render(extra:0)
                XCTAssertEqual(before.width-after.width,16*scale)
                for (old,new) in zip(before.gaps,after.gaps) {
                    XCTAssertGreaterThanOrEqual(new,2*scale-1)
                    XCTAssertEqual(old-new,4*scale)
                }
                if sample == 3 { measurements.append("\(dark ? "dark" : "light") \(scale)x styles=\(combination) widths(pt)=\(lengths) gaps before/after(px)=\(before.gaps)/\(after.gaps)") }
            }
        } } }
        try measurements.joined(separator:"\n").write(to:root.appendingPathComponent("artifacts/migration/stats-spacing-measurements.txt"),atomically:true,encoding:.utf8)
    }

    func testSharedContainerRegionsAndScreenshotSpacing() throws {
        let pages = StatsMenuPresentation.order
        let container = StatsMenuContainer(frame:.zero)
        var selected:StatsPage?
        container.open = { selected = $0 }
        var sample = snapshot()
        sample.ram = StatsRAM(total:100,app:86,wired:0,compressed:0,free:14)
        sample.disk = StatsDisk(id:"disk0",name:"Internal SSD",counters:nil,total:100,available:24)
        sample.cpu.total = 0.20
        sample.networkDownRate = 995; sample.networkUpRate = 0
        let metrics = StatsMenuPresentation.metrics(sample)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for mask in 0..<16 {
            let visible = Set(pages.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
            for styleMask in 0..<16 {
                let styles = Dictionary(uniqueKeysWithValues:pages.enumerated().map { ($0.element,styleMask & (1 << $0.offset) != 0 ? StatsMenuStyle.icon : .label) })
                container.update(metrics:metrics,visible:visible,styles:styles,dark:false)
                var x:CGFloat = 0
                for page in pages {
                    let button = try XCTUnwrap(container.buttons[page])
                    XCTAssertEqual(button.isHidden,!visible.contains(page))
                    guard visible.contains(page) else { continue }
                    XCTAssertEqual(button.frame.minX,x)
                    XCTAssertEqual(button.frame.width,StatsMenuArtwork.statusLength(for:page,style:styles[page]!))
                    XCTAssertEqual(button.accessibilityLabel(),metrics.first { $0.page == page }?.accessibilityLabel)
                    XCTAssertEqual(button.toolTip,metrics.first { $0.page == page }?.tooltip)
                    XCTAssertTrue(button.acceptsFirstResponder)
                    XCTAssertEqual(button.accessibilityRole(),.button)
                    container.activate(button); XCTAssertEqual(selected,page)
                    x += button.frame.width
                }
                XCTAssertEqual(container.frame.width,x)
                let count = container.artworkUpdates
                container.update(metrics:metrics,visible:visible,styles:styles,dark:false)
                XCTAssertEqual(container.artworkUpdates,count)
            }
        }
        let styles = Dictionary(uniqueKeysWithValues:pages.map { ($0,StatsMenuStyle.icon) })
        for dark in [false,true] { for scale in [1,2] {
            container.update(metrics:metrics,visible:Set(pages),styles:styles,dark:dark)
            let width = Int(container.frame.width)*scale, height = 22*scale
            let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            // Before geometry placed independent artwork at its exact item length.
            // System-controlled spacing is deliberately not invented offscreen.
            let before = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            before.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:before,flipped:false)
            var beforeX:CGFloat = 0
            for metric in metrics {
                let image = StatsMenuArtwork.image(for:metric,style:.icon,dark:dark)
                image.draw(at:CGPoint(x:beforeX,y:0),from:.zero,operation:.sourceOver,fraction:1)
                beforeX += StatsMenuArtwork.statusLength(for:metric.page,style:.icon)
            }
            NSGraphicsContext.restoreGraphicsState()
            before.saveGState(); before.setBlendMode(.destinationOver)
            before.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
            before.fill(CGRect(x:0,y:0,width:container.frame.width,height:22)); before.restoreGState()
            let beforePNG = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(before.makeImage())).representation(using:.png,properties:[:]))
            try beforePNG.write(to:root.appendingPathComponent("artifacts/migration/stats-compact-screenshot-before-model-\(dark ? "dark" : "light")-\(scale)x.png"))
            context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            for page in pages {
                let button = try XCTUnwrap(container.buttons[page])
                context.saveGState()
                context.translateBy(x:button.frame.minX,y:button.frame.maxY)
                context.scaleBy(x:1,y:-1)
                button.draw(button.bounds)
                context.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
            var bounds:[(Int,Int)] = []
            for page in pages {
                let frame = try XCTUnwrap(container.buttons[page]).frame
                let start = Int(frame.minX)*scale, end = Int(frame.maxX)*scale
                var ink:[Int] = []
                for y in 0..<height { for x in start..<end where pixels[(y*width+x)*4+3] > 30 { ink.append(x) } }
                let left = try XCTUnwrap(ink.min()), right = try XCTUnwrap(ink.max())
                XCTAssertGreaterThan(left,start); XCTAssertLessThan(right,end-1)
                bounds.append((left,right))
            }
            let gaps = zip(bounds,bounds.dropFirst()).map { $1.0-$0.1-1 }
            XCTAssertTrue(gaps.allSatisfy { $0 >= 2*scale-1 })
            XCTAssertTrue((9*scale...15*scale).contains(gaps[0]))
            XCTAssertTrue((16*scale...22*scale).contains(gaps[1]))
            XCTAssertTrue((10*scale...16*scale).contains(gaps[2]))
            context.saveGState(); context.setBlendMode(.destinationOver)
            context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
            context.fill(CGRect(x:0,y:0,width:container.frame.width,height:22)); context.restoreGState()
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
            try png.write(to:root.appendingPathComponent("artifacts/migration/stats-compact-screenshot-after-\(dark ? "dark" : "light")-\(scale)x.png"))
            print("COMPACT screenshot \(dark ? "dark" : "light") \(scale)x bounds=\(bounds) gaps=\(gaps)")
        } }
    }

    func testStatsNavigationAndProfileImportRemainReachable() throws {
        let base = state(.cpu)
        let context = try XCTUnwrap(CGContext(data:nil,width:194,height:660,bitsPerComponent:8,bytesPerRow:194*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let hits = WorkspaceChrome.sidebar(base,size:CGSize(width:194,height:660),context:context)
        for page in StatsPage.allCases {
            let screen = try XCTUnwrap(WorkspaceScreen(rawValue:page.rawValue))
            XCTAssertTrue(hits.contains { $0.action == .screen(screen) && $0.title == "Stats \(page.title)" })
        }
        XCTAssertEqual(hits.filter { $0.action == .importProfile }.count,2)
        XCTAssertTrue(hits.allSatisfy { $0.rect.maxY <= 660 })

        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("artifacts/migration")
        let variants:[(String,WorkspaceScreen,WorkspaceScreen?)] = [
            ("normal",.overview,nil),("cpu",.cpu,nil),("ram",.ram,nil),
            ("ssd",.ssd,nil),("network",.network,nil),("hover-ram",.overview,.ram)
        ]
        for (theme,palette) in [("light",ThemePalette.light),("dark",.dark)] {
            for scale in [1,2] {
                for (name,screen,hovered) in variants {
                    var presentation = state(.cpu,palette:palette)
                    presentation.screen = screen
                    let context = try XCTUnwrap(CGContext(data:nil,width:194*scale,height:660*scale,
                        bitsPerComponent:8,bytesPerRow:194*scale*4,
                        space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
                    context.translateBy(x:0,y:660)
                    context.scaleBy(x:1,y:-1)
                    _ = WorkspaceChrome.sidebar(presentation,size:CGSize(width:194,height:660),context:context,
                        feedback:{ action,_ in .init(hovered:action == .screen(hovered ?? .overview)) })
                    let image = try XCTUnwrap(context.makeImage())
                    let crop = try XCTUnwrap(image.cropping(to:CGRect(x:0,y:300*scale,width:194*scale,height:190*scale)))
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage:crop).representation(using:.png,properties:[:]))
                    try data.write(to:output.appendingPathComponent("stats-sidebar-\(theme)-\(name)-\(scale)x.png"))
                }
            }
        }
    }

    func testFourPagesRenderAtBothSizesAndThemesWithUnavailableData() throws {
        for palette in [ThemePalette.light,.dark] {
            for width:CGFloat in [606,766] {
                for page in StatsPage.allCases {
                    for value in [snapshot(),SystemStatsSnapshot()] {
                let scene = WorkspaceContent.make(state(page,palette:palette),width:width,clock:0,connection:.init(),stats:value)
                XCTAssertGreaterThan(scene.height,250)
                XCTAssertTrue(scene.hits.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= width && $0.rect.maxY <= scene.height })
                let context = try XCTUnwrap(CGContext(data:nil,width:Int(width),height:Int(ceil(scene.height)),bitsPerComponent:8,
                    bytesPerRow:Int(width)*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.translateBy(x:0,y:scene.height);context.scaleBy(x:1,y:-1)
                scene.draw(in:context)
                XCTAssertNotNil(context.makeImage())
                    }
                }
            }
        }
    }

    func testMenuFormatsAndRendersCompactTwoRowItemsWithoutStatusItems() throws {
        let values = StatsMenuPresentation.metrics(snapshot())
        XCTAssertEqual(values.map(\.page),[.ram,.ssd,.network,.cpu])
        XCTAssertEqual(values.map(\.top),["RAM","SSD","↓1.2MB/s","CPU"])
        XCTAssertEqual(values.map(\.bottom),["56%","60%","↑300KB/s","42%"])
        XCTAssertEqual(StatsMenuPresentation.metrics(.init()).map(\.bottom),["—","—","↑—","—"])
        XCTAssertTrue(values[2].accessibilityLabel.contains("Download 1.2MB/s, upload 300KB/s"))
        let widths = values.map { StatsMenuArtwork.statusLength(for:$0.page) }
        XCTAssertLessThan(widths.reduce(0,+),205)
        XCTAssertLessThan(widths[2],75)
        var peak = snapshot()
        peak.cpu.total = 1
        peak.networkDownRate = 1_234_000_000_000
        let peakValues = StatsMenuPresentation.metrics(peak)
        XCTAssertEqual(peakValues[3].bottom,"100%")
        XCTAssertEqual(peakValues[2].top,"↓999+GB/s")
        var minimum = snapshot()
        minimum.cpu.total = 0
        minimum.ram = StatsRAM(total:100,app:0,wired:0,compressed:0,free:100)
        minimum.disk = StatsDisk(id:"disk0",name:"Internal SSD",counters:nil,total:100,available:100)
        minimum.networkDownRate = 0;minimum.networkUpRate = 0
        peak.ram = StatsRAM(total:100,app:100,wired:0,compressed:0,free:0)
        peak.disk = StatsDisk(id:"disk0",name:"Internal SSD",counters:nil,total:100,available:0)
        var samples = [snapshot(),SystemStatsSnapshot(),minimum,peak]
        var percentStrips:[(String,[StatsMenuMetric])] = []
        let rates:[Double] = [0,999,1_000,999_499,999_500,1_000_000,
            999_499_999,999_500_000,1_000_000_000,1_234_000_000_000]
        for (index,percent) in [0,9,10,40,78,85,100].enumerated() {
            var sample = snapshot()
            sample.cpu.total = Double(percent)/100
            sample.ram = StatsRAM(total:100,app:UInt64(percent),wired:0,compressed:0,free:UInt64(100-percent))
            sample.disk = StatsDisk(id:"disk0",name:"Internal SSD",counters:nil,total:100,available:UInt64(100-percent))
            sample.networkDownRate = rates[index]
            sample.networkUpRate = rates[rates.count-1-index]
            samples.append(sample)
            percentStrips.append(("\(percent)",StatsMenuPresentation.metrics(sample)))
        }
        for rate in rates {
            var sample = snapshot()
            sample.networkDownRate = rate;sample.networkUpRate = rate
            samples.append(sample)
        }
        XCTAssertEqual(Array(samples.map { StatsMenuPresentation.metrics($0)[2].top }.suffix(rates.count)),
            ["↓0B/s","↓999B/s","↓1.0KB/s","↓999KB/s","↓1.0MB/s",
             "↓1.0MB/s","↓999MB/s","↓1.0GB/s","↓1.0GB/s","↓999+GB/s"])
        for sample in samples {
            let metrics = StatsMenuPresentation.metrics(sample)
            XCTAssertEqual(metrics.map { StatsMenuArtwork.statusLength(for:$0.page) },widths)
            for metric in metrics {
                XCTAssertEqual(StatsMenuArtwork.image(for:metric).size,StatsMenuArtwork.size(for:metric.page))
            }
        }

        // Render all four side by side at both display scales without a status item.
        let width = Int(ceil(widths.reduce(0,+)))
        let height = Int(StatsMenuArtwork.height)
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var screenshot = snapshot()
        screenshot.cpu.total = 0.40
        screenshot.ram = StatsRAM(total:100,app:85,wired:0,compressed:0,free:15)
        screenshot.disk = StatsDisk(id:"disk0",name:"Internal SSD",counters:nil,total:100,available:22)
        screenshot.networkDownRate = 3_700
        screenshot.networkUpRate = 2_800
        let strips:[(String,[StatsMenuMetric])] = [("screenshot",StatsMenuPresentation.metrics(screenshot)),
            ("normal",values),
            ("minimum",StatsMenuPresentation.metrics(minimum))] + percentStrips + [
            ("maximum",StatsMenuPresentation.metrics(peak)),
            ("unavailable",StatsMenuPresentation.metrics(.init()))]
        for scale in [1,2] {
            var metricLeftEdges:[Int:Int] = [:]
            for (name,strip) in strips {
                let context = try XCTUnwrap(CGContext(data:nil,width:width*scale,height:height*scale,
                    bitsPerComponent:8,bytesPerRow:width*scale*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x:0,y:0,width:width*scale,height:height*scale))
                context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
                let graphics = NSGraphicsContext(cgContext:context,flipped:false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                var x:CGFloat = 0
                for (index,value) in strip.enumerated() {
                    StatsMenuArtwork.image(for:value).draw(at:CGPoint(x:x,y:0),from:.zero,operation:.sourceOver,fraction:1)
                    x += widths[index]
                }
                NSGraphicsContext.restoreGraphicsState()
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
                x = 0
                for (index,itemWidth) in widths.enumerated() {
                    let start = Int(x*CGFloat(scale))
                    let end = Int((x+itemWidth)*CGFloat(scale))
                    var rowLeftEdges:[Int] = []
                    for rows in [0..<(height*scale/2),(height*scale/2)..<(height*scale)] {
                        var inkX:[Int] = []
                        for y in rows { for px in start..<end {
                            let offset = (y*width*scale+px)*4
                            if pixels[offset] < 180 { inkX.append(px) }
                        }}
                        XCTAssertFalse(inkX.isEmpty,"item \(index) has a missing row")
                        rowLeftEdges.append(inkX.min() ?? -1)
                    }
                    XCTAssertLessThanOrEqual(abs(rowLeftEdges[0]-rowLeftEdges[1]),scale,
                        "item \(index) \(name) visible left edges differ at \(scale)x: \(rowLeftEdges)")
                    XCTAssertLessThanOrEqual(rowLeftEdges[0]-start,4*scale,
                        "item \(index) \(name) is not left-aligned within its fixed cell at \(scale)x")
                    if let expected = metricLeftEdges[index] {
                        XCTAssertLessThanOrEqual(abs(rowLeftEdges[1]-expected),scale,
                            "item \(index) \(name) value left edge shifted at \(scale)x: \(rowLeftEdges[1]) vs \(expected)")
                    } else {
                        metricLeftEdges[index] = rowLeftEdges[1]
                    }
                    x += itemWidth
                }
                let output = root.appendingPathComponent("artifacts/migration/stats-menu-two-row-\(name)-\(scale)x.png")
                let bitmap = try XCTUnwrap(context.makeImage())
                let png = NSBitmapImageRep(cgImage:bitmap).representation(using:.png,properties:[:])
                try XCTUnwrap(png).write(to:output)
            }
        }
        let controller = StatsMenuBarController()
        XCTAssertFalse(controller.installed)
        controller.update(snapshot())
        XCTAssertFalse(controller.installed)
    }

    func testEachStatsPageOffersAccessibleIndependentMenuToggleWithoutChangingCharts() throws {
        let sample = snapshot()
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for (theme,palette) in [("light",ThemePalette.light),("dark",.dark)] {
            for width:CGFloat in [606,766] {
                for page in StatsPage.allCases {
                    var shown = state(page,palette:palette)
                    let on = WorkspaceContent.make(shown,width:width,clock:0,connection:.init(),stats:sample)
                    shown.statsMenuVisible.remove(page)
                    let off = WorkspaceContent.make(shown,width:width,clock:0,connection:.init(),stats:sample)
                    let onHit = try XCTUnwrap(on.hits.first { $0.action == .toggleStatsMenu(page) })
                    let offHit = try XCTUnwrap(off.hits.first { $0.action == .toggleStatsMenu(page) })
                    let monitoringHit = try XCTUnwrap(on.hits.first { $0.action == .toggleStatsMonitoring(page) })
                    XCTAssertEqual(on.hits.filter { $0.action == .toggleStatsMenu(page) }.count,1)
                    XCTAssertEqual(off.hits.filter { $0.action == .toggleStatsMenu(page) }.count,1)
                    XCTAssertEqual(monitoringHit.rect.minX,onHit.rect.minX)
                    XCTAssertEqual(onHit.title,"Show \(page.title) in menu bar")
                    XCTAssertEqual(onHit.role,.checkbox)
                    XCTAssertTrue(onHit.checked)
                    XCTAssertFalse(offHit.checked)
                    XCTAssertEqual(onHit.rect,offHit.rect)
                    XCTAssertLessThanOrEqual(onHit.rect.maxX,width)
                    XCTAssertLessThan(onHit.rect.maxY,90)
                    for choice in StatsMenuStyle.allCases {
                        let hit = try XCTUnwrap(off.hits.first { $0.action == .statsMenuStyle(page,choice) })
                        XCTAssertEqual(hit.role,.radio)
                        XCTAssertEqual(hit.checked,choice == .label)
                        XCTAssertLessThanOrEqual(hit.rect.maxX,width)
                        let button = SceneActionButton(region:hit) {}
                        XCTAssertEqual(button.accessibilityValue() as? Int,choice == .label ? 1 : 0)
                    }
                    shown.statsMenuStyles[page] = .icon
                    let iconScene = WorkspaceContent.make(shown,width:width,clock:0,connection:.init(),stats:sample)
                    XCTAssertTrue(try XCTUnwrap(iconScene.hits.first { $0.action == .statsMenuStyle(page,.icon) }).checked)
                    XCTAssertEqual(on.statsCharts,off.statsCharts)
                    XCTAssertEqual(on.height,off.height)
                    let button = SceneActionButton(region:offHit) {}
                    XCTAssertEqual(button.accessibilityRole(),.checkBox)
                    XCTAssertEqual(button.accessibilityLabel(),offHit.title)
                    XCTAssertEqual(button.accessibilityValue() as? Int,0)
                    XCTAssertNil(button.window)
                    if width == 606 && (page == .cpu || page == .network) {
                        for (name,scene) in [("on",on),("off",off)] {
                            for scale in [1,2] {
                                let context = try XCTUnwrap(CGContext(data:nil,width:Int(width)*scale,height:90*scale,
                                    bitsPerComponent:8,bytesPerRow:Int(width)*scale*4,
                                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                                context.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
                                context.translateBy(x:0,y:90);context.scaleBy(x:1,y:-1)
                                context.setFillColor(VPNDrawing.color(palette.background))
                                context.fill(CGRect(x:0,y:0,width:width,height:90))
                                scene.draw(in:context)
                                let image = try XCTUnwrap(context.makeImage())
                                let png = try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
                                try png.write(to:root.appendingPathComponent(
                                    "artifacts/migration/stats-toggle-\(page.rawValue)-\(theme)-\(name)-\(scale)x.png"))
                            }
                        }
                    }
                }
            }
        }
    }

    func testStatsUpdatesAvoidWorkspaceRebuildAndHiddenPagesDoNotDraw() {
        var environment = RenderingEnvironment(windowVisible:true,occluded:false)
        let model = WorkspaceModel(backend:NoBackend())
        model.accept(state(.cpu).snapshot);model.screen = .cpu
        let view = WorkspaceView(frame:CGRect(x:0,y:0,width:960,height:720),environment:{ environment })
        var visible:StatsPage?
        view.visibilityChanged = { visible = $0 }
        view.update(model);view.layoutSubtreeIfNeeded()
        let builds = view.sceneBuilds
        let contentBuilds = view.contentBuilds
        var unrelated = SystemStatsSnapshot(); unrelated.networkDownRate = 10
        view.updateStats(unrelated)
        XCTAssertEqual(view.contentBuilds,contentBuilds)
        XCTAssertEqual(visible,.cpu)
        view.setStatsMenuVisibility([])
        var values = snapshot()
        for i in 0..<20 { values.cpu.total = Double(i)/20;view.updateStats(values) }
        XCTAssertEqual(view.sceneBuilds,builds)
        view.setStatsMenuVisibility(Set(StatsPage.allCases))
        XCTAssertEqual(view.sceneBuilds,builds)
        environment.occluded = true;view.refreshAnimation();XCTAssertNil(visible)
        values.cpu.total = 0.9;view.updateStats(values)
        XCTAssertEqual(view.sceneBuilds,builds)
        let hiddenBuilds = view.contentBuilds
        environment.occluded = false;view.refreshAnimation()
        XCTAssertEqual(view.contentBuilds,hiddenBuilds+1)
        XCTAssertNil(view.window);view.dispose()
    }

    func testChartLayersRetainPathsUntilHistoryOrThemeChanges() {
        var history = StatsHistory()
        history.add(.init(time:1,value:0.25))
        let layers = StatsChartLayers()
        var surface = StatsChartSurface(rect:CGRect(x:24,y:100,width:400,height:112),history:history,percent:true)
        layers.update(surface,palette:.light)
        let root = layers.root
        layers.update(surface,palette:.light)
        XCTAssertEqual(layers.pathUpdates,1)
        history.add(.init(time:2,value:nil,reason:"Target failed"))
        surface.history = history
        layers.update(surface,palette:.light)
        XCTAssertTrue(layers.root === root)
        XCTAssertEqual(layers.pathUpdates,2)
        XCTAssertEqual(layers.root.sublayers?.count,3)
        layers.update(surface,palette:.dark)
        XCTAssertEqual(layers.pathUpdates,3)
        XCTAssertTrue(StatsPanel.accessibilitySummary(.cpu,snapshot()).contains("Five-minute history"))
    }
    func testSummaryGeometryRetentionAndPreviews() throws {
        XCTAssertEqual(StatsFormat.bytes(UInt64(16_000_000_000)),"16 GB")
        XCTAssertEqual(StatsFormat.rate(0),"0 B/s")
        XCTAssertEqual(StatsFormat.rate(nil),"Unavailable")
        XCTAssertEqual(StatsSummarySurface.composition([0.06,0.08,0.86],total:1)!,[0.06,0.08,0.86])
        XCTAssertNil(StatsSummarySurface.composition([0.06,nil,0.86],total:1))
        XCTAssertNil(StatsSummarySurface.composition([0.06,0.08,0.80],total:1))
        XCTAssertNil(StatsSummarySurface.composition([Double.nan,0,1],total:1))
        XCTAssertNil(StatsSummarySurface.composition([0,0],total:0))
        XCTAssertNotNil(StatsSummarySurface.composition([0,1],total:1))
        XCTAssertNotNil(StatsSummarySurface.composition([0.00001,0.99999],total:1))
        let residue = try XCTUnwrap(StatsSummarySurface.composition([1.0005,0],total:1))
        XCTAssertEqual(residue.reduce(0,+),1,accuracy:0.000001)
        let layers = StatsSummaryLayers()
        var surface = StatsSummarySurface(rect:CGRect(x:0,y:0,width:558,height:150),fractions:[0.06,0.08,0.86],colors:ThemePalette.light.statsColors)
        layers.update(surface,palette:.light);layers.update(surface,palette:.light)
        XCTAssertEqual(layers.updates,1)
        let children = layers.root.sublayers!
        surface.fractions = [0.2,0.3,0.5];layers.update(surface,palette:.light)
        XCTAssertEqual(layers.updates,2);XCTAssertEqual(layers.root.sublayers?.count,10)
        XCTAssertTrue(zip(children,layers.root.sublayers!).allSatisfy { $0 === $1 })
        let retainedContext = try XCTUnwrap(CGContext(data:nil,width:558,height:150,bitsPerComponent:8,bytesPerRow:558*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        layers.root.render(in:retainedContext)
        let retainedData = try XCTUnwrap(retainedContext.data).assumingMemoryBound(to:UInt8.self)
        XCTAssertTrue((0..<(558*150)).contains { retainedData[$0*4+3] != 0 },"Retained layers must draw actual pixels")
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("artifacts/migration")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let retainedPNG = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(retainedContext.makeImage())).representation(using:.png,properties:[:]))
        try retainedPNG.write(to:output.appendingPathComponent("stats-summary-retained.png"))
        for palette in [ThemePalette.light,.dark] { for width:CGFloat in [606,766] { for scale in [1,2] { for page in StatsPage.allCases {
            let scene = WorkspaceContent.make(state(page,palette:palette),width:width,clock:0,connection:.init(),stats:snapshot())
            let height:CGFloat = page == .network ? 365 : 320
            let context = try XCTUnwrap(CGContext(data:nil,width:Int(width)*scale,height:Int(height)*scale,bitsPerComponent:8,bytesPerRow:Int(width)*scale*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x:CGFloat(scale),y:CGFloat(scale));context.translateBy(x:0,y:height);context.scaleBy(x:1,y:-1)
            context.setFillColor(VPNDrawing.color(palette.background));context.fill(CGRect(x:0,y:0,width:width,height:height))
            scene.draw(in:context)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
            try png.write(to:output.appendingPathComponent("stats-summary-\(page.rawValue)-\(palette.theme == .dark ? "dark" : "light")-\(Int(width))-\(scale)x.png"))
        } } } }
    }

    func testCPUSummaryRetainedPixels() throws {
        let output = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/migration")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for palette in [ThemePalette.light,.dark] { for width:CGFloat in [606,766] { for scale in [1,2] { for busy in [0,9,16,100] {
            var sample = snapshot()
            sample.cpu.total = Double(busy)/100; sample.cpu.system = Double(busy)/200
            sample.cpu.user = Double(busy)/200; sample.cpu.idle = 1-Double(busy)/100
            let scene = WorkspaceContent.make(state(.cpu,palette:palette),width:width,clock:0,connection:.init(),stats:sample,retainedStats:true)
            let surface = try XCTUnwrap(scene.statsSummaries.first)
            let height:CGFloat = 320, pixelWidth = Int(width)*scale
            let context = try XCTUnwrap(CGContext(data:nil,width:pixelWidth,height:Int(height)*scale,bitsPerComponent:8,bytesPerRow:pixelWidth*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x:CGFloat(scale),y:CGFloat(scale));context.translateBy(x:0,y:height);context.scaleBy(x:1,y:-1)
            context.setFillColor(VPNDrawing.color(palette.background));context.fill(CGRect(x:0,y:0,width:width,height:height));scene.draw(in:context)
            let layers = StatsSummaryLayers();layers.update(surface,palette:palette)
            context.saveGState();context.translateBy(x:surface.rect.minX,y:surface.rect.maxY);context.scaleBy(x:1,y:-1);layers.root.render(in:context);context.restoreGState()
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
            try png.write(to:output.appendingPathComponent("stats-cpu-retained-\(palette.theme == .dark ? "dark" : "light")-\(Int(width))-\(scale)x-\(busy).png"))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
            func pixel(_ x:Int,_ y:Int) -> (Int,Int,Int) { let i = (y*pixelWidth+x)*4;return (Int(pixels[i]),Int(pixels[i+1]),Int(pixels[i+2])) }
            func ink(in rect:CGRect,color:UInt32) -> Int {
                let rgb = (Int((color>>16)&255),Int((color>>8)&255),Int(color&255))
                var n = 0
                for y in Int(rect.minY*CGFloat(scale))..<Int(rect.maxY*CGFloat(scale)) { for x in Int(rect.minX*CGFloat(scale))..<Int(rect.maxX*CGFloat(scale)) {
                    let p = pixel(x,y);if abs(p.0-rgb.0)<20 && abs(p.1-rgb.1)<20 && abs(p.2-rgb.2)<20 { n += 1 }
                } };return n
            }
            let left = surface.rect.minX+124, available = surface.rect.width-140
            for (index,colorIndex) in [1,0,3].enumerated() {
                let x = left+CGFloat(index)*available/3
                XCTAssertGreaterThan(ink(in:CGRect(x:x,y:surface.rect.minY+82,width:9,height:9),color:palette.statsColors[colorIndex]),10*scale*scale,"legend \(index)")
                XCTAssertGreaterThan(ink(in:CGRect(x:x+14,y:surface.rect.minY+80,width:available/3-16,height:14),color:palette.text),5*scale*scale,"legend text \(index)")
            }
            let center = CGPoint(x:surface.rect.minX+60,y:surface.rect.minY+68)
            // Check the painted ring around the same center used for the glyphs.
            for offset in [CGPoint(x:0,y:-39),CGPoint(x:39,y:0),CGPoint(x:0,y:39),CGPoint(x:-39,y:0)] {
                let patch = CGRect(x:center.x+offset.x-2,y:center.y+offset.y-2,width:4,height:4)
                XCTAssertTrue([1,0,3].contains { ink(in:patch,color:palette.statsColors[$0]) >= 2*scale*scale },"ring at \(offset)")
            }
            let textColor = palette.text
            var xs:[Int] = [],ys:[Int] = []
            let rect = CGRect(x:center.x-37,y:center.y-25,width:74,height:50)
            let rgb = (Int((textColor>>16)&255),Int((textColor>>8)&255),Int(textColor&255))
            for y in Int(rect.minY*CGFloat(scale))..<Int(rect.maxY*CGFloat(scale)) { for x in Int(rect.minX*CGFloat(scale))..<Int(rect.maxX*CGFloat(scale)) {
                let p = pixel(x,y);if abs(p.0-rgb.0)<30 && abs(p.1-rgb.1)<30 && abs(p.2-rgb.2)<30 { xs.append(x);ys.append(y) }
            } }
            let midX = CGFloat(try XCTUnwrap(xs.min())+XCTUnwrap(xs.max())+1)/2/CGFloat(scale)
            let midY = CGFloat(try XCTUnwrap(ys.min())+XCTUnwrap(ys.max())+1)/2/CGFloat(scale)
            XCTAssertEqual(midX,center.x,accuracy:1.5);XCTAssertEqual(midY,center.y,accuracy:1.5)
        } } } }
    }

    func testNetworkSummaryCenteredRetainedPixels() throws {
        let output = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("artifacts/migration")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let values:[(String,Double?)] = [("zero",0),("6_3kb",6300),("12kb",12000),("999kb",999000),("1mb",1000000),("999gb",999000000000),("1tb",1000000000000),("large",1000000000000000),("unavailable",nil)]
        for palette in [ThemePalette.light,.dark] { for width:CGFloat in [606,766] { for scale in [1,2] { for (name,rate) in values {
            var sample = snapshot();sample.networkDownRate = rate;sample.networkUpRate = rate
            // Network summary is drawn by the production scene even when history uses retained layers.
            let scene = WorkspaceContent.make(state(.network,palette:palette),width:width,clock:0,connection:.init(),stats:sample,retainedStats:true)
            XCTAssertTrue(StatsPanel.accessibilitySummary(.network,sample).contains(StatsFormat.rate(rate)))
            let height:CGFloat = 340, pixelWidth = Int(width)*scale
            let context = try XCTUnwrap(CGContext(data:nil,width:pixelWidth,height:Int(height)*scale,bitsPerComponent:8,bytesPerRow:pixelWidth*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x:CGFloat(scale),y:CGFloat(scale));context.translateBy(x:0,y:height);context.scaleBy(x:1,y:-1)
            context.setFillColor(VPNDrawing.color(palette.background));context.fill(CGRect(x:0,y:0,width:width,height:height));scene.draw(in:context)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage())).representation(using:.png,properties:[:]))
            try png.write(to:output.appendingPathComponent("stats-network-retained-\(palette.theme == .dark ? "dark" : "light")-\(Int(width))-\(scale)x-\(name).png"))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
            let rgb = (Int((palette.surface>>16)&255),Int((palette.surface>>8)&255),Int(palette.surface&255))
            func bounds(_ rect:CGRect) throws -> (CGFloat,CGFloat,CGFloat,CGFloat,[Int]) {
                var xs:[Int] = [],ys:[Int] = []
                for y in Int(rect.minY*CGFloat(scale))..<Int(rect.maxY*CGFloat(scale)) { for x in Int(rect.minX*CGFloat(scale))..<Int(rect.maxX*CGFloat(scale)) {
                    let i = (y*pixelWidth+x)*4
                    if max(abs(Int(pixels[i])-rgb.0),abs(Int(pixels[i+1])-rgb.1),abs(Int(pixels[i+2])-rgb.2)) > 35 { xs.append(x);ys.append(y) }
                } }
                return (CGFloat(try XCTUnwrap(xs.min()))/CGFloat(scale),CGFloat(try XCTUnwrap(xs.max())+1)/CGFloat(scale),CGFloat(try XCTUnwrap(ys.min()))/CGFloat(scale),CGFloat(try XCTUnwrap(ys.max())+1)/CGFloat(scale),xs)
            }
            let card = CGRect(x:24,y:199,width:width-48,height:120)
            for index in 0..<2 {
                let column = CGRect(x:card.minX+CGFloat(index)*card.width/2,y:card.minY,width:card.width/2,height:card.height)
                let value = try bounds(CGRect(x:column.minX+8,y:card.minY+20,width:column.width-16,height:43))
                let label = try bounds(CGRect(x:column.minX+8,y:card.minY+63,width:column.width-16,height:37))
                let message = "\(name) \(palette.theme) \(width) \(scale)x column \(index)"
                XCTAssertEqual((value.0+value.1)/2,column.midX,accuracy:2,message)
                XCTAssertEqual((label.0+label.1)/2,column.midX,accuracy:2,message)
                let swatch = palette.statsColors[index]
                let expected = (Int((swatch>>16)&255),Int((swatch>>8)&255),Int(swatch&255))
                var colored = 0
                for py in Int((card.minY+63)*CGFloat(scale))..<Int((card.minY+100)*CGFloat(scale)) {
                    for px in Int((column.minX+8)*CGFloat(scale))..<Int((column.maxX-8)*CGFloat(scale)) {
                        let i = (py*pixelWidth+px)*4
                        if abs(Int(pixels[i])-expected.0)<20 && abs(Int(pixels[i+1])-expected.1)<20 && abs(Int(pixels[i+2])-expected.2)<20 { colored += 1 }
                    }
                }
                XCTAssertGreaterThan(colored,10*scale*scale,message)
                XCTAssertGreaterThan(value.0,column.minX+10,message);XCTAssertLessThan(value.1,column.maxX-10,message)
                XCTAssertGreaterThan(label.0,column.minX+10,message);XCTAssertLessThan(label.1,column.maxX-10,message)
                XCTAssertLessThan(label.2-value.3,12,message)
                XCTAssertEqual((value.2+label.3)/2,card.midY,accuracy:5,message)
                if rate != nil {
                    let occupied = Set(value.4), minX = try XCTUnwrap(value.4.min()),maxX = try XCTUnwrap(value.4.max())
                    var gap = 0, longest = 0
                    for x in minX...maxX { if occupied.contains(x) { gap = 0 } else { gap += 1;longest = max(longest,gap) } }
                    XCTAssertLessThanOrEqual(CGFloat(longest)/CGFloat(scale),9,message)
                }
            }
        } } } }
    }

}
