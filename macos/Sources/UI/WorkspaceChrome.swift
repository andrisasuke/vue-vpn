import AppKit

struct WorkspacePresentation: Equatable {
    var snapshot: Snapshot
    var selectedID: String
    var screen: WorkspaceScreen = .overview
    var busy = false
    var themePreference: ThemePreference = .system
    var palette: ThemePalette = .light
    var selected: Profile? { snapshot.profiles.first { $0.id == selectedID } }
    var connectedCount: Int { snapshot.sessions.filter { $0.status == .connected }.count }
    var title: String {
        switch screen { case .overview: "Overview"; case .activity: "Activity"; case .setup: "App settings" }
    }
}

enum WorkspaceAction: Equatable {
    case screen(WorkspaceScreen), profile(String), importProfile, toggle, edit, delete, dismissError
    case disconnectAll, helper(String)
    case theme(ThemePreference)
    case closeModal, submitCredentials, togglePassword, toggleRemember, saveProfile, forgetPassword
    case addRoute, removeRoute(Route), editorRouting(RoutingMode), toggleLegacyCipher, confirmDelete
}

struct WorkspaceHitRegion {
    enum Role { case button,radio,checkbox }
    var rect: CGRect
    var title: String
    var action: WorkspaceAction
    var enabled = true
    var role = Role.button
    var checked = false
}

/// Shared by the real AppKit views and the offscreen visual checks. All content
/// is drawn from state; frozen reference images are never application resources.
@MainActor enum WorkspaceChrome {
    static let sidebarWidth: CGFloat = 194
    static let headerHeight: CGFloat = 50
    static let footerHeight: CGFloat = 41

    static func sidebar(_ state: WorkspacePresentation, size: CGSize, context: CGContext,
                        feedback:(WorkspaceAction,CGRect)->WorkspaceScene.Feedback = { _,_ in .init() }) -> [WorkspaceHitRegion] {
        let palette = state.palette
        fill(CGRect(origin: .zero, size: size), palette[.sidebar, light:0x1c3029], context)
        VPNIcon.brand.draw(in: CGRect(x: 21, y: 52, width: 29, height: 29), color: palette[.accent, light:0xd8efad], context: context)
        VPNDrawing.text("VueVPN", in: context, at: CGPoint(x: 59, y: 75), size: 23, weight: 650, tracking: -1.2, color: palette[.text, light:0xf1f3e9])
        VPNDrawing.text("WORKSPACE", in: context, at: CGPoint(x: 24, y: 117), size: 10, weight: 650, tracking: 1.6, color: palette[.secondaryText, light:0x96aa9c])
        var hits: [WorkspaceHitRegion] = []
        let rows: [(WorkspaceScreen, String, VPNIcon)] = [(.overview, "Overview", .grid), (.activity, "Activity", .activity), (.setup, "App settings", .laptop)]
        for (i, row) in rows.enumerated() {
            let rect = CGRect(x: 11, y: 133+49*i, width: 172, height: 44)
            let selected = state.screen == row.0
            let hovered = feedback(.screen(row.0),rect).hovered
            if hovered && !selected {
                context.setFillColor(VPNDrawing.color(palette[.overlay, light:0xffffff],alpha:8.0/255))
                context.addPath(CGPath(roundedRect:rect,cornerWidth:9,cornerHeight:9,transform:nil));context.fillPath()
            }
            if selected { VPNDrawing.rounded(rect, radius: 9, fill: palette[.sidebarSelected, light:0x34483a], in: context) }
            row.2.draw(in: CGRect(x: 24, y: rect.minY+12, width: 20, height: 20), color: selected ? palette[.accent, light:0xd8efad] : hovered ? palette[.onAccent, light:0xffffff] : palette[.secondaryText, light:0xb9c8bc], context: context)
            VPNDrawing.text(row.1, in: context, at: CGPoint(x: 56, y: rect.minY+26.5), size: 13, weight: 400, color: selected ? palette[.accent, light:0xeaf7d3] : hovered ? palette[.onAccent, light:0xffffff] : palette[.secondaryText, light:0xb9c8bc])
            if i == 0 {
                context.setFillColor(VPNDrawing.color(palette[.overlay, light:0xffffff], alpha: 11.0/255))
                context.addPath(CGPath(roundedRect: CGRect(x: 150, y: rect.minY+12, width: 20, height: 20), cornerWidth: 5, cornerHeight: 5, transform: nil)); context.fillPath()
                let label = String(state.snapshot.profiles.count)
                VPNDrawing.text(label, in: context, at: CGPoint(x: 160-VPNDrawing.textWidth(label,size:10,weight:400)/2, y: rect.minY+26), size: 10, weight: 400, color: palette[.secondaryText, light:0xcbd5c5])
            }
            hits.append(WorkspaceHitRegion(rect: rect, title: row.1, action: .screen(row.0)))
        }
        VPNDrawing.text("YOUR PROFILES", in: context, at: CGPoint(x: 22, y: 314.5), size: 9, weight: 400, tracking: 1.3, color: palette[.secondaryText, light:0x97ab9b])
        let importRect = CGRect(x:148,y:299,width:24,height:24)
        if !state.busy && feedback(.importProfile,importRect).hovered {
            context.setFillColor(VPNDrawing.color(palette[.overlay, light:0xffffff],alpha:16.0/255))
            context.addPath(CGPath(roundedRect:importRect,cornerWidth:5,cornerHeight:5,transform:nil));context.fillPath()
        }
        VPNIcon.plus.draw(in: CGRect(x: 154, y: 303.5, width: 14, height: 14), color: palette[.secondaryText, light:0xa4b5a3], context: context)
        hits.append(WorkspaceHitRegion(rect: CGRect(x: 148, y: 299, width: 24, height: 24), title: "Import profile", action: .importProfile, enabled: !state.busy))
        var y: CGFloat = 335
        if state.snapshot.profiles.isEmpty {
            let lines = VPNDrawing.wrappedLines("Your imported networks will appear here.",width:148,size:11,weight:400)
            for (i,line) in lines.enumerated() {
                VPNDrawing.text(line, in: context, at: CGPoint(x: 23, y: y+20+CGFloat(i)*16), size: 11, weight: 400, color: palette[.secondaryText, light:0x91a798])
            }
            y += 24+CGFloat(lines.count)*16
        }
        for profile in state.snapshot.profiles {
            let session = state.snapshot.sessions.first { $0.profileId == profile.id }
            let status = session?.status ?? .disconnected
            let label = session?.disconnectStalled == true ? "Disconnect stalled" : status.label
            let rect = CGRect(x: 11, y: y, width: 172, height: 62)
            if feedback(.profile(profile.id),rect).hovered { VPNDrawing.rounded(rect,radius:9,fill:palette[.sidebarHover, light:0x2a4033],in:context) }
            if state.selectedID == profile.id { VPNDrawing.rounded(rect, radius: 9, fill: palette[.sidebarSelected, light:0x354c3b], in: context) }
            context.setFillColor(VPNDrawing.color(palette[.overlay, light:0xffffff], alpha: 11.0/255))
            context.addPath(CGPath(roundedRect: CGRect(x: 25, y: y+15, width: 32, height: 32), cornerWidth: 9, cornerHeight: 9, transform: nil)); context.fillPath()
            VPNIcon.server.draw(in: CGRect(x: 33, y: y+23, width: 16, height: 16), color: status == .connected ? palette[.accent, light:0xcfed9f] : palette[.secondaryText, light:0xc1d59b], context: context)
            VPNDrawing.truncatedText(profile.name, width: 85, in: context, at: CGPoint(x: 68,y: y+26), size: 12, weight: 550, color: palette[.secondaryText, light:0xc2cdbf])
            VPNDrawing.text(label, in: context, at: CGPoint(x: 68,y: y+45), size: 10, weight: 400, color: palette[.secondaryText, light:0x91a590])
            context.saveGState()
            if status == .connected { context.setShadow(offset: .zero, blur: 8, color: VPNDrawing.color(palette[.accent, light:0xa9d578],alpha:85.0/255)) }
            context.setFillColor(VPNDrawing.color(status == .connected ? palette[.accent, light:0xb6e086] : palette[.secondaryText, light:0x7b8d80]))
            context.fillEllipse(in: CGRect(x: 164, y: y+28.5, width: 5, height: 5)); context.restoreGState()
            hits.append(WorkspaceHitRegion(rect: rect, title: "\(profile.name), \(label)", action: .profile(profile.id)))
            y += 72
        }
        y += state.snapshot.profiles.isEmpty ? 14 : 8
        let rect = CGRect(x: 11, y: y, width: 172, height: 42)
        let hovered = !state.busy && feedback(.importProfile,rect).hovered
        if hovered {
            context.setFillColor(VPNDrawing.color(palette[.overlay, light:0xffffff],alpha:8.0/255))
            context.addPath(CGPath(roundedRect:rect,cornerWidth:9,cornerHeight:9,transform:nil));context.fillPath()
        }
        context.saveGState()
        if state.busy { context.setAlpha(0.5) }
        let outer = CGPath(roundedRect:rect,cornerWidth:9,cornerHeight:9,transform:nil)
        let border = CGMutablePath();border.addPath(outer)
        border.addPath(CGPath(roundedRect:rect.insetBy(dx:1,dy:1),cornerWidth:8,cornerHeight:8,transform:nil))
        context.addPath(border);context.clip(using:.evenOdd)
        context.setStrokeColor(VPNDrawing.color(hovered ? palette[.secondaryText, light:0x9bae90] : palette[.secondaryText, light:0x51604e]));context.setLineWidth(CGFloat(Float(2.2)))
        let length = 2*(rect.width+rect.height-36)+18*CGFloat.pi
        let numberOfDashes = Float(length)/3
        let gap:CGFloat = Int(numberOfDashes)%2 == 1 && numberOfDashes != floor(numberOfDashes) ? CGFloat(3+3/(numberOfDashes/2)) : 3
        context.setLineDash(phase:3,lengths:[3,gap]);context.addPath(outer);context.strokePath()
        context.restoreGState();context.saveGState()
        if state.busy { context.setAlpha(0.5) }
        let label = "Import .ovpn profile", width = VPNDrawing.textWidth(label,size:12,weight:400)
        let left = rect.midX-(width+24)/2
        VPNIcon.upload.draw(in: CGRect(x:left,y:y+13,width:16,height:16),color:palette[.secondaryText, light:0xbcccb6],context:context)
        VPNDrawing.text(label,in:context,at:CGPoint(x:left+24,y:y+25),size:12,weight:400,color:palette[.secondaryText, light:0xbcccb6])
        context.restoreGState()
        hits.append(WorkspaceHitRegion(rect:rect,title:label,action:.importProfile,enabled:!state.busy))
        return hits
    }

    static func header(_ state: WorkspacePresentation, width: CGFloat, context: CGContext) {
        let palette = state.palette
        fill(CGRect(x:0,y:0,width:width,height:50),palette[.background, light:0xfafbf8],context)
        fill(CGRect(x:0,y:49,width:width,height:1),palette[.border, light:0xe5e9df],context)
        VPNDrawing.text("Workspace",in:context,at:CGPoint(x:24,y:32.5),size:11,weight:400,color:palette[.secondaryText, light:0x889184])
        let nameWidth = ceil(VPNDrawing.textWidth("Workspace",size:11,weight:400)*64)/64
        VPNIcon.chevron.draw(in:CGRect(x:24+nameWidth+12,y:22,width:13,height:13),color:palette[.secondaryText, light:0xa8b19f],context:context)
        VPNDrawing.text(state.title,in:context,at:CGPoint(x:24+nameWidth+37,y:32.5),size:11,weight:500,color:palette[.text, light:0x495c4b])
        let label = state.connectedCount == 0 ? "No active connection" : "\(state.connectedCount) connected"
        let color: UInt32 = state.connectedCount == 0 ? palette[.secondaryText, light:0x889184] : palette[.accent, light:0x277545]
        let x = width-24-ceil(VPNDrawing.textWidth(label,size:10,weight:400)*64)/64
        context.setFillColor(VPNDrawing.color(color)); context.fillEllipse(in:CGRect(x:(x-10).rounded(.toNearestOrAwayFromZero),y:26,width:5,height:5))
        VPNDrawing.text(label,in:context,at:CGPoint(x:x,y:32),size:10,weight:400,color:color)
    }

    static func footer(width: CGFloat, context: CGContext, palette:ThemePalette = .light) -> WorkspaceHitRegion {
        fill(CGRect(x:0,y:0,width:width,height:41),palette[.background, light:0xf7f9f3],context)
        fill(CGRect(x:0,y:0,width:width,height:1),palette[.border, light:0xe5e9df],context)
        context.setFillColor(VPNDrawing.color(palette[.secondaryText, light:0xb6c1a8])); context.fillEllipse(in:CGRect(x:24,y:19,width:4,height:4))
        VPNDrawing.text("Private by design",in:context,at:CGPoint(x:34,y:24.5),size:9,weight:400,color:palette[.secondaryText, light:0x98a08e])
        let end = 34+ceil(VPNDrawing.textWidth("Private by design",size:9,weight:400)*64)/64
        VPNDrawing.text("·",in:context,at:CGPoint(x:end+6,y:24.5),size:9,weight:400,color:palette[.secondaryText, light:0x98a08e])
        VPNDrawing.text("IPv4",in:context,at:CGPoint(x:end+12+ceil(VPNDrawing.textWidth("·",size:9,weight:400)*64)/64,y:24.5),size:9,weight:400,color:palette[.secondaryText, light:0x98a08e])
        let label = "Connection activity", labelWidth = ceil(VPNDrawing.textWidth(label,size:9,weight:400)*64)/64
        let left = width-30-labelWidth-17
        VPNIcon.terminal.draw(in:CGRect(x:left,y:15,width:12,height:12),color:palette[.secondaryText, light:0x7f8c70],context:context)
        VPNDrawing.text(label,in:context,at:CGPoint(x:left+17,y:24),size:9,weight:400,color:palette[.secondaryText, light:0x7f8c70])
        return WorkspaceHitRegion(rect:CGRect(x:left-6,y:11,width:labelWidth+29,height:19),title:label,action:.screen(.activity))
    }

    private static func fill(_ rect: CGRect, _ color: UInt32, _ context: CGContext) {
        context.setFillColor(VPNDrawing.color(color)); context.fill(rect)
    }
}
