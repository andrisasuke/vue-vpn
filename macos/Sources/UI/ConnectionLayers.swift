import AppKit
import QuartzCore

/// Retained artwork. Only compositor properties animate; no application timer,
/// layout, font creation or bitmap generation is needed for animation frames.
@MainActor final class ConnectionLayers {
    let root = CALayer()
    private let base = CALayer(),indicator = CALayer(),button = CALayer()
    private let network = CALayer(),networkBackground = CALayer(),foreground = CALayer()
    private let traffic = CALayer(),statistics = CALayer(),duration = CALayer(),halo = CALayer()
    private let lines = CAShapeLayer(),outerHalo = CAShapeLayer(),innerHalo = CAShapeLayer()
    private var state:ConnectionPresentation?
    private var palette:ThemePalette = .light
    private var size = CGSize.zero
    private var scale:CGFloat = 0
    private var feedback = WorkspaceScene.Feedback()
    private var running = false
    private var reduceMotion = false
    private var epoch:CFTimeInterval = 0
    private(set) var rasterizations = 0
    private(set) var staticBuilds = 0
    private(set) var metricBuilds = 0
    var animationRunning:Bool { running }

    init() {
        root.isGeometryFlipped = true;root.speed = 0
        for layer in [base,indicator,button,network,statistics,duration] { root.addSublayer(layer) }
        for layer in [networkBackground,lines,halo,foreground,traffic] { network.addSublayer(layer) }
        halo.addSublayer(outerHalo);halo.addSublayer(innerHalo)
        network.opacity = 0.85;network.allowsGroupOpacity = true;network.masksToBounds = true
        lines.fillColor = nil;lines.lineCap = .round;lines.opacity = Float(0.9)
        for layer in [root,base,indicator,button,network,networkBackground,foreground,traffic,statistics,duration,halo,lines,outerHalo,innerHalo] {
            layer.actions = ["contents":NSNull(),"bounds":NSNull(),"position":NSNull(),"path":NSNull(),"opacity":NSNull(),"transform":NSNull()]
        }
    }

    func update(_ next:ConnectionPresentation,size:CGSize,palette:ThemePalette,scale:CGFloat,epoch:CFTimeInterval) {
        let scale = max(1,scale)
        var appearance = next;appearance.duration = "";appearance.bytesIn = 0;appearance.bytesOut = 0
        appearance.phase = 0;appearance.reduceMotion = false
        var previous = state;previous?.duration = "";previous?.bytesIn = 0;previous?.bytesOut = 0
        previous?.phase = 0;previous?.reduceMotion = false
        let rebuild = previous != appearance || self.size != size || self.palette != palette || self.scale != scale
        let trafficChanged = rebuild || state?.bytesIn != next.bytesIn || state?.bytesOut != next.bytesOut
        let durationChanged = rebuild || state?.duration != next.duration
        let animationChanged = state?.status != next.status || self.epoch != epoch || reduceMotion != next.reduceMotion || rebuild
        self.size = size;self.palette = palette;self.scale = scale;self.epoch = epoch;state = next
        reduceMotion = next.reduceMotion
        CATransaction.begin();CATransaction.setDisableActions(true)
        if rebuild {
            staticBuilds += 1
            root.bounds = CGRect(origin:.zero,size:size)
            for layer in [root,lines,halo,outerHalo,innerHalo] { layer.contentsScale = scale }
            let height = ConnectionPanel.bodyHeight(next,width:size.width)
            paint(base,part:.base,rect:root.bounds)
            paint(indicator,part:.indicator,rect:CGRect(x:20,y:29,width:15,height:15))
            paintButton()
            paint(statistics,part:.statistics,rect:CGRect(x:1,y:height+1,width:size.width-2,height:58))
            network.frame = CGRect(x:size.width-211,y:1,width:210,height:height)
            paint(networkBackground,part:.networkBackground,rect:network.frame,localTo:network.frame.origin)
            paint(foreground,part:.networkForeground,rect:network.frame,localTo:network.frame.origin)
            var transform = ConnectionArtwork.networkTransform(height:height)
            lines.frame = network.bounds
            lines.path = ConnectionArtwork.linePath().copy(using:&transform)
            lines.lineWidth = CGFloat(Float(1.4))*transform.a
            lines.lineDashPattern = [NSNumber(value:Double(6*transform.a)),NSNumber(value:Double(6*transform.a))]
            lines.strokeColor = VPNDrawing.color(next.status.active ? palette[.networkLine,light:0x588547] : palette[.networkRing,light:0x829d6e])
            halo.bounds = CGRect(x:0,y:0,width:110,height:110)
            halo.position = CGPoint(x:105,y:(height-56)/2)
            halo.setAffineTransform(CGAffineTransform(rotationAngle:-7 * .pi/180))
            for layer in [outerHalo,innerHalo] { layer.frame = halo.bounds }
            outerHalo.fillColor = VPNDrawing.color(palette[.border,light:0xdbe5ce])
            innerHalo.fillColor = VPNDrawing.color(palette[.raised,light:0xffffff])
        }
        if trafficChanged || durationChanged {
            metricBuilds += 1
            let height = ConnectionPanel.bodyHeight(next,width:size.width)
            if trafficChanged { paint(traffic,part:.traffic,rect:CGRect(x:size.width-211,y:height-53,width:210,height:54),localTo:network.frame.origin) }
            if durationChanged {
                let column = floor((size.width-48)/3*64)/64
                paint(duration,part:.duration,rect:CGRect(x:41+column,y:height+27,width:column-18,height:20))
            }
        }
        if animationChanged { configureAnimations() }
        CATransaction.commit()
    }

    func setFeedback(_ feedback:WorkspaceScene.Feedback) {
        guard feedback.hovered != self.feedback.hovered || feedback.pressed != self.feedback.pressed else { return }
        self.feedback = feedback
        CATransaction.begin();CATransaction.setDisableActions(true);paintButton();CATransaction.commit()
    }
    private func paintButton() {
        guard let state else { return }
        if state.buttonDisabled { feedback = .init() }
        paint(button,part:.button,rect:ConnectionPanel.buttonRect(state,width:size.width).insetBy(dx:-12,dy:-12))
    }
    private func paint(_ layer:CALayer,part:ConnectionParts,rect:CGRect,localTo origin:CGPoint = .zero) {
        guard var state else { return }
        state.phase = 0;state.reduceMotion = true
        guard let image = Self.raster(size:rect.size,scale:scale,draw:{ context in
            context.translateBy(x:-rect.minX,y:-rect.minY)
            ConnectionPanel.draw(state,in:CGRect(origin:.zero,size:self.size),context:context,feedback:self.feedback,
                palette:self.palette,parts:part,networkOpacity:1)
        }) else { return }
        rasterizations += 1
        layer.frame = rect.offsetBy(dx:-origin.x,dy:-origin.y)
        layer.contentsScale = scale;layer.contents = image
    }

    static func raster(size:CGSize,scale:CGFloat,draw:(CGContext)->Void) -> CGImage? {
        let width = Int(ceil(size.width*scale)),height = Int(ceil(size.height*scale))
        guard width > 0,height > 0,width <= 16384,height <= 16384,
              width*height*4 <= 32*1024*1024,
              let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x:scale,y:scale);ctx.translateBy(x:0,y:CGFloat(height)/scale);ctx.scaleBy(x:1,y:-1)
        draw(ctx);return ctx.makeImage()
    }

    func hasVisibleAnimation(in topLeftRect:CGRect) -> Bool {
        guard let state,state.status.active else { return false }
        let networkArt = CGRect(x:size.width-211,y:1,width:210,height:network.bounds.height-56)
        let indicatorArt = CGRect(x:20,y:29,width:15,height:15)
        return topLeftRect.intersects(networkArt) || (state.status != .connected && topLeftRect.intersects(indicatorArt))
    }

    func setRunning(_ requested:Bool,now:CFTimeInterval = CACurrentMediaTime()) {
        let next = requested && state?.status.active == true && !reduceMotion
        guard running != next else { return }
        running = next
        CATransaction.begin();CATransaction.setDisableActions(true)
        if next {
            root.speed = 1;root.timeOffset = 0;root.beginTime = 0
        } else {
            // Freeze at the current phase. Resume uses the monotonic connection
            // epoch, never replays work for frames elapsed while invisible.
            root.timeOffset = root.convertTime(now,from:nil);root.speed = 0
        }
        CATransaction.commit()
    }

    private func configureAnimations() {
        for layer in [lines,outerHalo,innerHalo,indicator] { layer.removeAllAnimations() }
        setPhase(0)
        guard let state,state.status.active,!reduceMotion else { return }
        let transform = ConnectionArtwork.networkTransform(height:network.bounds.height)
        let dash = CABasicAnimation(keyPath:"lineDashPhase")
        dash.fromValue = 0;dash.toValue = -24*transform.a;dash.duration = 1.4
        repeatAnimation(dash,on:lines,key:"flow")
        if state.status != .connected {
            let pulse = keyframes("opacity",values:[1,0.3,1],duration:1,easeInOut:false)
            repeatAnimation(pulse,on:indicator,key:"pulse")
            for (layer,inner) in [(outerHalo,false),(innerHalo,true)] {
                let breathe = keyframes("path",values:[ConnectionArtwork.haloPath(inner:inner,spread:0),ConnectionArtwork.haloPath(inner:inner,spread:7),ConnectionArtwork.haloPath(inner:inner,spread:0)],duration:1.5,easeInOut:true)
                repeatAnimation(breathe,on:layer,key:"breathe")
            }
            repeatAnimation(keyframes("opacity",values:[96.0/255,48.0/255,96.0/255],duration:1.5,easeInOut:true),on:innerHalo,key:"fade")
        }
    }
    private func repeatAnimation(_ animation:CAAnimation,on layer:CALayer,key:String) {
        animation.repeatCount = .infinity
        animation.beginTime = epoch
        layer.add(animation,forKey:key)
    }
    private func keyframes(_ property:String,values:[Any],duration:Double,easeInOut:Bool) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath:property)
        animation.values = values;animation.keyTimes = [0,0.5,1];animation.duration = duration
        let curve = easeInOut ? CAMediaTimingFunction(controlPoints:0.42,0,0.58,1) : CAMediaTimingFunction(controlPoints:0.25,0.1,0.25,1)
        animation.timingFunctions = [curve,curve];return animation
    }

    /// The same model-layer values make deterministic offscreen frames possible
    /// without opening a window or starting the application event loop.
    func setPhase(_ phase:Double) {
        let active = state?.status.active == true && !reduceMotion
        let transitioning = active && state?.status != .connected
        let spread:CGFloat = transitioning ? 7*AnimationTiming.keyframeProgress(elapsed:phase,duration:1.5,easeInOut:true) : 0
        let transform = ConnectionArtwork.networkTransform(height:network.bounds.height)
        lines.lineDashPhase = active ? -24*CGFloat(phase.truncatingRemainder(dividingBy:1.4))/1.4*transform.a : 0
        indicator.opacity = transitioning ? Float(1-0.7*AnimationTiming.keyframeProgress(elapsed:phase,duration:1,easeInOut:false)) : 1
        outerHalo.path = ConnectionArtwork.haloPath(inner:false,spread:spread)
        innerHalo.path = ConnectionArtwork.haloPath(inner:true,spread:spread)
        innerHalo.opacity = Float((96-spread*48/7)/255)
    }
}

@MainActor final class ConnectionPanelView:NSView {
    let artwork = ConnectionLayers()
    override var isFlipped:Bool { true }
    var hasVisibleAnimation:Bool { artwork.hasVisibleAnimation(in:visibleRect) }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        // The AppKit backing layer supplies the top-left coordinate system.
        // The standalone root only flips geometry when rendered independently.
        artwork.root.isGeometryFlipped = false
        layer?.addSublayer(artwork.root)
    }
    required init?(coder:NSCoder) { fatalError("Programmatic panel") }
    func update(_ state:ConnectionPresentation,palette:ThemePalette,epoch:CFTimeInterval) {
        artwork.root.frame = bounds
        artwork.update(state,size:bounds.size,palette:palette,scale:window?.backingScaleFactor ?? 2,epoch:epoch)
    }
}
