import AppKit

struct StatsChartSurface: Equatable {
    var rect: CGRect
    var history: StatsHistory
    var percent: Bool
}

/// Fixed pair of vector paths per chart. The workspace canvas keeps these
/// layers through value changes, resizing, and page redraws.
@MainActor final class StatsChartLayers {
    let root = CALayer()
    private let primary = CAShapeLayer()
    private let secondary = CAShapeLayer()
    private let failures = CAShapeLayer()
    private var last: StatsChartSurface?
    private var lastPalette: ThemePalette?
    private(set) var pathUpdates = 0
    init() {
        root.isGeometryFlipped = true
        root.masksToBounds = true
        root.cornerRadius = 9
        for layer in [primary,secondary,failures] {
            layer.fillColor = nil;layer.lineWidth = 2
            layer.lineJoin = .round;layer.lineCap = .round
            root.addSublayer(layer)
        }
    }
    func update(_ surface:StatsChartSurface,palette:ThemePalette) {
        guard surface != last || palette != lastPalette else { return }
        root.frame = surface.rect
        primary.frame = CGRect(origin:.zero,size:surface.rect.size)
        secondary.frame = primary.frame
        failures.frame = primary.frame
        primary.strokeColor = VPNDrawing.color(palette.accent)
        secondary.strokeColor = VPNDrawing.color(palette.warning)
        failures.strokeColor = VPNDrawing.color(palette.warning)
        failures.lineWidth = 3
        let points = surface.history.points
        guard let last = points.last else {
            primary.path = nil;secondary.path = nil;failures.path = nil
            self.last = surface;lastPalette = palette;pathUpdates += 1;return
        }
        let maximum = surface.percent ? 1 : max(1,points.compactMap(\.value).max() ?? 0,points.compactMap(\.second).max() ?? 0)
        for (index,layer) in [primary,secondary].enumerated() {
            let path = CGMutablePath()
            var drawing = false
            for point in points {
                guard let value = index == 0 ? point.value : point.second else { drawing = false;continue }
                let px = surface.rect.width-CGFloat((last.time-point.time)/300)*surface.rect.width
                let py = surface.rect.height-4-CGFloat(min(1,max(0,value/maximum)))*(surface.rect.height-8)
                if drawing { path.addLine(to:CGPoint(x:px,y:py)) } else { path.move(to:CGPoint(x:px,y:py));drawing = true }
            }
            layer.path = path
        }
        let markers = CGMutablePath()
        for point in points where point.reason == "Target failed" {
            let px = surface.rect.width-CGFloat((last.time-point.time)/300)*surface.rect.width
            markers.move(to:CGPoint(x:px,y:surface.rect.height-15))
            markers.addLine(to:CGPoint(x:px,y:surface.rect.height-4))
        }
        failures.path = markers
        self.last = surface;lastPalette = palette;pathUpdates += 1
    }
}


/// Shared, bounded composition geometry. An incomplete or inconsistent sample
/// is represented by the neutral track; a 0.1% residue is rounding tolerance.
struct StatsSummarySurface: Equatable {
    var rect: CGRect
    var fractions: [Double]?
    var colors: [UInt32]
    static func composition(_ values: [Double?], total: Double?) -> [Double]? {
        guard let total, total.isFinite, total > 0, values.allSatisfy({ $0 != nil && $0!.isFinite && $0! >= 0 }) else { return nil }
        let numbers = values.map { $0! }
        let sum = numbers.reduce(0,+)
        guard abs(sum-total) <= total * 0.001 else { return nil }
        var result = numbers.map { $0 / total }
        let residue = 1-result.reduce(0,+)
        if let index = result.indices.reversed().first(where: { result[$0] + residue >= 0 }) { result[index] += residue }
        else { return nil }
        return result
    }
    func paths() -> [CGPath] {
        let ring = CGRect(x:rect.minX+16,y:rect.minY+24,width:88,height:88)
        let bar = CGRect(x:rect.minX+124,y:rect.minY+57,width:max(0,rect.width-140),height:12)
        var result: [CGPath] = []
        var start = -CGFloat.pi/2, offset: CGFloat = 0
        for value in fractions ?? [] {
            let amount = CGFloat(value), arc = CGMutablePath()
            arc.addArc(center:CGPoint(x:ring.midX,y:ring.midY),radius:39,startAngle:start,endAngle:start+amount*2*CGFloat.pi,clockwise:false)
            result.append(arc.copy(strokingWithWidth:10,lineCap:.butt,lineJoin:.miter,miterLimit:10))
            start += amount*2*CGFloat.pi
            let segment = CGPath(rect:CGRect(x:bar.minX+offset*bar.width,y:bar.minY,width:amount*bar.width,height:bar.height),transform:nil)
            result.append(segment); offset += amount
        }
        return result
    }
    func draw(in context: CGContext, palette: ThemePalette) {
        let ring = CGRect(x:rect.minX+21,y:rect.minY+29,width:78,height:78)
        let bar = CGRect(x:rect.minX+124,y:rect.minY+57,width:max(0,rect.width-140),height:12)
        context.setStrokeColor(VPNDrawing.color(palette.statsColors[3])); context.setLineWidth(10); context.strokeEllipse(in:ring)
        VPNDrawing.rounded(bar,radius:6,fill:palette.statsColors[3],in:context)
        for (index,path) in paths().enumerated() {
            context.saveGState()
            if index % 2 == 1 { context.addPath(CGPath(roundedRect:bar,cornerWidth:6,cornerHeight:6,transform:nil)); context.clip() }
            context.addPath(path);context.setFillColor(VPNDrawing.color(colors[index/2]));context.fillPath()
            context.restoreGState()
        }
    }
}

@MainActor final class StatsSummaryLayers {
    let root = CALayer()
    private let track = CAShapeLayer()
    private let barTrack = CAShapeLayer()
    private let segments = (0..<8).map { _ in CAShapeLayer() }
    private let masks = (0..<4).map { _ in CAShapeLayer() }
    private var last: StatsSummarySurface?
    private var lastPalette: ThemePalette?
    private(set) var updates = 0
    init() {
        root.isGeometryFlipped = true
        for layer in [track,barTrack] + segments { root.addSublayer(layer) }
        for index in 0..<4 { segments[index*2+1].mask = masks[index] }
    }
    func update(_ surface: StatsSummarySurface, palette: ThemePalette) {
        guard surface != last || palette != lastPalette else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = surface.rect
        for layer in [track,barTrack] + segments { layer.frame = root.bounds }
        var local = surface; local.rect.origin = .zero
        let ring = CGRect(x:21,y:29,width:78,height:78)
        let bar = CGRect(x:124,y:57,width:max(0,surface.rect.width-140),height:12)
        // Shape-layer paths are painted in the layer's unflipped coordinates,
        // while the scene and the parent view use a top-left origin.
        var flip = CGAffineTransform(translationX:0,y:surface.rect.height).scaledBy(x:1,y:-1)
        track.path = CGPath(ellipseIn:ring,transform:&flip);track.fillColor = nil;track.strokeColor = VPNDrawing.color(palette.statsColors[3]);track.lineWidth = 10
        barTrack.path = CGPath(roundedRect:bar,cornerWidth:6,cornerHeight:6,transform:&flip);barTrack.fillColor = VPNDrawing.color(palette.statsColors[3])
        let paths = local.paths()
        for (index,layer) in segments.enumerated() {
            layer.path = index < paths.count ? paths[index].copy(using:&flip) : nil
            layer.fillColor = index < paths.count ? VPNDrawing.color(surface.colors[index/2]) : nil
            if index % 2 == 1 {
                let mask = masks[index/2];mask.frame = root.bounds;mask.path = barTrack.path
            }
        }
        CATransaction.commit();last = surface;lastPalette = palette;updates += 1
    }
}
