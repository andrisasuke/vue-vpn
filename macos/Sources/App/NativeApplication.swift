import AppKit
import Observation
import UniformTypeIdentifiers

@main
enum NativeApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationController()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ApplicationController:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private let model:WorkspaceModel
    private let menu = MenuBarController()
    private let stats = SystemStatsService(platform:NativeSystemStatsEnvironment())
    private let statsMenu = StatsMenuBarController()
    private let statsMenuVisibility = StatsMenuVisibilitySettings(store:UserDefaultsStatsMenuVisibilityStore(defaults:.standard))
    private let statsMenuStyles = StatsMenuStyleSettings(store:UserDefaultsStatsMenuStyleStore(defaults:.standard))
    private let statsMonitoring = StatsMonitoringSettings(store:UserDefaultsStatsMonitoringStore(defaults:.standard))
    private var powerObserver: NSObjectProtocol?
    private let theme = ThemeSettings(store:UserDefaultsThemeStore(defaults:.standard))
    private var palette:ThemePalette = .light
    private var applyingAppearance = false
    private var window:NSWindow?
    private var root:NSView?
    private var workspace:WorkspaceView?
    private var dialog:ProfileDialog?
    private var observing = false
    private var importOpen = false
    private var terminationApproved = false
    private struct DialogState:Equatable {
        var modal:WorkspaceModal?
        var profile:Profile?
        var busy:Bool
        var hasPassword:Bool
        var passwordVisible:Bool
        var remember:Bool
        var error:String
        var active:Bool
    }
    private var dialogState:DialogState?
    private weak var previousResponder:NSResponder?

    override init() {
        let worker = BackendWorker {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.vuevpn.desktop/profiles",isDirectory:true)
            return try VPNBackend(store:ProfileStore(root:root),bridge:NativeBridge(),clock:SystemVPNClock())
        }
        model = WorkspaceModel(backend:worker)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification:Notification) {
        if let identifier = Bundle.main.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier:identifier)
            .first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}) {
            running.activate(options:[])
            terminationApproved = true;NSApplication.shared.terminate(nil);return
        }
        installApplicationMenu()
        let view = WorkspaceView(frame:CGRect(x:0,y:0,width:960,height:720))
        let window = NSWindow(contentRect:view.bounds,styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title = "VueVPN";window.titleVisibility = .hidden;window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width:800,height:600)
        window.contentMinSize = NSSize(width:800,height:600)
        window.isReleasedWhenClosed = false;window.delegate = self
        let root = AppearanceRootView(frame:view.bounds)
        view.autoresizingMask = [.width,.height];root.addSubview(view)
        window.contentView = root;window.center()
        self.window = window;workspace = view;self.root = root
        root.appearanceChanged = { [weak self] in self?.refreshAppearance() }
        applyAppearance()
        view.perform = { [weak self] in self?.perform($0) }
        view.setStatsMenuVisibility(statsMenuVisibility.visiblePages)
        view.setStatsMenuStyles(statsMenuStyles.styles)
        view.visibilityChanged = { [weak self] in self?.stats.setVisiblePage($0) }
        view.sleepChanged = { [weak self] in self?.stats.setSleeping($0) }
        menu.perform = { [weak self] action in
            guard let self else { return }
            switch action {
            case .open: self.showWindow()
            case .profile(let id):
                Task { await self.model.toggleFromMenu(id);if self.model.modal != nil || self.model.screen == .setup { self.showWindow() } }
            case .disconnectAll: Task { await self.model.disconnectAll() }
            case .quit: NSApplication.shared.terminate(nil)
            }
        }
        menu.install()
        statsMenu.open = { [weak self] page in
            guard let self,let screen = WorkspaceScreen(rawValue:page.rawValue) else { return }
            self.model.screen = screen
            self.showWindow()
            self.observe()
        }
        stats.changed = { [weak self] value in
            self?.statsMenu.update(value)
            self?.workspace?.updateStats(value)
        }
        for page in StatsPage.allCases where !statsMonitoring.enabledPages.contains(page) {
            stats.setMonitoring(page,enabled:false)
        }
        view.updateStats(stats.snapshot)
        statsMenu.setVisiblePages(statsMenuVisibility.visiblePages.intersection(statsMonitoring.enabledPages))
        statsMenu.setStyles(statsMenuStyles.styles)
        statsMenu.install()
        statsMenu.update(stats.snapshot)
        if let savedTarget = UserDefaults.standard.string(forKey:"VueVPNStatsProbeTarget") {
            _ = stats.setProbeTarget(savedTarget)
        }
        stats.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        powerObserver = NotificationCenter.default.addObserver(forName:Notification.Name.NSProcessInfoPowerStateDidChange,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.stats.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        }
        stats.start()
        observing = true;observe()
        showWindow()
        model.startPolling()
    }

    private func observe() {
        guard observing else { return }
        withObservationTracking {
            workspace?.update(model)
            menu.update(MenuPresentation(snapshot:model.state,busy:model.busy,quitting:model.quitting,
                connectingID:model.connectingID,disconnectingID:model.disconnectingID))
            let context = model.state.sessions.filter(\.active).sorted { $0.profileId < $1.profileId }
                .map { "\($0.profileId):\($0.sessionId):\($0.status.rawValue)" }.joined(separator:"|")
            stats.setVPNContext(context)
            updateDialog()
            window?.isDocumentEdited = false
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func updateDialog() {
        guard let workspace,let root else { return }
        let next = DialogState(modal:model.modal,profile:model.modalProfile,busy:model.busy,
            hasPassword:!model.password.isEmpty,passwordVisible:model.passwordVisible,remember:model.rememberPassword,
            error:model.modalError,active:model.state.sessions.contains { $0.profileId == model.modalProfile?.id && $0.active })
        workspace.setCoveredByModal(model.modal != nil)
        if let modal = model.modal,let profile = model.modalProfile {
            if dialog?.matches(modal) != true {
                if dialog == nil { previousResponder = window?.firstResponder }
                dialog?.clearSecrets();dialog?.removeFromSuperview()
                let view = ProfileDialog(model:model,modal:modal,profile:profile)
                view.frame = workspace.bounds;view.autoresizingMask = [.width,.height]
                view.applyTheme(palette)
                workspace.prepareBackdrop();view.captureBackdrop(from:workspace)
                root.addSubview(view,positioned:.above,relativeTo:nil)
                view.changed = { [weak self] in self?.updateDialog() }
                dialog = view
                dialogState = next
                root.setAccessibilityChildren([view])
                view.update();view.layoutSubtreeIfNeeded();view.focusInitial()
            } else {
                if dialogState != next { dialog?.update();dialogState = next }
            }
        } else {
            let wasOpen = dialog != nil
            dialog?.clearSecrets();dialog?.removeFromSuperview();dialog = nil
            root.setAccessibilityChildren([workspace])
            dialogState = nil
            if wasOpen { window?.makeFirstResponder(previousResponder);previousResponder = nil }
        }
    }

    private func perform(_ action:WorkspaceAction) {
        switch action {
        case .theme(let preference):theme.select(preference);applyAppearance()
        case .screen(let screen):model.screen = screen
        case .toggleStatsMenu(let page):
            guard statsMonitoring.enabledPages.contains(page) else { return }
            statsMenuVisibility.toggle(page)
            statsMenu.setVisiblePages(statsMenuVisibility.visiblePages.intersection(statsMonitoring.enabledPages))
            workspace?.setStatsMenuVisibility(statsMenuVisibility.visiblePages)
        case .toggleStatsMonitoring(let page):
            statsMonitoring.toggle(page)
            stats.setMonitoring(page,enabled:statsMonitoring.enabledPages.contains(page))
            statsMenu.setVisiblePages(statsMenuVisibility.visiblePages.intersection(statsMonitoring.enabledPages))
        case .statsMenuStyle(let page,let style):
            guard statsMonitoring.enabledPages.contains(page) else { return }
            statsMenuStyles.select(style,for:page)
            statsMenu.setStyles(statsMenuStyles.styles)
            workspace?.setStatsMenuStyles(statsMenuStyles.styles)
        case .selectStatsInterface:
            let ids = stats.snapshot.interfaces.map(\.id)
            let current = stats.snapshot.automaticInterface ? nil : stats.snapshot.selectedInterface
            let choices: [String?] = [nil] + ids.map(Optional.some)
            let index = choices.firstIndex(where:{$0 == current}) ?? 0
            stats.selectInterface(choices[(index+1)%choices.count])
        case .refreshPublicAddress:stats.refreshPublicAddress()
        case .editProbeTarget:
            guard statsMonitoring.enabledPages.contains(.network) else { return }
            editProbeTarget()
        case .profile(let id):model.selectedID = id;model.screen = .overview
        case .dismissError:model.error = ""
        case .importProfile:importProfile()
        case .edit:if let profile = model.selected { model.openModal(.settings(profile.id)) }
        case .delete:if let profile = model.selected { model.openModal(.delete(profile.id)) }
        case .toggle:Task { await model.toggle() }
        case .disconnectAll:Task { await model.disconnectAll() }
        case .helper(let operation):Task { await model.helperAction(operation) }
        default:break // Modal actions are owned by ProfileDialog.
        }
    }

    private func importProfile() {
        guard !model.busy,!importOpen,let window else { return }
        importOpen = true
        let panel = NSOpenPanel()
        panel.appearance = window.appearance
        panel.title = "Import OpenVPN profile"
        panel.allowedContentTypes = [UTType(filenameExtension:"ovpn") ?? .data]
        panel.allowsMultipleSelection = false;panel.canChooseDirectories = false;panel.canChooseFiles = true
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }
            self.importOpen = false
            guard response == .OK,let url = panel.url else { return }
            Task { await self.model.importProfile(url) }
        }
    }

    private func editProbeTarget() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Connectivity target"
        alert.informativeText = "Enter a hostname or IP address. VueVPN checks TCP port 443 only while Network is visible."
        alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel")
        let field = NSTextField(string:stats.snapshot.connectivity.target)
        field.frame = NSRect(x:0,y:0,width:300,height:24)
        field.placeholderString = "1.1.1.1"
        alert.accessoryView = field
        workspace?.setCoveredByModal(true)
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }
            self.workspace?.setCoveredByModal(false)
            if response == .alertFirstButtonReturn,self.stats.setProbeTarget(field.stringValue) {
                UserDefaults.standard.set(self.stats.snapshot.connectivity.target,forKey:"VueVPNStatsProbeTarget")
            }
        }
    }

    @objc private func showWindow() {
        applyAppearance()
        window?.deminiaturize(nil);window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps:true)
        workspace?.refreshAnimation()
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { showWindow();return true }

    private func applyAppearance() {
        guard let window,!applyingAppearance else { return }
        applyingAppearance = true
        switch theme.preference {
        case .light:window.appearance = NSAppearance(named:.aqua)
        case .dark:window.appearance = NSAppearance(named:.darkAqua)
        case .system:window.appearance = nil
        }
        applyingAppearance = false
        refreshAppearance()
    }

    private func refreshAppearance() {
        guard let window,!applyingAppearance else { return }
        let resolved = theme.preference.resolved(system:ThemePalette.resolve(window.effectiveAppearance))
        palette = ThemePalette(theme:resolved)
        window.backgroundColor = NSColor(cgColor:VPNDrawing.color(palette.background))!
        workspace?.applyTheme(palette,preference:theme.preference)
        if let dialog,let workspace {
            dialog.applyTheme(palette)
            workspace.layoutSubtreeIfNeeded();workspace.prepareBackdrop()
            dialog.captureBackdrop(from:workspace)
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { sender.orderOut(nil);workspace?.stopAnimation();stats.setVisiblePage(nil);return false }
    func windowDidBecomeKey(_ notification:Notification) { workspace?.refreshAnimation() }
    func windowDidDeminiaturize(_ notification:Notification) { workspace?.refreshAnimation() }
    func windowDidMiniaturize(_ notification:Notification) { workspace?.refreshAnimation() }
    func windowDidResize(_ notification:Notification) {
        dialog?.update()
        if let workspace,dialog != nil { workspace.prepareBackdrop();dialog?.captureBackdrop(from:workspace) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard !model.busy,!model.quitting else { return .terminateCancel }
        Task {
            let clean = await model.prepareToQuit()
            terminationApproved = clean
            if !clean { showWindow() }
            sender.reply(toApplicationShouldTerminate:clean)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification) {
        observing = false;model.stopPolling();stats.stop();workspace?.dispose();dialog?.clearSecrets();menu.remove();statsMenu.remove()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }

    private func installApplicationMenu() {
        let root = NSMenu()
        let application = NSMenuItem(),appMenu = NSMenu(title:"VueVPN")
        let about = NSMenuItem(title:"About VueVPN",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        about.target = NSApplication.shared;appMenu.addItem(about);appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Hide VueVPN",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit VueVPN",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        application.submenu = appMenu;root.addItem(application)
        let editItem = NSMenuItem(),edit = NSMenu(title:"Edit")
        for (label,selector,key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {
            edit.addItem(withTitle:label,action:NSSelectorFromString(selector),keyEquivalent:key)
        }
        editItem.submenu = edit;root.addItem(editItem)
        let windowItem = NSMenuItem(),windowMenu = NSMenu(title:"Window")
        let open = NSMenuItem(title:"Open VueVPN",action:#selector(showWindow),keyEquivalent:"0")
        open.target = self;windowMenu.addItem(open)
        windowMenu.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowItem.submenu = windowMenu;root.addItem(windowItem)
        NSApplication.shared.mainMenu = root
    }
}
