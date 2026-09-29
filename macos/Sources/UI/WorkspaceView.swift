import AppKit

/// Native button semantics (keyboard, accessibility, enabled state) over the
/// shared renderer. Static text never becomes a selectable text view.
@MainActor
final class SceneActionButton: NSButton {
    var handler: (() -> Void)?
    var feedbackChanged:(() -> Void)?
    private(set) var hovered = false
    private(set) var pressed = false
    private var area:NSTrackingArea?
    var cursorSuppressed = false { didSet { if oldValue != cursorSuppressed { invalidateCursor() } } }
    override var isEnabled:Bool { didSet { if oldValue != isEnabled { invalidateCursor() } } }
    var showsPointingHand:Bool { isEnabled && !cursorSuppressed && !isHiddenOrHasHiddenAncestor }
    var pointingHandRect:NSRect? {
        let rect = bounds.intersection(visibleRect)
        return showsPointingHand && !rect.isEmpty ? rect : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty,!isHiddenOrHasHiddenAncestor else { return }
        addCursorRect(rect,cursor:pointingHandRect != nil ? .pointingHand : .arrow)
    }
    private func invalidateCursor() {
        if !isEnabled || cursorSuppressed { hovered = false }
        window?.invalidateCursorRects(for:self)
        feedbackChanged?()
    }

    init(region: WorkspaceHitRegion, handler: @escaping () -> Void) {
        super.init(frame:region.rect)
        self.handler = handler
        title = region.title; isEnabled = region.enabled
        isBordered = false; setButtonType(.momentaryPushIn)
        focusRingType = .exterior
        target = self; action = #selector(invoke)
        setAccessibilityLabel(region.title)
        updateAccessibility(region)
    }
    required init?(coder:NSCoder) { fatalError("Programmatic native view") }
    override var isOpaque:Bool { false }
    override func draw(_ dirtyRect:NSRect) {}
    override var focusRingMaskBounds:NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect:bounds,xRadius:9,yRadius:9).fill() }
    override func highlight(_ flag:Bool) {
        super.highlight(flag);pressed = flag;feedbackChanged?()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);self.area = area
        invalidateCursor()
    }
    override func mouseEntered(with event:NSEvent) { hovered = showsPointingHand;feedbackChanged?() }
    override func mouseExited(with event:NSEvent) { hovered = false;feedbackChanged?() }
    @objc private func invoke() { guard isEnabled else { return }; handler?() }
    func updateAccessibility(_ region:WorkspaceHitRegion) {
        switch region.role {
        case .button:setAccessibilityRole(.button)
        case .radio:setAccessibilityRole(.radioButton);setAccessibilityValue(region.checked ? 1 : 0)
        case .checkbox:setAccessibilityRole(.checkBox);setAccessibilityValue(region.checked ? 1 : 0)
        }
    }
}

@MainActor
final class SceneCanvasView: NSView {
    var render: ((CGContext) -> Void)? { didSet { needsDisplay = true } }
    var interactiveRender: ((CGContext,(WorkspaceAction,CGRect)->WorkspaceScene.Feedback) -> Void)? { didSet { needsDisplay = true } }
    var scene:WorkspaceScene? { didSet { needsDisplay = true } }
    var background:UInt32 = 0xfafbf8
    private var regions:[WorkspaceHitRegion] = []
    private var buttons:[SceneActionButton] = []
    var cursorSuppressed = false { didSet { buttons.forEach { $0.cursorSuppressed = cursorSuppressed } } }
    private(set) var connectionView:ConnectionPanelView?
    var perform:((WorkspaceAction) -> Void)?
    override var isFlipped:Bool { true }
    override var isOpaque:Bool { true }

    override func draw(_ dirtyRect:NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(VPNDrawing.color(background));context.fill(bounds)
        render?(context)
        interactiveRender?(context,feedback)
        scene?.draw(in:context,feedback:feedback)
    }

    private func feedback(_ action:WorkspaceAction,_ rect:CGRect) -> WorkspaceScene.Feedback {
        guard let index = regions.firstIndex(where:{$0.action == action && $0.rect == rect}),index < buttons.count else { return .init() }
        let button = buttons[index]
        return WorkspaceScene.Feedback(hovered:button.isEnabled && button.hovered,pressed:button.isEnabled && button.pressed)
    }

    func setConnection(_ rect:CGRect?,state:ConnectionPresentation,palette:ThemePalette,epoch:CFTimeInterval) {
        guard let rect else {
            connectionView?.artwork.setRunning(false);connectionView?.removeFromSuperview();connectionView = nil;return
        }
        if connectionView == nil {
            let view = ConnectionPanelView(frame:rect)
            addSubview(view,positioned:.below,relativeTo:subviews.first);connectionView = view
        }
        connectionView?.frame = rect
        connectionView?.update(state,palette:palette,epoch:epoch)
    }

    func setRegions(_ next:[WorkspaceHitRegion]) {
        // Reuse controls when traffic counters change, preserving keyboard focus.
        let same = regions.count == next.count && zip(regions,next).allSatisfy { $0.action == $1.action && $0.rect == $1.rect }
        if same {
            for (button,region) in zip(buttons,next) {
                button.title = region.title;button.setAccessibilityLabel(region.title);button.isEnabled = region.enabled
                button.updateAccessibility(region)
            }
        } else {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = next.map { region in
                let button = SceneActionButton(region:region) { [weak self] in self?.perform?(region.action) }
                button.cursorSuppressed = cursorSuppressed
                button.feedbackChanged = { [weak self,weak button] in
                    guard let self,let button else { return }
                    if region.action == .toggle,let panel = self.connectionView {
                        panel.artwork.setFeedback(.init(hovered:button.isEnabled && button.hovered,pressed:button.isEnabled && button.pressed))
                    } else { self.needsDisplay = true }
                }
                addSubview(button);return button
            }
        }
        regions = next
    }
}

@MainActor
final class WorkspaceView: NSView {
    private let sidebarScroll = NSScrollView()
    private let contentScroll = NSScrollView()
    private let sidebar = SceneCanvasView()
    private let content = SceneCanvasView()
    private let header = SceneCanvasView()
    private let footer = SceneCanvasView()
    private let toast = ToastView(frame:.zero)
    private var toastText = ""
    private var state: WorkspacePresentation?
    private var connection = ConnectionPresentation()
    private var clock:UInt64 = 0
    private var error = ""
    private var loaded = false
    private var animationOrigin = CACurrentMediaTime()
    private var structuralDirty = true
    private var coveredByModal = false
    private var displayAsleep = false
    private var observers:[NSObjectProtocol] = []
    private let environmentOverride:(() -> RenderingEnvironment)?
    private(set) var sceneBuilds = 0
    var panelArtwork:ConnectionLayers? { content.connectionView?.artwork }
    private var previousProfileID:String?
    private var previousScreen:WorkspaceScreen?
    private var accessibilityObserver:NSObjectProtocol?
    private(set) var palette:ThemePalette = .light
    private var themePreference:ThemePreference = .system
    var perform:((WorkspaceAction) -> Void)?
    override var isFlipped:Bool { true }

    init(frame:NSRect,environment:(() -> RenderingEnvironment)? = nil) {
        environmentOverride = environment
        super.init(frame:frame)
        sidebar.background = 0x1c3029
        for (scroll,document) in [(sidebarScroll,sidebar),(contentScroll,content)] {
            scroll.documentView = document
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true;scroll.scrollerStyle = .overlay
            addSubview(scroll)
        }
        addSubview(header);addSubview(footer);addSubview(toast)
        for surface in [sidebar,content,footer] { surface.perform = { [weak self] in self?.perform?($0) } }
        setAccessibilityRole(.group);setAccessibilityLabel("VueVPN workspace")
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,object:nil,queue:.main
        ) { [weak self] _ in Task { @MainActor in self?.refreshAnimation() } }
    }
    required init?(coder:NSCoder) { fatalError("Programmatic native view") }

    private var environment:RenderingEnvironment {
        var result = environmentOverride?() ?? RenderingEnvironment(
            windowVisible:window?.isVisible == true,occluded:window?.occlusionState.contains(.visible) != true,
            minimized:window?.isMiniaturized == true,applicationHidden:NSApp?.isHidden == true,displayAsleep:displayAsleep)
        result.coveredByModal = coveredByModal
        result.panelVisible = content.connectionView?.hasVisibleAnimation ?? false
        result.overview = state?.screen == .overview;result.activeConnection = connection.status.active && !connection.disconnectStalled
        result.reduceMotion = environmentOverride?().reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return result
    }

    func applyTheme(_ palette:ThemePalette,preference:ThemePreference) {
        guard self.palette != palette || themePreference != preference else { return }
        self.palette = palette;themePreference = preference
        state?.palette = palette;state?.themePreference = preference
        sidebar.background = palette[.sidebar,light:0x1c3029]
        for canvas in [content,header,footer] { canvas.background = palette.background }
        for scroll in [sidebarScroll,contentScroll] { scroll.scrollerKnobStyle = palette.theme == .dark ? .light : .dark }
        toast.applyTheme(palette)
        structuralDirty = true;refreshAnimation()
    }

    func setCoveredByModal(_ covered:Bool) {
        guard coveredByModal != covered else { return }
        coveredByModal = covered
        for canvas in [sidebar,content,header,footer] { canvas.cursorSuppressed = covered }
        refreshAnimation()
    }

    func update(_ model:WorkspaceModel) {
        let oldStructure = state?.structure,oldError = error,oldLoaded = loaded
        let oldConnection = connection
        state = WorkspacePresentation(snapshot:model.state,selectedID:model.selectedID,screen:model.screen,busy:model.busy || model.quitting,themePreference:themePreference,palette:palette)
        var status = model.session?.status ?? .disconnected
        if model.isConnecting { status = .connecting }
        if model.isDisconnecting { status = .disconnecting }
        if status != connection.status || state?.selectedID != previousProfileID { animationOrigin = CACurrentMediaTime() }
        connection = ConnectionPresentation(status:status,authKind:model.selected?.authKind ?? .pin,
            buttonDisabled:model.connectionButtonDisabled,disconnectStalled:model.session?.disconnectStalled == true,address:model.session?.address ?? "",
            duration:VPNFormat.duration(since:model.session?.connectedAt,now:model.clock),
            transport:model.selected?.protocol.uppercased() ?? "UDP",bytesIn:model.session?.bytesIn ?? 0,bytesOut:model.session?.bytesOut ?? 0)
        error = model.error;loaded = model.loaded;clock = model.clock;toastText = model.toast
        structuralDirty = structuralDirty || oldStructure != state?.structure || oldError != error || oldLoaded != loaded || oldConnection.status != connection.status || oldConnection.buttonDisabled != connection.buttonDisabled
        if previousProfileID != model.selectedID || previousScreen != model.screen {
            pendingScrollReset = true
            previousProfileID = model.selectedID;previousScreen = model.screen
        }
        refreshAnimation()
    }

    private var lastLayoutSize = CGSize.zero
    private var pendingScrollReset = false
    override func layout() {
        super.layout()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size;structuralDirty = true
        let mainWidth = max(1,bounds.width-194)
        sidebarScroll.frame = CGRect(x:0,y:0,width:194,height:bounds.height)
        header.frame = CGRect(x:194,y:0,width:mainWidth,height:50)
        contentScroll.frame = CGRect(x:194,y:50,width:mainWidth,height:max(0,bounds.height-91))
        footer.frame = CGRect(x:194,y:max(50,bounds.height-41),width:mainWidth,height:41)
        refreshAnimation()
    }

    private func rebuild() {
        guard let state else { return }
        sceneBuilds += 1;structuralDirty = false
        let palette = self.palette
        let mainWidth = max(1,bounds.width-194)
        rebuildContent()
        let sidebarHeight = max(bounds.height,CGFloat(399+72*state.snapshot.profiles.count))
        sidebar.frame.size = CGSize(width:194,height:sidebarHeight)
        // Geometry is independent of drawing; a tiny unshown context only records
        // the renderer's hit targets and is never an NSWindow or application view.
        let geometry = CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        geometry.clip(to:.zero)
        let sidebarSize = sidebar.frame.size
        let sidebarHits = WorkspaceChrome.sidebar(state,size:sidebarSize,context:geometry)
        sidebar.interactiveRender = { _ = WorkspaceChrome.sidebar(state,size:sidebarSize,context:$0,feedback:$1) };sidebar.setRegions(sidebarHits)
        header.render = { WorkspaceChrome.header(state,width:mainWidth,context:$0) }
        let footerHit = WorkspaceChrome.footer(width:mainWidth,context:geometry,palette:palette)
        footer.render = { _ = WorkspaceChrome.footer(width:mainWidth,context:$0,palette:palette) };footer.setRegions([footerHit])
    }

    private func rebuildContent() {
        guard let state else { return }
        let width = max(1,bounds.width-194)
        connection.phase = CACurrentMediaTime()-animationOrigin
        connection.reduceMotion = environment.reduceMotion
        let scene = WorkspaceContent.make(state,width:width,clock:clock,connection:connection,error:error,loaded:loaded,retainedConnection:true)
        content.frame.size = CGSize(width:width,height:max(scene.height,contentScroll.contentSize.height))
        content.scene = scene
        content.setConnection(scene.connectionPanel,state:connection,palette:palette,epoch:animationOrigin)
        content.setRegions(scene.hits)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeLifecycleObservers()
        guard window != nil else { stopAnimation();return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didChangeBackingPropertiesNotification] {
            observers.append(center.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.refreshAnimation() }
            })
        }
        for name in [NSApplication.didHideNotification,NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.refreshAnimation() } })
        }
        contentScroll.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName:NSView.boundsDidChangeNotification,object:contentScroll.contentView,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.refreshAnimation() }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification,NSWorkspace.screensDidWakeNotification,NSWorkspace.willSleepNotification,NSWorkspace.didWakeNotification] {
            observers.append(workspaceCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                let asleep = notification.name == NSWorkspace.screensDidSleepNotification || notification.name == NSWorkspace.willSleepNotification
                Task { @MainActor in self?.displayAsleep = asleep;self?.refreshAnimation() }
            })
        }
        refreshAnimation()
    }
    func refreshAnimation() {
        guard environment.rendersWorkspace else { stopAnimation();return }
        if pendingScrollReset { pendingScrollReset = false;contentScroll.contentView.scroll(to:.zero) }
        if structuralDirty { rebuild() }
        else {
            connection.reduceMotion = environment.reduceMotion
            content.connectionView?.update(connection,palette:palette,epoch:animationOrigin)
        }
        toast.update(toastText,in:bounds)
        content.connectionView?.artwork.setRunning(environment.animates)
    }
    // Explicit preparation for a one-off modal backdrop, never from polling.
    func prepareBackdrop() {
        if structuralDirty { rebuild() }
        stopAnimation()
    }
    func stopAnimation() { content.connectionView?.artwork.setRunning(false) }
    private func removeLifecycleObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
    func dispose() {
        stopAnimation();removeLifecycleObservers()
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
    }
}
