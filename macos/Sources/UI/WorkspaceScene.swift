import AppKit

/// A retained list of native drawing commands and matching accessible controls.
/// Layout measures the actual text, so scrolling and hit targets share geometry.
@MainActor struct WorkspaceScene {
    struct Feedback { var hovered = false; var pressed = false }
    let palette: ThemePalette
    init(palette: ThemePalette = .light) { self.palette = palette }
    var connectionPanel:CGRect?
    var height: CGFloat = 0
    var hits: [WorkspaceHitRegion] = []
    private var commands: [@MainActor (CGContext, (WorkspaceAction, CGRect) -> Feedback) -> Void] = []

    func draw(in context: CGContext,feedback:(WorkspaceAction,CGRect)->Feedback = { _,_ in Feedback() }) {
        commands.forEach { $0(context,feedback) }
    }
    mutating func custom(_ draw: @escaping @MainActor (CGContext) -> Void) { commands.append { context,_ in draw(context) } }
    mutating func interactive(_ action:WorkspaceAction,in rect:CGRect,_ draw:@escaping @MainActor (CGContext,Feedback)->Void) {
        commands.append { context,feedback in draw(context,feedback(action,rect)) }
    }
    mutating func append(_ scene:WorkspaceScene) { commands += scene.commands;hits += scene.hits }
    mutating func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: CGFloat = 400,
                       color: UInt32? = nil, tracking: CGFloat = 0, mono: Bool = false) {
        let color = color ?? palette.text
        custom { VPNDrawing.text(value,in:$0,at:CGPoint(x:x,y:y),size:size,weight:weight,tracking:tracking,color:color,monospace:mono) }
    }
    mutating func box(_ rect: CGRect, radius: CGFloat, fill: UInt32, border: UInt32? = nil) {
        custom { VPNDrawing.rounded(rect,radius:radius,fill:fill,border:border,in:$0) }
    }
    mutating func icon(_ icon: VPNIcon, x: CGFloat, y: CGFloat, size: CGFloat, color: UInt32) {
        custom { icon.draw(in:CGRect(x:x,y:y,width:size,height:size),color:color,context:$0) }
    }
    @discardableResult mutating func paragraph(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                                               size: CGFloat = 11, lineHeight: CGFloat = 18.7,
                                               color: UInt32? = nil, weight: CGFloat = 400) -> CGFloat {
        let color = color ?? palette.secondaryText
        let lines = VPNDrawing.wrappedLines(value,width:width,size:size,weight:weight)
        for (i,line) in lines.enumerated() { text(line,x:x,y:y+size+CGFloat(i)*lineHeight,size:size,weight:weight,color:color) }
        return CGFloat(lines.count)*lineHeight
    }
    enum ButtonStyle { case primary, secondary, text, danger, icon }
    @discardableResult mutating func button(_ label: String, x: CGFloat, y: CGFloat, action: WorkspaceAction,
                                            style: ButtonStyle = .secondary, icon: VPNIcon? = nil,
                                            enabled: Bool = true, fixedWidth: CGFloat? = nil,
                                            fontSize: CGFloat = 11, iconAfter:Bool = false,fixedHeight:CGFloat? = nil) -> CGRect {
        let palette = self.palette
        let isText = style == .text, iconOnly = style == .icon
        let fontWeight: CGFloat = isText ? 400 : 550
        let labelWidth = VPNDrawing.textWidth(label,size:fontSize,weight:fontWeight)
        let natural = ceil((labelWidth+(icon == nil ? 0 : isText ? 21 : 23)+(isText ? 6 : 36))*64)/64
        let textHeight = floor(fontSize*1.5)+16
        let rect = CGRect(x:x,y:y,width:fixedWidth ?? (iconOnly ? 33 : natural),height:fixedHeight ?? (iconOnly ? 33 : isText ? textHeight : max(40,floor(fontSize*1.5)+24)))
        let color: UInt32 = style == .primary || style == .danger ? palette[.onAccent, light:0xffffff] : isText ? palette[.secondaryText, light:0x6b7d60] : palette[.secondaryText, light:0x5c7250]
        interactive(action,in:rect) { ctx,feedback in
            ctx.saveGState(); defer { ctx.restoreGState() }
            if !enabled { ctx.setAlpha(0.5); ctx.beginTransparencyLayer(auxiliaryInfo:nil) }
            if enabled && feedback.pressed { ctx.translateBy(x:0,y:1) }
            let hover = enabled && feedback.hovered
            let painted = VPNDrawing.pixelAligned(rect,in:ctx)
            if style == .primary { VPNDrawing.shadow(painted,radius:9,blur:5,offset:CGSize(width:0,height:3),color:palette[.shadow, light:0x245b3b],alpha:16.0/255,in:ctx) }
            if style == .primary || style == .danger {
                VPNDrawing.rounded(painted,radius:9,fill:style == .danger ? palette[.dangerButton, light:0xa84e3e] : hover ? palette[.primaryHover, light:0x164d38] : palette[.primaryButton, light:0x25674d],in:ctx)
            } else if style == .secondary {
                VPNDrawing.rounded(painted,radius:9,fill:hover ? palette[.hover, light:0xf1f4ed] : palette[.raised, light:0xeef2e7],border:palette[.border, light:0xdce4d2],in:ctx)
            } else if iconOnly { VPNDrawing.rounded(painted,radius:7,fill:hover ? palette[.raised, light:0xf0f3eb] : palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df],background:hover,in:ctx) }
            let iconWidth: CGFloat = iconOnly ? 16 : isText ? 14 : 15
            let contentWidth = labelWidth+(icon == nil ? 0 : iconWidth+(isText ? 7 : 8))
            let left = iconOnly ? rect.midX-8 : rect.midX-contentWidth/2
            if let icon { icon.draw(in:CGRect(x:iconAfter ? left+labelWidth+(isText ? 7 : 8) : left,y:rect.midY-iconWidth/2,width:iconWidth,height:iconWidth),color:iconOnly ? palette[.secondaryText, light:0x77847b] : color,context:ctx) }
            if !iconOnly {
                VPNDrawing.text(label,in:ctx,at:CGPoint(x:left+(icon == nil || iconAfter ? 0 : iconWidth+(isText ? 7 : 8)),y:rect.midY+(isText ? fontSize*0.5-1.5 : 4)),size:fontSize,weight:fontWeight,color:hover && isText ? palette[.accent, light:0x25674d] : color)
            }
            if !enabled { ctx.endTransparencyLayer() }
        }
        hits.append(WorkspaceHitRegion(rect:rect,title:label,action:action,enabled:enabled))
        return rect
    }
}

@MainActor enum WorkspaceContent {
    static func make(_ state: WorkspacePresentation, width: CGFloat, clock: UInt64,
                     connection: ConnectionPresentation, error: String = "", loaded: Bool = true,retainedConnection:Bool = false) -> WorkspaceScene {
        let palette = state.palette
        var scene = WorkspaceScene(palette:palette)
        let left: CGFloat = 24, inner = max(1,width-48)
        var y: CGFloat = 22
        if !error.isEmpty {
            var message = WorkspaceScene(palette:palette)
            let h = message.paragraph(error,x:left+14,y:y+12,width:inner-70,size:12,lineHeight:18,color:palette[.errorText, light:0x8b5032])+24
            scene.box(CGRect(x:left,y:y,width:inner,height:h),radius:10,fill:palette[.errorSurface, light:0xfff1e8],border:palette[.errorBorder, light:0xeed9c5])
            scene.custom { message.draw(in:$0) }
            scene.button("Dismiss error",x:left+inner-39,y:y+6,action:.dismissError,style:.icon,icon:.close)
            y += h+16
        }
        if !loaded {
            scene.text("Loading your workspace…",x:left+50,y:y+64,size:14)
            scene.height = y+130; return scene
        }
        switch state.screen {
        case .overview:
            if state.snapshot.helper.status != "enabled" {
                let messageHeight = CGFloat(VPNDrawing.wrappedLines(state.snapshot.helper.message,width:max(1,inner-155),size:10,weight:400).count)*15
                scene.box(CGRect(x:left,y:y,width:inner,height:messageHeight+22),radius:9,fill:palette[.connection, light:0xf0f4e9])
                scene.icon(.info,x:left+13,y:y+11,size:15,color:palette[.secondaryText, light:0x6a8159])
                scene.paragraph(state.snapshot.helper.message,x:left+37,y:y+11,width:inner-155,size:10,lineHeight:15,color:palette[.secondaryText, light:0x6a8159])
                scene.button("View details",x:left+inner-104,y:y+2,action:.screen(.setup),style:.text,icon:.arrow,fontSize:10,iconAfter:true)
                y += messageHeight+40
            }
            if let profile = state.selected {
                y = overview(&scene,profile:profile,state:state,connection:connection,x:left,y:y,width:inner,retainedConnection:retainedConnection)
            } else { y = welcome(&scene,x:left,y:y,width:inner,busy:state.busy) }
        case .activity:
            heading(&scene,eyebrow:"CONNECTION HISTORY",title:"Activity",subtitle:"Session events from this app launch.",x:left,y:y,width:inner)
            let bw = ceil(VPNDrawing.textWidth("Disconnect all",size:11,weight:550)*64)/64+36
            scene.button("Disconnect all",x:left+inner-bw,y:y+15,action:.disconnectAll,enabled:!state.busy && state.snapshot.sessions.contains(where:\.active))
            y += 88
            if state.snapshot.logs.isEmpty {
                let label = "No activity yet. Your connection events will appear here."
                scene.text(label,x:left+(inner-VPNDrawing.textWidth(label,size:11,weight:400))/2,y:y+36,size:11,color:palette[.secondaryText, light:0x8b977f])
                y += 64
            }
            let formatter = DateFormatter(); formatter.timeStyle = .medium; formatter.dateStyle = .none
            for entry in state.snapshot.logs.reversed() {
                let label = state.snapshot.profiles.first { $0.id == entry.profileId }?.name ?? "VueVPN"
                let textWidth = max(1,inner-74)
                let lines = VPNDrawing.wrappedLines(entry.message,width:textWidth,size:11,weight:400)
                let h = 84+CGFloat(lines.count)*16
                scene.box(CGRect(x:left,y:y,width:inner,height:h),radius:12,fill:palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df])
                scene.box(CGRect(x:left+16,y:y+16,width:30,height:30),radius:9,fill:palette[.raised, light:0xedf3e5])
                scene.icon(.activity,x:left+23.5,y:y+23.5,size:15,color:palette[.secondaryText, light:0x8ca178])
                scene.text(label,x:left+58,y:y+32,size:11,weight:700)
                let p = scene.paragraph(entry.message,x:left+58,y:y+43,width:textWidth,size:11,lineHeight:16)
                scene.text(formatter.string(from:Date(timeIntervalSince1970:Double(entry.timestamp))),x:left+58,y:y+63+p,size:9,color:palette[.secondaryText, light:0x97a28d])
                y += h+12
            }
        case .setup:
            y = settings(&scene,state:state,x:left,y:y,width:inner)
        }
        scene.height = y+22
        return scene
    }

    private static func heading(_ scene: inout WorkspaceScene, eyebrow: String, title: String, subtitle: String,
                                x: CGFloat,y: CGFloat,width: CGFloat) {
        let palette = scene.palette
        scene.text(eyebrow,x:x,y:y+10,size:9,weight:650,color:palette[.secondaryText, light:0x8c9b7e],tracking:1.7)
        scene.text(title,x:x,y:y+43,size:23,weight:620,tracking:-0.8)
        scene.paragraph(subtitle,x:x,y:y+54,width:width,size:11)
    }

    private static func overview(_ scene: inout WorkspaceScene,profile:Profile,state:WorkspacePresentation,
                                 connection:ConnectionPresentation,x:CGFloat,y:CGFloat,width:CGFloat,retainedConnection:Bool) -> CGFloat {
        let palette = scene.palette
        scene.text("YOUR NETWORK",x:x,y:y+10,size:9,weight:650,color:palette[.secondaryText, light:0x8c9b7e],tracking:1.7)
        let titleLines = VPNDrawing.wrappedLines(profile.name,width:min(370,max(1,width-140)),size:23,weight:620)
        for (i,line) in titleLines.enumerated() { scene.text(line,x:x,y:y+43+CGFloat(i)*34,size:23,weight:620,tracking:-0.8) }
        let extra = CGFloat(max(0,titleLines.count-1))*34
        scene.icon(.server,x:x,y:y+56.5+extra,size:20,color:palette[.secondaryText, light:0x77847b])
        let serverWidth = min(250,ceil(VPNDrawing.textWidth(profile.server,size:10,weight:400)*64)/64)
        scene.custom { VPNDrawing.truncatedText(profile.server,width:serverWidth,in:$0,at:CGPoint(x:x+29,y:y+70+extra),size:10,weight:400,color:palette[.secondaryText, light:0x77847b]) }
        let proto = profile.protocol.uppercased(), tagX = x+38+serverWidth
        let tagWidth = ceil(VPNDrawing.textWidth(proto,size:9,weight:400,tracking:0.18)*64)/64+16
        scene.custom { ctx in
            VPNDrawing.rounded(VPNDrawing.pixelAligned(CGRect(x:tagX,y:y+56+extra,width:tagWidth,height:21),in:ctx),radius:5,fill:palette[.background, light:0xfafbf8],border:palette[.border, light:0xe5e9df],in:ctx)
        }
        scene.text(proto,x:tagX+8,y:y+70+extra,size:9,color:palette[.secondaryText, light:0x77836d],tracking:0.18)
        scene.button("Edit profile",x:x+width-122.4375,y:y+23,action:.edit,style:.text,icon:.edit,enabled:!state.busy,fontSize:10)
        scene.button("Delete profile",x:x+width-33,y:y+22,action:.delete,style:.icon,icon:.trash,enabled:!state.busy)
        var cursor = y+95+extra
        let panelHeight = ConnectionPanel.height(connection,width:width)
        let panel = CGRect(x:x,y:cursor,width:width,height:panelHeight)
        let connectionTarget = ConnectionPanel.buttonRect(connection,width:width).offsetBy(dx:x,dy:cursor)
        scene.connectionPanel = panel
        if !retainedConnection {
            scene.interactive(.toggle,in:connectionTarget) { context,feedback in
                ConnectionPanel.draw(connection,in:panel,context:context,feedback:feedback,palette:palette)
            }
        }
        scene.hits.append(WorkspaceHitRegion(rect:connectionTarget,title:connection.buttonLabel,action:.toggle,enabled:!connection.buttonDisabled))
        cursor += panelHeight
        if let session = state.snapshot.sessions.first(where:{$0.profileId == profile.id}) {
            if let error = session.error, !error.isEmpty {
                cursor += 12
                cursor += scene.paragraph(error,x:x,y:cursor,width:width,color:palette[.errorText, light:0xa64035])
            }
            if session.status == .reconnecting {
                cursor += scene.paragraph("Retry \(session.attempts) of 5. Waiting pauses when the network is unavailable.",x:x,y:cursor,width:width)
            }
        }
        cursor += 20
        scene.icon(.route,x:x,y:cursor+2.5,size:16,color:palette[.secondaryText, light:0x6b825d])
        scene.text("Traffic routing",x:x+23,y:cursor+16,size:14,weight:600,tracking:-0.2)
        scene.text("Choose which IPv4 traffic uses this connection.",x:x,y:cursor+35,size:10,color:palette[.secondaryText, light:0x8a9481])
        scene.button("Manage routes",x:x+width-105,y:cursor+3.5,action:.edit,style:.text,icon:.arrow,iconAfter:true)
        cursor += 50
        let modeWidth = (width-11)/2
        for (i,mode) in [RoutingMode.all,.selected].enumerated() {
            let rect = CGRect(x:x+CGFloat(i)*(modeWidth+11),y:cursor,width:modeWidth,height:73)
            let selected = profile.routingMode == mode
            scene.interactive(.edit,in:rect) { VPNDrawing.routingChoice(rect,selected:selected,hovered:$1.hovered,palette:palette,in:$0) }
            let label = mode == .all ? "All IPv4 traffic" : "Selected networks"
            scene.text(label,x:rect.minX+34,y:rect.minY+24,size:10,weight:600)
            if mode == .all { scene.text("DEFAULT",x:rect.minX+37+VPNDrawing.textWidth(label,size:10,weight:600),y:rect.minY+24,size:7,color:palette[.secondaryText, light:0x86977c]) }
            scene.text(mode == .all ? "Outgoing IPv4 traffic uses the VPN." : "Only specific IP addresses and subnets.",x:rect.minX+34,y:rect.minY+42,size:9,color:palette[.secondaryText, light:0x8a9480])
            scene.hits.append(WorkspaceHitRegion(rect:rect,title:label,action:.edit,role:.radio,checked:selected))
        }
        cursor += 85
        if profile.routingMode == .selected {
            let tableHeight:CGFloat = 41+(profile.routes.isEmpty ? 64.5 : 25+CGFloat(profile.routes.count)*31)
            scene.box(CGRect(x:x,y:cursor,width:width,height:tableHeight),radius:11,fill:palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df])
            let headingBorder = CGRect(x:x+1,y:cursor+39,width:width-2,height:1)
            scene.custom { ctx in ctx.setFillColor(VPNDrawing.color(palette[.border, light:0xedf0e8]));ctx.fill(headingBorder) }
            scene.text("VPN routes",x:x+16,y:cursor+23.5,size:10,weight:550,color:palette[.secondaryText, light:0x6e7e61])
            let count = String(profile.routes.count)
            let countX = x+16+VPNDrawing.textWidth("VPN routes ",size:10,weight:550)+5
            let countRect = CGRect(x:countX,y:cursor+12.5,width:VPNDrawing.textWidth(count,size:9,weight:550)+10,height:15)
            scene.custom { VPNDrawing.rounded(VPNDrawing.pixelAligned(countRect,in:$0),radius:4,fill:palette[.raised, light:0xf3f5ee],in:$0) }
            scene.text(count,x:countX+5,y:cursor+23.5,size:9,weight:550,color:palette[.secondaryText, light:0x98a08c])
            scene.text("IPv4",x:x+width-39.234375,y:cursor+24,size:11,color:palette[.secondaryText, light:0x77847b])
            if profile.routes.isEmpty { scene.paragraph("Add the networks you want to reach through this VPN.",x:x+24,y:cursor+64,width:width-48) }
            else {
                let columns:[CGFloat] = [16,width*0.455714,width*0.692352]
                for (i,label) in ["NETWORK ADDRESS","SUBNET","DESTINATION"].enumerated() {
                    scene.text(label,x:x+columns[i],y:cursor+58,size:8,weight:450,color:palette[.secondaryText, light:0x98a08e],tracking:0.8)
                }
                for (i,route) in profile.routes.enumerated() {
                    let rowY = cursor+81+CGFloat(i)*31
                    scene.text(route.address.description,x:x+columns[0],y:rowY,size:10,color:palette[.text, light:0x4c6241],mono:true)
                    scene.text("/\(route.prefix)",x:x+columns[1],y:rowY,size:10,color:palette[.secondaryText, light:0x79896c])
                    scene.box(CGRect(x:x+columns[2],y:rowY-11,width:47.421875,height:17),radius:4,fill:palette[.raised, light:0xf4f6ef])
                    scene.text("Via VPN",x:x+columns[2]+6,y:rowY,size:9,color:palette[.secondaryText, light:0x89967b])
                }
            }
            cursor += tableHeight
        } else {
            scene.box(CGRect(x:x,y:cursor,width:width,height:144),radius:11,fill:palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df])
            scene.box(CGRect(x:x+19,y:cursor+48.5,width:47,height:47),radius:14,fill:palette[.raised, light:0xedf4e5])
            scene.icon(.globe,x:x+32.5,y:cursor+62,size:20,color:palette[.accent, light:0x25674d])
            scene.text("Your IPv4 traffic, through one connection.",x:x+82,y:cursor+44.5,size:12,weight:550)
            scene.paragraph("Only one profile can use this mode at a time. Other profiles can connect with specific routes.",x:x+82,y:cursor+56.5,width:min(370,width-102),size:10,lineHeight:17,color:palette[.secondaryText, light:0x89947e])
            scene.text("0.0.0.0/0 → VPN",x:x+82,y:cursor+107,size:10,color:palette[.secondaryText, light:0x6c815c],mono:true)
            cursor += 144
        }
        scene.icon(.info,x:x,y:cursor+11,size:12,color:palette[.secondaryText, light:0x929a89])
        let note = profile.routingMode == .selected ? "Other IPv4 traffic uses your regular network." : "VPN transport traffic keeps using your physical network."
        cursor += 10+scene.paragraph(note+" IPv6 is unchanged.",x:x+18,y:cursor+10,width:width-18,size:9,lineHeight:13.5,color:palette[.secondaryText, light:0x929a89])
        for warning in profile.warnings { cursor += 8+scene.paragraph(warning,x:x,y:cursor+8,width:width,color:palette[.warning, light:0x996331]) }
        return cursor
    }

    private static func welcome(_ scene:inout WorkspaceScene,x:CGFloat,y:CGFloat,width:CGFloat,busy:Bool) -> CGFloat {
        let palette = scene.palette
        let center = x+width/2
        scene.custom { ctx in
            ctx.saveGState();ctx.translateBy(x:center,y:y+82.5);ctx.rotate(by:-6 * .pi/180)
            VPNDrawing.rounded(CGRect(x:-44,y:-44,width:88,height:88),radius:25,fill:palette[.raised, light:0xe9f1dd],in:ctx)
            VPNIcon.brand.draw(in:CGRect(x:-25,y:-25,width:50,height:50),color:palette[.accent, light:0x25674d],context:ctx,snap:false)
            ctx.restoreGState()
        }
        func centered(_ value:String,size:CGFloat,weight:CGFloat,tracking:CGFloat = 0) -> CGFloat {
            center-VPNDrawing.textWidth(value,size:size,weight:weight,tracking:tracking)/2
        }
        let eyebrow = "A LITTLE CLOSER TO YOUR NETWORK"
        scene.text(eyebrow,x:centered(eyebrow,size:9,weight:650,tracking:1.7),y:y+164.5,size:9,weight:650,color:palette[.secondaryText, light:0x8c9b7e],tracking:1.7)
        for (i,label) in ["Your workspace.","Wherever you are."].enumerated() {
            scene.text(label,x:centered(label,size:37,weight:700,tracking:-1.8),y:y+217.5+CGFloat(i)*43,size:37,weight:700,tracking:-1.8)
        }
        for (i,label) in ["Import your OpenVPN profile, choose your routes,","and connect to the networks that matter."].enumerated() {
            scene.text(label,x:centered(label,size:12,weight:400),y:y+298.5+CGFloat(i)*22,size:12,color:palette[.secondaryText, light:0x77847b])
        }
        let bw = ceil(VPNDrawing.textWidth("Import .ovpn profile",size:11,weight:550)*64)/64+59
        scene.button("Import .ovpn profile",x:center-bw/2,y:y+353.5,action:.importProfile,style:.primary,icon:.upload,enabled:!busy)
        let label = "Your profiles stay on this Mac."
        scene.text(label,x:centered(label,size:10,weight:400),y:y+417.5,size:10,color:palette[.secondaryText, light:0x939f88])
        return y+460
    }

    private static func settings(_ scene:inout WorkspaceScene,state:WorkspacePresentation,x:CGFloat,y:CGFloat,width:CGFloat) -> CGFloat {
        heading(&scene,eyebrow:"MADE FOR YOUR MAC",title:"App settings",subtitle:"Set up once, connect from anywhere in your menu bar.",x:x,y:y,width:width)
        let helperY = AppearanceSection.append(to:&scene,preference:state.themePreference,x:x,y:y+88,width:width)+20
        return helperSettings(&scene,state:state,x:x,y:helperY,width:width)
    }

    /// Shared helper content allows its existing reference to remain unchanged
    /// when the independent Appearance section is inserted above it.
    static func helperSettings(_ scene:inout WorkspaceScene,state:WorkspacePresentation,x:CGFloat,y:CGFloat,width:CGFloat) -> CGFloat {
        let palette = scene.palette
        var card = WorkspaceScene(palette:palette), cursor = y
        card.box(CGRect(x:x+26,y:cursor+26,width:45,height:45),radius:13,fill:palette[.raised, light:0xdce8ce])
        card.icon(.shield,x:x+38.5,y:cursor+38.5,size:20,color:palette[.secondaryText, light:0x527446])
        card.text("VPN helper",x:x+26,y:cursor+106,size:18,weight:700)
        var rowY = cursor+121
        rowY += card.paragraph(state.snapshot.helper.message,x:x+26,y:rowY+3,width:width-52,size:12,lineHeight:21)+12
        let tag = state.snapshot.helper.status.replacingOccurrences(of:"_",with:" ").uppercased()
        let tw = VPNDrawing.textWidth(tag,size:9,weight:400,tracking:0.18)+16
        let tagRect = CGRect(x:x+26,y:rowY+3,width:tw,height:19)
        card.custom { VPNDrawing.rounded(VPNDrawing.pixelAligned(tagRect,in:$0),radius:5,fill:palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df],background:false,in:$0) }
        card.text(tag,x:x+34,y:rowY+16,size:9,color:palette[.secondaryText, light:0x77836d],tracking:0.18)
        rowY += 41
        var bx = x+26
        let action: (String,WorkspaceAction)?
        switch state.snapshot.helper.status {
        case "not_registered","not_found": action = ("Enable VPN helper",.helper("register"))
        case "unavailable": action = ("Repair VPN helper",.helper("retry_update"))
        case "update_failed": action = ("Retry helper update",.helper("retry_update"))
        case "update_pending": action = ("Disconnect all and update",.disconnectAll)
        default: action = nil
        }
        if let action { bx = card.button(action.0,x:bx,y:rowY,action:action.1,style:.primary,enabled:!state.busy).maxX+8 }
        if bx+170 > x+width-26 { bx = x+26;rowY += 48 }
        bx = card.button("Open macOS settings",x:bx,y:rowY,action:.helper("settings"),enabled:!state.busy && state.snapshot.helper.status != "updating").maxX+8
        if bx+100 > x+width-26 { bx = x+26;rowY += 48 }
        card.button("Refresh status",x:bx,y:rowY,action:.helper("status"),style:.text,enabled:!state.busy,fixedHeight:40)
        rowY += 55
        rowY += card.paragraph("Use the packaged VueVPN.app from /Applications. Helper updates install automatically when no VPN connections are active. If macOS requests approval, allow it in system settings.",x:x+26,y:rowY+3,width:width-52,size:10,lineHeight:18)
        let rect = CGRect(x:x,y:cursor,width:width,height:rowY+26-cursor)
        scene.custom { ctx in
            let pixel = 1/hypot(ctx.ctm.a,ctx.ctm.b)
            ctx.saveGState();ctx.addPath(CGPath(roundedRect:rect.insetBy(dx:pixel,dy:pixel),cornerWidth:16,cornerHeight:16,transform:nil));ctx.clip()
            let colors = [VPNDrawing.color(palette[.gradientStart, light:0xf0f5e7]), VPNDrawing.color(palette[.gradientEnd, light:0xfafbf7])]
            let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB)!,colors:colors as CFArray,locations:[0,1])!
            let angle:CGFloat = 130 * .pi/180,dx = sin(angle),dy = -cos(angle)
            let length = abs(rect.width*dx)+abs(rect.height*dy)
            ctx.drawLinearGradient(gradient,start:CGPoint(x:rect.midX-dx*length/2,y:rect.midY-dy*length/2),end:CGPoint(x:rect.midX+dx*length/2,y:rect.midY+dy*length/2),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]);ctx.restoreGState()
            VPNDrawing.rounded(rect,radius:16,fill:palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df],background:false,in:ctx)
        }
        scene.append(card)
        cursor = rect.maxY
        for (title,body) in [
            ("Always within reach","Closing this window keeps VueVPN in your menu bar. Its icon turns green when a profile is connected. Choose a profile there to connect or disconnect."),
            ("Your credentials stay yours","Remembered PINs are saved in macOS Keychain after successful authentication. You can remove them in each profile’s settings."),
            ("IPv4 only","This version manages IPv4 traffic. IPv6 keeps using your existing network. There is no automatic connection at startup or kill switch."),
        ] {
            cursor += 23
            scene.text(title,x:x,y:cursor+13,size:12,weight:700)
            cursor += 25
            cursor += scene.paragraph(body,x:x,y:cursor+3,width:width,size:11,lineHeight:20)
        }
        cursor += 20
        scene.button("Disable helper and disconnect all",x:x,y:cursor,action:.helper("unregister"),style:.text,enabled:!state.busy && state.snapshot.helper.status == "enabled")
        return cursor+32
    }
}
