import XCTest
import AppKit

@MainActor final class ThemeTests:XCTestCase {
    private struct NoBackend:BackendExecuting {
        func execute(_ command:BackendCommand) async -> BackendResult {
            XCTFail("Changing appearance must not call the VPN backend")
            return BackendResult(failure:AppError("test","No backend"))
        }
    }
    private var output:URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("artifacts/migration/themes")
    }
    private func fixture(_ name:String) throws -> Snapshot {
        struct Fixture:Decodable { let snapshot:Snapshot }
        let path = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .appendingPathComponent("References/\(name).json")
        return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:path)).snapshot
    }
    private func render(_ name:String,size:CGSize,draw:(CGContext)->Void) throws -> CGImage {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let context = try XCTUnwrap(CGContext(data:nil,width:Int(size.width*2),height:Int(size.height*2),bitsPerComponent:8,
            bytesPerRow:Int(size.width*2)*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x:2,y:2);context.translateBy(x:0,y:size.height);context.scaleBy(x:1,y:-1)
        draw(context)
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
        try data.write(to:output.appendingPathComponent("\(name).png"))
        return image
    }

    func testAppearanceChoicesFitAndRemainEnabledDuringVPNOperations() throws {
        let snapshot = try fixture("settings-enabled")
        for width:CGFloat in [606,766] {
            for theme in ResolvedTheme.allCases {
                for choice in ThemePreference.allCases {
                    let state = WorkspacePresentation(snapshot:snapshot,selectedID:"",screen:.setup,busy:true,themePreference:choice,palette:ThemePalette(theme:theme))
                    let scene = WorkspaceContent.make(state,width:width,clock:1,connection:.init())
                    let choices = scene.hits.filter { if case .theme = $0.action { return true };return false }
                    XCTAssertEqual(choices.map(\.title),["Light","Dark","System"])
                    XCTAssertEqual(choices.filter(\.checked).map(\.action),[.theme(choice)])
                    XCTAssertTrue(choices.allSatisfy { $0.enabled && $0.role == .radio && $0.rect.minX >= 24 && $0.rect.maxX <= width-24 })
                    for pair in zip(choices,choices.dropFirst()) { XCTAssertFalse(pair.0.rect.intersects(pair.1.rect)) }
                    let helper = try XCTUnwrap(scene.hits.first { $0.action == .helper("settings") })
                    XCTAssertGreaterThan(helper.rect.minY,choices.last!.rect.maxY)
                }
            }
        }
    }

    func testDarkTextMeetsContrastRequirement() {
        func luminance(_ rgb:UInt32) -> Double {
            func channel(_ shift:UInt32) -> Double {
                let value = Double((rgb >> shift)&255)/255.0
                return value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4)
            }
            return channel(16)*0.2126 + channel(8)*0.7152 + channel(0)*0.0722
        }
        func contrast(_ a:UInt32,_ b:UInt32) -> Double {
            let a = luminance(a),b = luminance(b)
            return (max(a,b)+0.05)/(min(a,b)+0.05)
        }
        let p = ThemePalette.dark
        for background in [p.background,p.surface,p[.raised,light:0],p[.connection,light:0],p[.selected,light:0],p[.gradientStart,light:0]] {
            for text in [p.text,p.secondaryText,p[.accent,light:0]] { XCTAssertGreaterThanOrEqual(contrast(text,background),4.5) }
        }
        for button in [p[.primaryButton,light:0],p[.primaryHover,light:0],p[.dangerButton,light:0]] {
            XCTAssertGreaterThanOrEqual(contrast(p[.onAccent,light:0],button),4.5)
        }
        XCTAssertGreaterThanOrEqual(contrast(p[.errorText,light:0],p[.errorSurface,light:0]),4.5)
    }

    func testNativeAppearanceResolvesAndLightPalettePreservesSourceColors() throws {
        XCTAssertEqual(ThemePalette.resolve(try XCTUnwrap(NSAppearance(named:.aqua))),.light)
        XCTAssertEqual(ThemePalette.resolve(try XCTUnwrap(NSAppearance(named:.darkAqua))),.dark)
        XCTAssertEqual(ThemePalette.resolve(try XCTUnwrap(NSAppearance(named:.accessibilityHighContrastDarkAqua))),.dark)
        for role in ThemePalette.Role.allCases {
            for color:UInt32 in [0xffffff,0x25674d,0x77847b] { XCTAssertEqual(ThemePalette.light[role,light:color],color) }
        }
        XCTAssertNotEqual(ThemePalette.dark[.surface,light:0xffffff],ThemePalette.dark[.onAccent,light:0xffffff])
    }

    func testCursorTracksEnabledVisibilityAndModalCoverage() {
        let parent = NSView(frame:CGRect(x:0,y:0,width:80,height:40))
        parent.clipsToBounds = true
        let button = SceneActionButton(region:.init(rect:CGRect(x:20,y:0,width:100,height:40),title:"Connect",action:.toggle)) {}
        parent.addSubview(button)
        XCTAssertTrue(button.showsPointingHand)
        XCTAssertEqual(button.pointingHandRect?.width,60)
        button.isEnabled = false;XCTAssertNil(button.pointingHandRect)
        button.isEnabled = true;XCTAssertNotNil(button.pointingHandRect)
        button.cursorSuppressed = true;XCTAssertNil(button.pointingHandRect)
        button.cursorSuppressed = false;XCTAssertNotNil(button.pointingHandRect)
        parent.isHidden = true;XCTAssertNil(button.pointingHandRect)
        parent.isHidden = false
        button.frame.origin.x = 100;XCTAssertNil(button.pointingHandRect)
        XCTAssertNil(button.window)
    }

    func testThemeSwitchPreservesNativeInputIdentityValueAndGeometry() {
        for secure in [true,false] {
            let input = NativeTextInput(frame:CGRect(x:0,y:0,width:240,height:38),value:"synthetic",label:"Input",secure:secure)
            input.field.placeholderString = "Enter value"
            let field = input.field,rect = field.frame
            for palette in [ThemePalette.dark,.light,.dark] {
                input.applyTheme(palette)
                XCTAssertTrue(input.field === field)
                XCTAssertEqual(input.field.stringValue,"synthetic")
                XCTAssertEqual(input.field.frame,rect)
                XCTAssertEqual(input.field.textColor,NSColor(cgColor:VPNDrawing.color(palette.text)))
                XCTAssertEqual(input.field.placeholderString ?? input.field.placeholderAttributedString?.string,"Enter value")
                XCTAssertEqual(input.field.placeholderAttributedString?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor,
                    NSColor(cgColor:VPNDrawing.color(palette.secondaryText)))
                XCTAssertNil(input.window)
            }
            input.showPassword(true)
            XCTAssertEqual(input.field.textColor,NSColor(cgColor:VPNDrawing.color(ThemePalette.dark.text)))
        }
    }

    func testDialogThemeSwitchKeepsUnsavedDraftAndCredentialState() throws {
        let snapshot = try fixture("editor-selected"),profile = try XCTUnwrap(snapshot.profiles.first)
        let model = WorkspaceModel(backend:NoBackend());model.accept(snapshot)
        model.openModal(.settings(profile.id))
        let dialog = ProfileDialog(model:model,modal:.settings(profile.id),profile:profile)
        dialog.frame = CGRect(x:0,y:0,width:960,height:720);dialog.update();dialog.layoutSubtreeIfNeeded()
        func inputs(_ view:NSView) -> [NativeTextInput] {
            if let input = view as? NativeTextInput { return [input] }
            return view.subviews.flatMap(inputs)
        }
        let name = try XCTUnwrap(inputs(dialog).first { $0.field.accessibilityLabel() == "Profile name" })
        name.field.stringValue = "Unsaved draft";name.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        let identity = name.field
        dialog.applyTheme(.dark);dialog.applyTheme(.light)
        XCTAssertTrue(name.field === identity);XCTAssertEqual(name.field.stringValue,"Unsaved draft")
        XCTAssertEqual(model.state,snapshot)
        model.closeModal();model.openModal(.credentials(profile.id))
        model.password = "synthetic-pin";model.rememberPassword = true
        let credentials = ProfileDialog(model:model,modal:.credentials(profile.id),profile:profile)
        credentials.frame = dialog.frame;credentials.update();credentials.applyTheme(.dark)
        XCTAssertEqual(model.password,"synthetic-pin");XCTAssertTrue(model.rememberPassword)
        XCTAssertNil(credentials.window)
    }

    func testRenderPagesAndDialogsInBothThemesWithoutWindows() throws {
        for theme in ResolvedTheme.allCases {
            let palette = ThemePalette(theme:theme)
            for name in ["welcome","overview-disconnected","overview-connected","overview-connecting","activity-events","settings-enabled","settings-repair"] {
                let snapshot = try fixture(name)
                let screen:WorkspaceScreen = name.hasPrefix("settings") ? .setup : name.hasPrefix("activity") ? .activity : .overview
                for size in [CGSize(width:960,height:720),CGSize(width:800,height:600)] {
                    let mainWidth = size.width-194
                    let state = WorkspacePresentation(snapshot:snapshot,selectedID:snapshot.profiles.first?.id ?? "",screen:screen,palette:palette)
                    let session = snapshot.sessions.first
                    let connection = ConnectionPresentation(status:session?.status ?? .disconnected,bytesIn:1_500_000,bytesOut:10_000_000)
                    let scene = WorkspaceContent.make(state,width:mainWidth,clock:1,connection:connection)
                    XCTAssertTrue(scene.hits.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= mainWidth && $0.rect.maxY <= scene.height })
                    _ = try render("\(theme)-\(name)-\(Int(size.width))",size:size) { context in
                        context.setFillColor(VPNDrawing.color(palette.background));context.fill(CGRect(origin:.zero,size:size))
                        _ = WorkspaceChrome.sidebar(state,size:CGSize(width:194,height:size.height),context:context)
                        context.translateBy(x:194,y:0);WorkspaceChrome.header(state,width:mainWidth,context:context)
                        context.saveGState();context.translateBy(x:0,y:50);context.clip(to:CGRect(x:0,y:0,width:mainWidth,height:size.height-91))
                        scene.draw(in:context);context.restoreGState()
                        context.translateBy(x:0,y:size.height-41);_ = WorkspaceChrome.footer(width:mainWidth,context:context,palette:palette)
                    }
                }
            }
            for name in ["editor-selected","editor-all","delete-dialog","pin-error"] {
                let snapshot = try fixture(name),profile = try XCTUnwrap(snapshot.profiles.first)
                let model = WorkspaceModel(backend:NoBackend());model.accept(snapshot)
                let modal:WorkspaceModal = name.hasPrefix("editor") ? .settings(profile.id) : name == "delete-dialog" ? .delete(profile.id) : .credentials(profile.id)
                model.openModal(modal)
                if name == "pin-error" { model.modalError = "Authentication failed. Check your PIN and try again." }
                let dialog = ProfileDialog(model:model,modal:modal,profile:profile)
                dialog.frame = CGRect(x:0,y:0,width:960,height:720);dialog.applyTheme(palette);dialog.update();dialog.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(dialog.subviews.first as? NSScrollView),surface = try XCTUnwrap(scroll.documentView)
                _ = try render("\(theme)-\(name)",size:surface.frame.size) { context in
                    surface.displayIgnoringOpacity(surface.bounds,in:NSGraphicsContext(cgContext:context,flipped:true))
                }
                XCTAssertNil(dialog.window)
            }
        }
    }
}
