import XCTest
import AppKit

/// Pure scene construction and drawing only. No NSApplication, NSWindow,
/// status item, XPC adapter, Keychain or production profile directory.
@MainActor
final class SceneTests:XCTestCase {
    private func state(_ status:SessionStatus = .disconnected) throws -> WorkspacePresentation {
        var profile = try ProfileParser.parse("client\nremote vpn.example.test\nauth-user-pass\n",fallbackName:"Development").profile
        profile.id = "synthetic-profile";profile.routingMode = .selected
        profile.routes = [try VPNPolicy.route(IPv4("10.7.1.22"),16)]
        let snapshot = Snapshot(profiles:[profile],sessions:[Session(profileId:profile.id,sessionId:"synthetic-session",status:status)],helper:HelperStatus("enabled","Ready"),logs:[])
        return WorkspacePresentation(snapshot:snapshot,selectedID:profile.id)
    }

    func testConnectionHitTargetUsesThePaintedButtonAndPendingState() throws {
        for status in SessionStatus.allCases {
            let state = try state(status)
            let pending = status == .connecting || status == .disconnecting
            let presentation = ConnectionPresentation(status:status,buttonDisabled:pending)
            let scene = WorkspaceContent.make(state,width:766,clock:1,connection:presentation)
            let target = try XCTUnwrap(scene.hits.first { $0.action == .toggle })
            XCTAssertEqual(target.rect,ConnectionPanel.buttonRect(presentation,width:718).offsetBy(dx:24,dy:117))
            XCTAssertEqual(target.title,presentation.buttonLabel)
            XCTAssertEqual(target.enabled,!pending)
        }
    }

    func testBothRoutingChoicesOpenProfileEditor() throws {
        let scene = WorkspaceContent.make(try state(),width:766,clock:1,connection:ConnectionPresentation())
        for title in ["All IPv4 traffic","Selected networks","Manage routes"] {
            let target = try XCTUnwrap(scene.hits.first { $0.title == title })
            XCTAssertEqual(target.action,.edit)
        }
        XCTAssertFalse(scene.hits.contains { $0.title.lowercased().contains("dns") })
        let radios = scene.hits.filter { $0.role == .radio }
        XCTAssertEqual(radios.count,2)
        XCTAssertEqual(radios.filter(\.checked).map(\.title),["Selected networks"])
    }

    func testSeparateButtonsSharingAnActionKeepIndependentFeedback() throws {
        var first = WorkspaceScene(),second = WorkspaceScene()
        let a = CGRect(x:0,y:0,width:80,height:40),b = a.offsetBy(dx:100,dy:0)
        var observed:[Bool] = []
        first.interactive(.edit,in:a) { _,feedback in observed.append(feedback.hovered) }
        second.interactive(.edit,in:b) { _,feedback in observed.append(feedback.hovered) }
        first.append(second)
        let context = try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        first.draw(in:context) { action,rect in .init(hovered:action == .edit && rect == b) }
        XCTAssertEqual(observed,[false,true])
    }

    func testCredentialsRespectSavePermissionAndPendingConnection() throws {
        var profile = try XCTUnwrap(state().selected)
        for allowed in [true,false] {
            profile.allowPasswordSave = allowed
            for busy in [true,false] {
                let dialog = CredentialsScene.make(profile:profile,width:480,top:108,busy:busy,
                    hasPassword:true,visible:false,remember:false,error:"")
                let remember = dialog.scene.hits.first { $0.action == .toggleRemember }
                XCTAssertEqual(remember != nil,allowed)
                if let remember { XCTAssertEqual(remember.enabled,!busy);XCTAssertEqual(remember.role,.checkbox) }
                let connect = try XCTUnwrap(dialog.scene.hits.first { $0.action == .submitCredentials })
                XCTAssertEqual(connect.enabled,!busy)
                XCTAssertEqual(connect.title,busy ? "Connecting…" : "Connect")
                XCTAssertEqual(dialog.passwordRect.height,38)
            }
        }
    }

    func testCredentialsErrorMovesActionsAndEmptyPasswordCannotSubmit() throws {
        let profile = try XCTUnwrap(state().selected)
        let plain = CredentialsScene.make(profile:profile,width:480,top:108,busy:false,
            hasPassword:false,visible:false,remember:false,error:"")
        let error = CredentialsScene.make(profile:profile,width:480,top:108,busy:false,
            hasPassword:false,visible:true,remember:false,error:String(repeating:"Authentication failed. ",count:8))
        XCTAssertGreaterThan(error.bottom,plain.bottom)
        XCTAssertFalse(try XCTUnwrap(error.scene.hits.first { $0.action == .submitCredentials }).enabled)
        XCTAssertEqual(error.scene.hits.first { $0.action == .togglePassword }?.title,"Hide password")
        XCTAssertTrue(error.scene.hits.allSatisfy { $0.rect.maxY <= error.bottom })
    }

    func testTextInputUsesCenteredLineHeightWhileEditingAndResizing() {
        for secure in [false,true] {
            for fontSize:CGFloat in [12,13] {
                let input = NativeTextInput(frame:CGRect(x:0,y:0,width:240,height:38),value:"Synthetic",label:"Input",secure:secure,fontSize:fontSize)
                for height:CGFloat in [38,54,38] {
                    input.setFrameSize(NSSize(width:320,height:height))
                    input.layoutSubtreeIfNeeded()
                    for value in ["", "Synthetic", String(repeating:"x",count:100)] {
                        input.update(value:value,enabled:true)
                        let before = input.field.frame
                        input.controlTextDidBeginEditing(Notification(name:NSControl.textDidBeginEditingNotification,object:input.field))
                        XCTAssertEqual(input.field.frame,before)
                        XCTAssertEqual(before.height,input.field.intrinsicContentSize.height,accuracy:0.01)
                        XCTAssertLessThan(before.height,height)
                        XCTAssertEqual(before.midY,input.bounds.midY,accuracy:0.01)
                        XCTAssertEqual(before.width,input.bounds.width)
                        input.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:input.field))
                        XCTAssertEqual(input.field.frame,before)
                        XCTAssertNil(input.window)
                    }
                }
            }
        }
    }

    func testPasswordVisibilityPreservesDisabledStateAndValue() {
        let input = NativeTextInput(frame:CGRect(x:0,y:0,width:200,height:38),value:"synthetic-pin",label:"Password",secure:true)
        input.update(value:"synthetic-pin",enabled:false)
        for visible in [true,false,true] {
            input.showPassword(visible)
            XCTAssertNil(input.window)
            XCTAssertEqual(input.field is NSSecureTextField,!visible)
            XCTAssertEqual(input.field.stringValue,"synthetic-pin")
            XCTAssertFalse(input.field.isEnabled)
            XCTAssertEqual(input.field.frame.midY,input.bounds.midY,accuracy:0.01)
            XCTAssertEqual(input.field.frame.height,input.field.intrinsicContentSize.height,accuracy:0.01)
        }
        input.clear()
        XCTAssertEqual(input.field.stringValue,"")
    }

    func testHelperActionsFollowStateAndBusyProtection() throws {
        for (status,title,action):(String,String,WorkspaceAction) in [
            ("not_found","Enable VPN helper",.helper("register")),
            ("not_registered","Enable VPN helper",.helper("register")),
            ("unavailable","Repair VPN helper",.helper("retry_update")),
            ("update_failed","Retry helper update",.helper("retry_update")),
            ("update_pending","Disconnect all and update",.disconnectAll),
        ] {
            var state = try state();state.screen = .setup;state.snapshot.helper.status = status
            for busy in [false,true] {
                state.busy = busy
                let scene = WorkspaceContent.make(state,width:606,clock:1,connection:ConnectionPresentation())
                let target = try XCTUnwrap(scene.hits.first { $0.title == title })
                XCTAssertEqual(target.action,action);XCTAssertEqual(target.enabled,!busy)
                XCTAssertTrue(scene.hits.allSatisfy { $0.rect.minX >= 0 && $0.rect.maxX <= 606 })
            }
        }
    }

    func testUpdatingHelperDisablesSettingsButton() throws {
        var state = try state();state.screen = .setup;state.snapshot.helper.status = "updating"
        let scene = WorkspaceContent.make(state,width:766,clock:1,connection:ConnectionPresentation())
        XCTAssertFalse(try XCTUnwrap(scene.hits.first { $0.action == .helper("settings") }).enabled)
        XCTAssertFalse(try XCTUnwrap(scene.hits.first { $0.action == .helper("unregister") }).enabled)
    }

    func testEmptyWorkspaceOffersImportWithoutConnectionAction() throws {
        var state = try state();state.snapshot.profiles = [];state.snapshot.sessions = [];state.selectedID = ""
        let scene = WorkspaceContent.make(state,width:606,clock:1,connection:ConnectionPresentation())
        XCTAssertTrue(scene.hits.contains { $0.action == .importProfile && $0.enabled })
        XCTAssertFalse(scene.hits.contains { $0.action == .toggle })
    }

    func testActivityDisconnectAllRequiresActiveSession() throws {
        for status in [SessionStatus.disconnected,.error,.connected,.reconnecting] {
            var state = try state(status);state.screen = .activity
            let scene = WorkspaceContent.make(state,width:766,clock:1,connection:ConnectionPresentation())
            XCTAssertEqual(try XCTUnwrap(scene.hits.first { $0.action == .disconnectAll }).enabled,status.active)
        }
    }

    func testScenesRenderIntoMemoryAtBothSupportedWindowSizes() throws {
        for width:CGFloat in [606,766] {
            for screen in [WorkspaceScreen.overview,.activity,.setup] {
                var state = try state();state.screen = screen
                state.snapshot.logs = [LogEntry(timestamp:1,profileId:"synthetic-profile",message:"Synthetic connection event.")]
                let scene = WorkspaceContent.make(state,width:width,clock:1,connection:ConnectionPresentation(),error:"Synthetic error")
                XCTAssertGreaterThan(scene.height,0)
                let context = try XCTUnwrap(CGContext(data:nil,width:Int(width),height:Int(ceil(scene.height)),bitsPerComponent:8,bytesPerRow:Int(width)*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
                context.translateBy(x:0,y:scene.height);context.scaleBy(x:1,y:-1)
                scene.draw(in:context)
                XCTAssertNotNil(context.makeImage())
                XCTAssertTrue(scene.hits.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 && $0.rect.maxY <= scene.height })
            }
        }
    }
}
