import AppKit

@MainActor
final class ToastView:NSView {
    private var palette:ThemePalette = .light
    func applyTheme(_ palette:ThemePalette) { self.palette = palette;needsDisplay = true }
    private var message = ""
    private var requestedMessage = ""
    private var visible = false
    private var generation = 0
    private var layoutBounds = CGRect.zero
    override var isFlipped:Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer = true;isHidden = true
        setAccessibilityRole(.staticText)
    }
    required init?(coder:NSCoder) { fatalError("Programmatic native toast") }

    func update(_ text:String,in bounds:CGRect) {
        guard requestedMessage != text || layoutBounds != bounds else { return }
        layoutBounds = bounds
        let changed = requestedMessage != text
        requestedMessage = text
        if !text.isEmpty { message = text }
        let width = min(bounds.width-32,ceil(VPNDrawing.textWidth(message,size:12,weight:400))+36)
        let lines = VPNDrawing.wrappedLines(message,width:width-36,size:12,weight:400)
        let height = CGFloat(lines.count)*18+24
        let restingFrame = CGRect(x:(bounds.width-width)/2-32,y:bounds.height-25-height-32,width:width+64,height:height+64)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let targetFrame = restingFrame.offsetBy(dx:0,dy:text.isEmpty && !reduceMotion ? 15 : 0)
        needsDisplay = true
        setAccessibilityValue(message)
        guard changed || visible != !text.isEmpty else { frame = targetFrame;return }
        generation += 1;let current = generation
        visible = !text.isEmpty
        if visible && isHidden {
            frame = restingFrame.offsetBy(dx:0,dy:reduceMotion ? 0 : 15)
            alphaValue = 0;isHidden = false
        }
        let duration = reduceMotion ? 0 : 0.2
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints:0.25,0.1,0.25,1)
            self.animator().alphaValue = self.visible ? 1 : 0
            self.animator().frame = targetFrame
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,self.generation == current else { return }
                if !self.visible { self.isHidden = true;self.message = "" }
            }
        }
        if visible { NSAccessibility.post(element:self,notification:.valueChanged) }
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx:32,dy:32)
        VPNDrawing.shadow(rect,radius:11,blur:30,offset:CGSize(width:0,height:10),color:palette[.shadow, light:0x19351c],alpha:37.0/255,in:ctx)
        VPNDrawing.rounded(rect,radius:11,fill:palette[.toast, light:0x233b2e],in:ctx)
        for (i,line) in VPNDrawing.wrappedLines(message,width:rect.width-36,size:12,weight:400).enumerated() {
            VPNDrawing.text(line,in:ctx,at:CGPoint(x:rect.minX+18,y:rect.minY+25+CGFloat(i)*18),size:12,weight:400,color:palette[.toastText, light:0xf0f6e6])
        }
    }
}
