import AppKit

struct ConnectionPresentation: Equatable {
    var status: SessionStatus = .disconnected
    var authKind: AuthKind = .pin
    var buttonDisabled = false
    var disconnectStalled = false
    var address = ""
    var duration = "—"
    var transport = "UDP"
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var phase: Double = 0
    var reduceMotion = false

    var heading: [String] {
        if status == .connected { return ["Your workspace.", "Within reach."] }
        if status.active { return ["Bringing your", "network closer."] }
        return ["Your workspace.", "One connection away."]
    }
    var description: String {
        status == .connected ? "Connected securely to your private network." : authKind == .pin ?
        "A familiar network, wherever you are. Connect with your profile PIN." : "Connect securely with your OpenVPN profile."
    }
    var buttonLabel: String {
        if disconnectStalled && !buttonDisabled { return "Retry disconnect" }
        return switch status {
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        default: status.active ? "Disconnect" : "Connect to VPN"
        }
    }
    var statusLabel: String { disconnectStalled ? "Disconnect stalled" : status.label }
}

struct ConnectionParts:OptionSet {
    let rawValue:Int
    static let base = Self(rawValue:1<<0)
    static let indicator = Self(rawValue:1<<1)
    static let button = Self(rawValue:1<<2)
    static let networkBackground = Self(rawValue:1<<3)
    static let lines = Self(rawValue:1<<4)
    static let halo = Self(rawValue:1<<5)
    static let networkForeground = Self(rawValue:1<<6)
    static let traffic = Self(rawValue:1<<7)
    static let statistics = Self(rawValue:1<<8)
    static let duration = Self(rawValue:1<<9)
    static let network:Self = [.networkBackground,.lines,.halo,.networkForeground,.traffic]
    static let all:Self = [.base,.indicator,.button,.network,.statistics,.duration]
}

/// Shared geometry for immediate-mode image comparisons and retained layers.
enum ConnectionArtwork {
    static let endpoints = [CGPoint(x:32,y:55),CGPoint(x:303,y:55),CGPoint(x:32,y:199),CGPoint(x:303,y:199)]
    static func linePath() -> CGPath {
        let path = CGMutablePath()
        for point in endpoints { path.move(to:point);path.addLine(to:CGPoint(x:167,y:127)) }
        return path
    }
    static func networkTransform(height:CGFloat) -> CGAffineTransform {
        let visualHeight = height-56,scale = min(194/335.0,visualHeight/254)
        return CGAffineTransform(translationX:8+(194-335*scale)/2,y:(visualHeight-254*scale)/2).scaledBy(x:scale,y:scale)
    }
    static func haloPath(inner:Bool,spread:CGFloat) -> CGPath {
        let inset:CGFloat = inner ? 10 : 11
        return CGPath(roundedRect:CGRect(x:22,y:22,width:66,height:66).insetBy(dx:-inset-spread,dy:-inset-spread),
            cornerWidth:21+inset+spread,cornerHeight:21+inset+spread,transform:nil)
    }
}

@MainActor enum ConnectionPanel {
    static func bodyHeight(_ state: ConnectionPresentation, width: CGFloat) -> CGFloat {
        let copyWidth = min(320, max(1, width - 2 - 210 - 23))
        let lines = VPNDrawing.wrappedLines(state.description, width: copyWidth, size: 10, weight: 400)
        return max(218, 22 + 21 + 12 + 60 + 10 + CGFloat(lines.count) * 17 + 16 + 40 + 21)
    }

    static func height(_ state: ConnectionPresentation, width: CGFloat) -> CGFloat { bodyHeight(state, width: width) + 60 }

    static func buttonRect(_ state: ConnectionPresentation, width: CGFloat) -> CGRect {
        let h = bodyHeight(state, width: width)
        let textWidth = VPNDrawing.textWidth(state.buttonLabel, size: 11, weight: 550)
        return CGRect(x: 24, y: 1 + h - 61, width: ceil((textWidth + 59) * 64) / 64, height: 40)
    }

    static func draw(_ state: ConnectionPresentation, in rect: CGRect, context: CGContext,feedback:WorkspaceScene.Feedback = .init(),palette:ThemePalette = .light,parts:ConnectionParts = .all,networkOpacity:CGFloat = 0.85) {
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        let bounds = CGRect(origin: .zero, size: rect.size)
        if parts.contains(.base) { VPNDrawing.rounded(bounds, radius: 18, fill: palette[.connection, light:0xf0f4e9], border: palette[.border, light:0xdee5d4], in: context) }
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 17, cornerHeight: 17, transform: nil))
        context.clip()
        let bodyHeight = bodyHeight(state, width: rect.width)
        let online = state.status == .connected
        let transitioning = state.status.active && !online
        if parts.contains(.indicator) {
        context.saveGState()
        if transitioning && !state.reduceMotion {
            context.setAlpha(1 - 0.7 * AnimationTiming.keyframeProgress(elapsed:state.phase,duration:1,easeInOut:false))
        }
        if online {
            context.setFillColor(VPNDrawing.color(palette[.accent, light:0x4e9853], alpha: 21.0/255))
            context.fillEllipse(in: CGRect(x: 21, y: 30.5, width: 12, height: 12))
        }
        context.setFillColor(VPNDrawing.color(online ? palette[.accent, light:0x448747] : palette[.secondaryText, light:0x8d9982]))
        context.fillEllipse(in: CGRect(x: 24, y: 33.5, width: 6, height: 6))
        context.restoreGState()
        }
        if parts.contains(.base) {
        VPNDrawing.text(state.statusLabel.uppercased(), in: context, at: CGPoint(x: 37, y: 40),
                        size: 9, weight: 650, tracking: 1.2, color: online ? palette[.accent, light:0x2e7846] : palette[.secondaryText, light:0x76856a])
        for (i, line) in state.heading.enumerated() {
            VPNDrawing.text(line, in: context, at: CGPoint(x: 24, y: 81 + i * 30), size: 27, weight: 580, tracking: -1,color:palette.text)
        }
        let lines = VPNDrawing.wrappedLines(state.description, width: min(320, max(1, rect.width - 235)), size: 10, weight: 400)
        for (i, line) in lines.enumerated() {
            VPNDrawing.text(line, in: context, at: CGPoint(x: 24, y: 138 + i * 17), size: 10, weight: 400, color: palette[.secondaryText, light:0x7c8870])
        }
        }
        if parts.contains(.button) { button(state, rect: buttonRect(state, width: rect.width), context: context,feedback:feedback,palette:palette) }
        if !parts.intersection(.network).isEmpty { network(state, rect: CGRect(x: rect.width - 211, y: 1, width: 210, height: bodyHeight), context: context,palette:palette,parts:parts,opacity:networkOpacity) }
        if !parts.intersection([.statistics,.duration]).isEmpty { statistics(state, rect: CGRect(x: 1, y: bodyHeight + 1, width: rect.width - 2, height: 58), context: context,palette:palette,parts:parts) }
    }

    private static func button(_ state: ConnectionPresentation, rect: CGRect, context: CGContext,feedback:WorkspaceScene.Feedback,palette:ThemePalette) {
        context.saveGState(); defer { context.restoreGState() }
        if !state.buttonDisabled && feedback.pressed { context.translateBy(x:0,y:1) }
        if state.buttonDisabled { context.setAlpha(0.5); context.beginTransparencyLayer(auxiliaryInfo: nil) }
        let scale = hypot(context.ctm.a, context.ctm.b)
        let painted = CGRect(x: (rect.minX*scale).rounded()/scale, y: (rect.minY*scale).rounded()/scale,
                             width: (rect.maxX*scale).rounded()/scale-(rect.minX*scale).rounded()/scale,
                             height: (rect.maxY*scale).rounded()/scale-(rect.minY*scale).rounded()/scale)
        VPNDrawing.shadow(painted, radius: 9, blur: 5, offset: CGSize(width: 0, height: 3), color: palette[.shadow, light:0x245b3b], alpha: 16.0/255, in: context)
        VPNDrawing.rounded(painted, radius: 9, fill: !state.buttonDisabled && feedback.hovered ? palette[.primaryHover, light:0x164d38] : palette[.primaryButton, light:0x25674d], in: context)
        VPNIcon.power.draw(in: CGRect(x: rect.minX + 18, y: rect.midY - 7.5, width: 15, height: 15), color: palette[.onAccent, light:0xffffff], context: context)
        let slack = rect.width - 59 - VPNDrawing.textWidth(state.buttonLabel, size: 11, weight: 550)
        VPNDrawing.text(state.buttonLabel, in: context, at: CGPoint(x: rect.minX + 41 + slack/2, y: rect.minY + 24),
                        size: 11, weight: 550, color: palette[.onAccent, light:0xffffff])
        if state.buttonDisabled { context.endTransparencyLayer() }
    }

    private static func network(_ state: ConnectionPresentation, rect: CGRect, context: CGContext,palette:ThemePalette,parts:ConnectionParts,opacity:CGFloat) {
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.clip(to: CGRect(origin: .zero, size: rect.size))
        context.setAlpha(opacity); context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        if parts.contains(.networkBackground) {
        // Elliptical radial glow, centered by the original grid layout.
        context.saveGState()
        context.translateBy(x: 105, y: rect.height/2)
        context.scaleBy(x: 170, y: 150)
        let colors = [VPNDrawing.color(palette[.networkGlow, light:0xd9e9b5], alpha: 138.0/255), VPNDrawing.color(palette[.networkGlow, light:0xd9e9b5], alpha: 0)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 0.67]) {
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: sqrt(2), options: [.drawsAfterEndLocation])
        }
        context.restoreGState()
        }
        let visualHeight = rect.height - 56, scale = min(194/335.0, visualHeight/254)
        context.saveGState()
        context.translateBy(x: 8 + (194 - 335 * scale)/2, y: (visualHeight - 254 * scale)/2)
        context.scaleBy(x: scale, y: scale)
        if parts.contains(.networkBackground) {
        for radius: CGFloat in [110, 80, 51] {
            context.saveGState()
            context.setAlpha(CGFloat(Float(radius == 110 ? 0.6 : 0.65)))
            context.beginTransparencyLayer(auxiliaryInfo:nil)
            context.setStrokeColor(VPNDrawing.color(palette[.networkRing, light:0xb7c89e]))
            context.setLineWidth(CGFloat(Float(0.7)))
            context.setLineDash(phase: 0, lengths: radius == 110 ? [2, 7] : [])
            context.strokeEllipse(in: CGRect(x: 167-radius, y: 127-radius, width: radius*2, height: radius*2))
            context.endTransparencyLayer();context.restoreGState()
        }
        }
        if parts.contains(.lines) {
        context.saveGState();context.setAlpha(CGFloat(Float(0.9)));context.beginTransparencyLayer(auxiliaryInfo:nil)
        context.setLineWidth(CGFloat(Float(1.4))); context.setLineCap(.round)
        context.setStrokeColor(VPNDrawing.color(state.status.active ? palette[.networkLine, light:0x588547] : palette[.networkRing, light:0x829d6e]))
        context.setLineDash(phase: state.status.active && !state.reduceMotion ? -24 * state.phase.truncatingRemainder(dividingBy: 1.4)/1.4 : 0, lengths: [6, 6])
        context.addPath(ConnectionArtwork.linePath()); context.strokePath()
        context.endTransparencyLayer();context.restoreGState()
        }
        if parts.contains(.networkForeground) {
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(1.5); context.setStrokeColor(VPNDrawing.color(palette[.networkRing, light:0xbbcca8])); context.setFillColor(VPNDrawing.color(palette[.surface, light:0xf9fbf5]))
        for p in ConnectionArtwork.endpoints {
            context.addEllipse(in: CGRect(x: p.x-11, y: p.y-11, width: 22, height: 22)); context.drawPath(using: .fillStroke)
        }
        }
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: 105, y: visualHeight/2); context.rotate(by: -7 * .pi/180)
        let mark = CGRect(x: -33, y: -33, width: 66, height: 66)
        let breathe: CGFloat = state.status.active && state.status != .connected && !state.reduceMotion ?
            7 * AnimationTiming.keyframeProgress(elapsed:state.phase,duration:1.5,easeInOut:true) : 0
        if parts.contains(.halo) {
        VPNDrawing.solidShadow(mark.insetBy(dx: -11-breathe, dy: -11-breathe), radius: 32+breathe, color: palette[.border, light:0xdbe5ce], in: context)
        VPNDrawing.solidShadow(mark.insetBy(dx: -10-breathe, dy: -10-breathe), radius: 31+breathe, color: palette[.raised, light:0xffffff],
                               alpha: (96-breathe*48/7)/255, in: context)
        }
        if parts.contains(.networkForeground) {
        VPNDrawing.shadow(mark, radius: 21, blur: 23, offset: CGSize(width: 0, height: 12), color: palette[.shadow, light:0x466437], alpha: 32.0/255, in: context)
        VPNDrawing.rounded(mark, radius: 21, fill: palette[.primaryButton, light:0x25674d], in: context)
        context.rotate(by: 7 * .pi/180)
        VPNIcon.brand.draw(in: CGRect(x: -19, y: -19, width: 38, height: 38), color: palette[.accent, light:0xd8efad], context: context, snap: false)
        }
        context.restoreGState()
        if parts.contains(.traffic) { traffic(state, origin: CGPoint(x: 6, y: rect.height-54), context: context,palette:palette) }
    }

    private static func traffic(_ state: ConnectionPresentation, origin: CGPoint, context: CGContext,palette:ThemePalette) {
        let values = [VPNFormat.bytes(state.status.active ? state.bytesIn : 0), VPNFormat.bytes(state.status.active ? state.bytesOut : 0)]
        for (index, amount) in values.enumerated() {
            let numeric = ceil(VPNDrawing.textWidth(amount.value, size: 24, weight: 600, tracking: -0.8, tabular: true)*64)/64
            let unit = amount.unit.isEmpty ? 0 : 2 + ceil(VPNDrawing.textWidth(amount.unit, size: 10, weight: 500)*64)/64
            let x = origin.x + (index == 0 ? 86 - numeric - unit : 112)
            VPNDrawing.text(amount.value, in: context, at: CGPoint(x: x, y: origin.y+21), size: 24, weight: 600, tracking: -0.8, color: palette[.accent, light:0x25674d], tabular: true)
            if !amount.unit.isEmpty {
                VPNDrawing.text(amount.unit, in: context, at: CGPoint(x: x+numeric+2, y: origin.y+21), size: 10, weight: 500, color: palette[.secondaryText, light:0x6f8364])
            }
        }
        let slash = VPNDrawing.textWidth("/", size: 21, weight: 300, tabular: true)
        VPNDrawing.text("/", in: context, at: CGPoint(x: origin.x+99-slash/2, y: origin.y+21), size: 21, weight: 300, color: palette[.secondaryText, light:0x9aab8b], tabular: true)
        let inWidth = VPNDrawing.textWidth("IN", size: 8, weight: 500, tracking: 1.6)
        VPNDrawing.text("IN", in: context, at: CGPoint(x: origin.x+86-inWidth, y: origin.y+38), size: 8, weight: 500, tracking: 1.6, color: palette[.secondaryText, light:0x7f9270])
        VPNDrawing.text("OUT", in: context, at: CGPoint(x: origin.x+112, y: origin.y+38), size: 8, weight: 500, tracking: 1.6, color: palette[.secondaryText, light:0x7f9270])
        let smallSlash = VPNDrawing.textWidth("/", size: 8, weight: 500)
        VPNDrawing.text("/", in: context, at: CGPoint(x: origin.x+99-smallSlash/2, y: origin.y+38), size: 8, weight: 500, color: palette[.secondaryText, light:0x7f9270])
    }

    private static func statistics(_ state: ConnectionPresentation, rect: CGRect, context: CGContext,palette:ThemePalette,parts:ConnectionParts) {
        if parts.contains(.statistics) {
        context.setFillColor(VPNDrawing.color(palette[.raised, light:0xffffff], alpha: palette.theme == .dark ? 1 : 71.0/255)); context.fill(rect)
        context.setFillColor(VPNDrawing.color(palette[.border, light:0xdde5d3])); context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
        }
        let width = (rect.width - 46)/3
        let labels = ["VPN address", "Session duration", "Connection protocol"]
        let values = [state.address.isEmpty ? "Not assigned" : state.address, state.duration, "OpenVPN"]
        let icons: [VPNIcon] = [.globe, .clock, .shield]
        for index in 0..<3 {
            let x = 24 + CGFloat(index)*floor(width*64)/64 + (index == 0 ? 0 : 17)
            if parts.contains(.statistics) {
            if index > 0 {
                context.setFillColor(VPNDrawing.color(palette[.border, light:0xdfe6d6]))
                let scale = abs(context.ctm.a)
                context.fill(CGRect(x: ((x-17)*scale).rounded()/scale, y: rect.minY+13, width: 1, height: 33))
            }
            icons[index].draw(in: CGRect(x: x, y: rect.minY+14, width: 11, height: 11), color: palette[.secondaryText, light:0x88917d], context: context)
            VPNDrawing.text(labels[index], in: context, at: CGPoint(x: x+16, y: rect.minY+23), size: 9, weight: 400, color: palette[.secondaryText, light:0x88917d])
            }
            if (index == 1 && parts.contains(.duration)) || (index != 1 && parts.contains(.statistics)) {
            VPNDrawing.text(values[index], in: context, at: CGPoint(x: x, y: rect.minY+42), size: 11, weight: 550, color: palette[.text, light:0x4a6340], monospace: index != 2)
            }
            if index == 2 && parts.contains(.statistics) {
                let end = x + ceil(VPNDrawing.textWidth("OpenVPN", size: 11, weight: 550)*64)/64
                let scale = hypot(context.ctm.a, context.ctm.b)
                context.setFillColor(VPNDrawing.color(palette[.secondaryText, light:0xacbb9a])); context.fillEllipse(in: CGRect(x: ((end+6)*scale).rounded()/scale, y: rect.minY+36, width: 4, height: 4))
                VPNDrawing.text(state.transport, in: context, at: CGPoint(x: end+16, y: rect.minY+42), size: 11, weight: 550, color: palette[.text, light:0x4a6340])
            }
        }
    }
}
