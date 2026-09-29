import AppKit
import CoreImage

/// AppKit fields over native dialog drawing. No WebView, system sheet redesign,
/// or password passed through notifications, URLs, logging, or drawing commands.
@MainActor
final class ProfileDialog: NSView {
    private(set) var palette:ThemePalette = .light
    private let model:WorkspaceModel
    private let modal:WorkspaceModal
    private let profileID:String
    private let scroll = NSScrollView()
    private let surface = SceneCanvasView()
    private var inputs:[String:NativeTextInput] = [:]
    private var focusedInput:String?
    private var editor:ProfileEditor?
    private var contentHeight:CGFloat = 317
    private var backdrop:CGImage?
    private var routeScroll:NSScrollView?
    private var keyMonitor:Any?
    private let imageContext = CIContext(options:[.useSoftwareRenderer:true])
    var changed:(() -> Void)?
    override var isFlipped:Bool { true }

    init(model:WorkspaceModel,modal:WorkspaceModal,profile:Profile) {
        self.model = model;self.modal = modal;profileID = profile.id
        if case .settings = modal { editor = ProfileEditor(profile) }
        super.init(frame:.zero)
        scroll.documentView = surface;scroll.drawsBackground = false;scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true;scroll.layer?.cornerRadius = 20;scroll.layer?.masksToBounds = true
        addSubview(scroll)
        surface.perform = { [weak self] in self?.perform($0) }
        setAccessibilityRole(.group);setAccessibilityLabel("Profile dialog")
        setAccessibilityModal(true)
    }
    required init?(coder:NSCoder) { fatalError("Programmatic native dialog") }
    override var acceptsFirstResponder:Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor);self.keyMonitor = nil }
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,event.window === self.window else { return event }
            if event.keyCode == 53 { self.perform(.closeModal);return nil }
            guard event.keyCode == 48 else { return event }
            self.advanceFocus(backwards:event.modifierFlags.contains(.shift));return nil
        }
    }

    private func advanceFocus(backwards:Bool) {
        guard let window else { return }
        func controls(_ view:NSView) -> [NSControl] {
            guard !view.isHidden else { return [] }
            if let control = view as? NSControl { return control.isEnabled ? [control] : [] }
            return view.subviews.flatMap(controls)
        }
        let ordered = controls(surface).sorted {
            let a = $0.convert($0.bounds,to:surface),b = $1.convert($1.bounds,to:surface)
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }
        guard !ordered.isEmpty else { return }
        let active = ordered.firstIndex { $0 === window.firstResponder || ($0 as? NSTextField)?.currentEditor() === window.firstResponder }
        let index = active.map { ($0+(backwards ? ordered.count-1 : 1))%ordered.count } ?? (backwards ? ordered.count-1 : 0)
        let target = ordered[index]
        target.scrollToVisible(target.bounds);window.makeFirstResponder(target)
    }

    override func mouseDown(with event:NSEvent) {
        if !scroll.frame.contains(convert(event.locationInWindow,from:nil)) { perform(.closeModal) }
    }

    func matches(_ modal:WorkspaceModal) -> Bool { self.modal == modal }

    func applyTheme(_ palette:ThemePalette) {
        guard self.palette != palette else { return }
        self.palette = palette
        backdrop = nil
        surface.background = palette.background
        scroll.scrollerKnobStyle = palette.theme == .dark ? .light : .dark
        inputs.values.forEach { $0.applyTheme(palette) }
        update()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect,cursor:.arrow)
    }

    /// Capture only native rendering behind the modal; never a frozen baseline.
    func captureBackdrop(from view:NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let image = bitmap.cgImage else { return }
        let source = CIImage(cgImage:image)
        let scale = CGFloat(image.width)/max(1,view.bounds.width)
        let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:5*scale]).cropped(to:source.extent)
        backdrop = imageContext.createCGImage(blurred,from:source.extent)
        needsDisplay = true
    }

    override func draw(_ dirtyRect:NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let backdrop {
            ctx.saveGState();ctx.translateBy(x:0,y:bounds.height);ctx.scaleBy(x:1,y:-1)
            ctx.draw(backdrop,in:bounds);ctx.restoreGState()
        }
        ctx.setFillColor(VPNDrawing.color(palette[.backdrop, light:0x15291f],alpha:102.0/255));ctx.fill(bounds)
        VPNDrawing.shadow(scroll.frame,radius:20,blur:90,offset:CGSize(width:0,height:25),color:palette[.shadow, light:0x142a27],alpha:64.0/255,in:ctx)
    }
    override func layout() {
        super.layout()
        let width = min(480,max(1,bounds.width-32)),height = min(contentHeight,max(1,bounds.height-32))
        scroll.frame = CGRect(x:(bounds.width-width)/2,y:(bounds.height-height)/2,width:width,height:height)
        surface.frame = CGRect(x:0,y:0,width:width,height:contentHeight)
    }

    func update() {
        guard let profile = model.state.profiles.first(where:{$0.id == profileID}) else { return }
        let palette = self.palette
        var scene = WorkspaceScene(palette:palette)
        routeScroll?.isHidden = true
        let width = min(480,max(1,bounds.width-32)),inner = max(1,width-52)
        let title:String,subtitle:String
        switch modal {
        case .credentials:
            title = profile.authKind == .pin ? "Enter your profile PIN" : "Connect to your network"
            subtitle = profile.name+(profile.username.isEmpty ? "" : " · \(profile.username)")
        case .settings: title = "Profile settings";subtitle = "Your network, your routing rules."
        case .delete:
            title = "Remove this profile?"
            subtitle = "\(profile.name) will be disconnected and removed from this Mac, together with its saved password. Your original .ovpn file is kept."
        }
        let header = DialogHeader.make(title:title,subtitle:subtitle,width:width,busy:model.busy,palette:palette)
        scene.append(header.scene)
        var y = header.bottom
        var used = Set<String>()
        switch modal {
        case .credentials:
            let credentials = CredentialsScene.make(profile:profile,width:width,top:y,busy:model.busy,
                hasPassword:!model.password.isEmpty,visible:model.passwordVisible,remember:model.rememberPassword,error:model.modalError,focused:focusedInput == "password",palette:palette)
            scene.append(credentials.scene)
            let field = input("password",label:"Password",rect:credentials.passwordRect,value:model.password,
                              secure:!model.passwordVisible,fontSize:13,maximum:4096,used:&used)
            field.showPassword(model.passwordVisible)
            field.changed = { [weak self] value in self?.model.password = value;self?.update() }
            field.submitted = { [weak self] in self?.perform(.submitCredentials) }
            y = credentials.bottom
        case .settings:
            if let editor {
                y = settings(&scene,editor:editor,profile:profile,y:y,width:width,used:&used)
            }
        case .delete:
            if !model.modalError.isEmpty { y += scene.paragraph(model.modalError,x:26,y:y,width:inner,color:palette[.errorText, light:0xa64035])+12 }
            y += 8
            let label = model.busy ? "Removing…" : "Remove profile"
            let removeWidth = max(98,ceil(VPNDrawing.textWidth(label,size:12,weight:550)*64)/64+36)
            scene.button("Cancel",x:width-26-removeWidth-108,y:y,action:.closeModal,enabled:!model.busy,fixedWidth:98,fontSize:12)
            scene.button(label,x:width-26-removeWidth,y:y,action:.confirmDelete,style:.danger,enabled:!model.busy,fixedWidth:removeWidth,fontSize:12)
            y += 42
        }
        contentHeight = y+26
        var full = WorkspaceScene(palette:palette)
        full.box(CGRect(x:0,y:0,width:width,height:contentHeight),radius:20,fill:palette[.background, light:0xfafbf8],border:palette[.border, light:0xe3e8dc])
        full.append(scene)
        surface.scene = full;surface.setRegions(scene.hits)
        for key in Set(inputs.keys).subtracting(used) { inputs.removeValue(forKey:key)?.removeFromSuperview() }
        surface.setAccessibilityLabel(title)
        needsLayout = true;needsDisplay = true
    }

    private func input(_ key:String,label:String,rect:CGRect,value:String,secure:Bool = false,
                       fontSize:CGFloat = 12,maximum:Int = 256,used:inout Set<String>) -> NativeTextInput {
        used.insert(key)
        let field:NativeTextInput
        if let existing = inputs[key] { field = existing }
        else {
            field = NativeTextInput(frame:rect,value:value,label:label,secure:secure,fontSize:fontSize,maximumLength:maximum)
            inputs[key] = field;surface.addSubview(field)
            field.focusChanged = { [weak self] focused in
                guard let self else { return }
                if focused { self.focusedInput = key }
                else if self.focusedInput == key { self.focusedInput = nil }
                // Editing notifications can arrive while replacing the secure
                // field. Rebuild after that operation, without re-entering it.
                Task { @MainActor [weak self] in self?.update() }
            }
        }
        field.frame = rect;field.update(value:value,enabled:!model.busy)
        field.applyTheme(palette)
        return field
    }

    private func settings(_ scene:inout WorkspaceScene,editor:ProfileEditor,profile:Profile,
                          y:CGFloat,width:CGFloat,used:inout Set<String>) -> CGFloat {
        let palette = self.palette
        let inner = width-52
        var y = y
        func field(_ key:String,_ label:String,_ value:String,_ maximum:Int,_ change:@escaping (String)->Void) {
            scene.text(label,x:26,y:y+12,size:11,weight:550,color:palette[.secondaryText, light:0x6f7d66])
            scene.box(CGRect(x:26,y:y+23,width:inner,height:40),radius:8,fill:palette[.surface, light:0xffffff],border:focusedInput == key ? palette[.focusBorder, light:0xa8afa4] : palette[.border, light:0xe5e9df])
            let control = input(key,label:label,rect:CGRect(x:36,y:y+24,width:inner-20,height:38),value:value,maximum:maximum,used:&used)
            control.changed = change
            control.submitted = { [weak self] in self?.perform(.saveProfile) }
            y += 77
        }
        field("name","Profile name",editor.draft.name,80) { [weak self] value in self?.editor?.draft.name = value;self?.update() }
        if profile.authKind != .certificate {
            field("username","Username",editor.draft.username,256) { [weak self] value in self?.editor?.draft.username = value }
        }
        y += 6
        scene.text("IPv4 routing",x:26,y:y+13,size:13,weight:700);y += 31
        let modeWidth = (inner-11)/2
        for (index,mode) in [RoutingMode.all,.selected].enumerated() {
            let x = 26+CGFloat(index)*(modeWidth+11),selected = editor.draft.routingMode == mode
            let modeRect = CGRect(x:x,y:y,width:modeWidth,height:73)
            scene.interactive(.editorRouting(mode),in:modeRect) { VPNDrawing.routingChoice(modeRect,selected:selected,hovered:$1.hovered,palette:palette,in:$0) }
            scene.text(mode == .all ? "All IPv4 traffic" : "Selected networks",x:x+34,y:y+24,size:10,weight:600)
            scene.paragraph(mode == .all ? "Route outgoing IPv4 via this VPN." : "Only the subnets you choose.",x:x+34,y:y+33,width:modeWidth-45,size:9,lineHeight:13.5,color:palette[.secondaryText, light:0x8a9480])
            scene.hits.append(WorkspaceHitRegion(rect:CGRect(x:x,y:y,width:modeWidth,height:73),title:mode == .all ? "All IPv4 traffic" : "Selected networks",action:.editorRouting(mode),enabled:!model.busy,role:.radio,checked:selected))
        }
        y += 93
        if editor.draft.routingMode == .selected {
            if editor.draft.routes.isEmpty {
                y += scene.paragraph("No IPv4 networks selected yet.",x:26,y:y,width:inner)
            }
            if !editor.draft.routes.isEmpty {
                var rows = WorkspaceScene(palette:palette)
                var rowY:CGFloat = 0
                for route in editor.draft.routes {
                    rows.box(CGRect(x:0,y:rowY,width:inner,height:51),radius:8,fill:palette[.raised, light:0xf0f3eb])
                    rows.text("\(route.address)/\(route.prefix)",x:12,y:rowY+30,size:12,mono:true)
                    rows.button("Remove \(route.address)/\(route.prefix)",x:inner-45,y:rowY+9,action:.removeRoute(route),style:.icon,icon:.trash,enabled:!model.busy)
                    rowY += 59
                }
                let scroll:NSScrollView,canvas:SceneCanvasView
                if let existing = routeScroll,let document = existing.documentView as? SceneCanvasView {
                    scroll = existing;canvas = document
                } else {
                    scroll = NSScrollView();canvas = SceneCanvasView()
                    scroll.documentView = canvas;scroll.borderType = .noBorder;scroll.drawsBackground = false
                    scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.scrollerStyle = .overlay
                    canvas.perform = { [weak self] in self?.perform($0) }
                    routeScroll = scroll;surface.addSubview(scroll)
                }
                let height = rowY-8
                scroll.isHidden = false;scroll.frame = CGRect(x:26,y:y,width:inner,height:min(180,height))
                scroll.scrollerKnobStyle = palette.theme == .dark ? .light : .dark
                canvas.background = palette.background
                canvas.frame = CGRect(x:0,y:0,width:inner,height:height)
                canvas.scene = rows;canvas.setRegions(rows.hits)
                y += min(180,height)
            }
            y += 24
            let addressWidth = floor((inner-67)*1.2/2.2*64)/64,subnetWidth = inner-67-addressWidth
            scene.text("IPv4 address",x:26,y:y+12,size:11,weight:550,color:palette[.secondaryText, light:0x6f7d66])
            scene.text("Prefix or subnet mask",x:34+addressWidth,y:y+12,size:11,weight:550,color:palette[.secondaryText, light:0x6f7d66])
            for (key,label,x,w,value) in [("address","IPv4 address",CGFloat(26),addressWidth,editor.address),
                                         ("subnet","Prefix or subnet mask",34+addressWidth,subnetWidth,editor.subnet)] {
                scene.box(CGRect(x:x,y:y+23,width:w,height:40),radius:8,fill:palette[.surface, light:0xffffff],border:focusedInput == key ? palette[.focusBorder, light:0xa8afa4] : palette[.border, light:0xe5e9df])
                let control = input(key,label:label,rect:CGRect(x:x+10,y:y+24,width:w-20,height:38),value:value,used:&used)
                control.field.placeholderString = key == "address" ? "10.0.0.0" : "24 / 255.255.255.0"
                control.applyTheme(palette)
                control.changed = { [weak self] value in
                    if key == "address" { self?.editor?.address = value } else { self?.editor?.subnet = value }
                }
                control.submitted = { [weak self] in self?.perform(.addRoute) }
            }
            scene.button("",x:width-77,y:y+23,action:.addRoute,style:.secondary,icon:.plus,enabled:!model.busy,fixedWidth:51)
            if let last = scene.hits.indices.last { scene.hits[last].title = "Add route" }
            y += 73
        } else {
            y -= 10
        }
        let checkRect = CGRect(x:28,y:y+3,width:12,height:12)
        scene.box(checkRect,radius:3,fill:editor.draft.allowLegacyCipher ? palette[.primaryButton, light:0x25674d] : palette[.surface, light:0xffffff],border:palette[.controlBorder, light:0x808080])
        if editor.draft.allowLegacyCipher { scene.icon(.check,x:29,y:y+4,size:10,color:palette[.onAccent, light:0xffffff]) }
        scene.hits.append(WorkspaceHitRegion(rect:CGRect(x:26,y:y,width:inner,height:18),title:"Allow AES-CBC compatibility for this profile",action:.toggleLegacyCipher,enabled:!model.busy,role:.checkbox,checked:editor.draft.allowLegacyCipher))
        scene.text("Allow AES-CBC compatibility for this profile",x:50,y:y+13,size:11);y += 18
        if profile.remembered {
            scene.text("PIN/password saved in Keychain",x:26,y:y+20,size:10,color:palette[.secondaryText, light:0x77847b])
            scene.button("Forget password",x:width-130,y:y,action:.forgetPassword,style:.text,enabled:!model.busy,fontSize:10)
            y += 50
        }
        if model.state.sessions.contains(where:{$0.profileId == profile.id && $0.active}) {
            scene.box(CGRect(x:26,y:y,width:inner,height:54),radius:8,fill:palette[.raised, light:0xedf3e5])
            scene.paragraph("Saving network changes reconnects this profile. Other profiles stay connected.",x:37,y:y+11,width:inner-22,size:10,lineHeight:16,color:palette[.secondaryText, light:0x7a8c6b])
            y += 69
        }
        let error = editor.validation.isEmpty ? model.modalError : editor.validation
        if !error.isEmpty { y += scene.paragraph(error,x:26,y:y,width:inner,color:palette[.errorText, light:0xa64035])+12 }
        y += 28
        let label = model.busy ? "Saving…" : "Save changes",bw = max(98,ceil(VPNDrawing.textWidth(label,size:12,weight:550)*64)/64+36)
        scene.button("Cancel",x:width-26-bw-108,y:y,action:.closeModal,enabled:!model.busy,fixedWidth:98,fontSize:12)
        scene.button(label,x:width-26-bw,y:y,action:.saveProfile,style:.primary,enabled:!model.busy && !editor.draft.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,fixedWidth:bw,fontSize:12)
        return y+42
    }

    private func perform(_ action:WorkspaceAction) {
        guard !model.busy else { return }
        switch action {
        case .closeModal: clearSecrets();model.closeModal();changed?()
        case .togglePassword: model.passwordVisible.toggle();update()
        case .toggleRemember: model.rememberPassword.toggle();update()
        case .editorRouting(let mode): editor?.draft.routingMode = mode;update()
        case .toggleLegacyCipher: editor?.draft.allowLegacyCipher.toggle();update()
        case .removeRoute(let route): editor?.removeRoute(route);update()
        case .addRoute: editor?.addRoute();update()
        case .submitCredentials:
            Task { await model.submitCredentials();update();changed?() }
        case .confirmDelete:
            Task { await model.deleteProfile();changed?() }
        case .saveProfile:
            guard let update = editor?.validatedUpdate() else { update();return }
            Task { await model.saveProfile(update);self.update();changed?() }
        case .forgetPassword:
            Task { await model.forget();update();changed?() }
        default: break
        }
    }
    func focusInitial() {
        if let field = inputs["password"] ?? inputs["name"] { field.focus() }
        else { window?.makeFirstResponder(self) }
    }
    func clearSecrets() { inputs["password"]?.clear() }
    override func cancelOperation(_ sender:Any?) { perform(.closeModal) }
}
