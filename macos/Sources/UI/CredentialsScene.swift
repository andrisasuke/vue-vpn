import AppKit

@MainActor struct DialogHeader {
    var scene:WorkspaceScene
    var bottom:CGFloat

    static func make(title:String,subtitle:String,width:CGFloat,busy:Bool,palette:ThemePalette = .light) -> DialogHeader {
        var scene = WorkspaceScene(palette:palette)
        scene.text(title,x:26,y:49.5,size:20,weight:600,tracking:-0.6)
        scene.button("Close dialog",x:width-59,y:26,action:.closeModal,style:.icon,icon:.close,enabled:!busy)
        let height = scene.paragraph(subtitle,x:26,y:70,width:max(1,width-52),size:12,lineHeight:20.4)
        return DialogHeader(scene:scene,bottom:68+floor(height)+20)
    }
}

/// Credentials layout is shared by the real modal and the hostless image tests.
/// It receives only whether a password is present, never the password itself.
@MainActor struct CredentialsScene {
    var scene:WorkspaceScene
    var passwordRect:CGRect
    var bottom:CGFloat

    static func make(profile:Profile,width:CGFloat,top:CGFloat,busy:Bool,
                     hasPassword:Bool,visible:Bool,remember:Bool,error:String,focused:Bool = false,palette:ThemePalette = .light) -> CredentialsScene {
        var scene = WorkspaceScene(palette:palette),y = top
        let inner = max(1,width-52)
        scene.text(profile.authKind == .pin ? "Profile PIN / password" : "Password",x:26,y:y+12,size:11,weight:550,color:palette[.secondaryText, light:0x6f7d66])
        y += 23
        let rect = CGRect(x:26,y:y,width:inner,height:40)
        scene.custom { VPNDrawing.emptyPasswordField(in:rect,focused:focused,palette:palette,context:$0) }
        let passwordRect = CGRect(x:61,y:y+1,width:inner-80,height:38)
        scene.hits.append(WorkspaceHitRegion(rect:CGRect(x:width-63,y:y+6,width:28,height:28),title:visible ? "Hide password" : "Show password",action:.togglePassword,enabled:!busy))
        y += 54
        if profile.allowPasswordSave {
            let checkbox = CGRect(x:26,y:y+2,width:16,height:16)
            scene.custom { context in
                let layer = CALayer()
                layer.bounds = CGRect(origin:.zero,size:checkbox.size)
                layer.backgroundColor = VPNDrawing.color(palette[.surface, light:0xffffff])
                layer.cornerRadius = 5;layer.cornerCurve = .continuous
                layer.borderWidth = 1.5
                layer.borderColor = VPNDrawing.color(remember ? palette[.primaryButton, light:0x25674d] : palette[.controlBorder, light:0x808080])
                if remember { layer.backgroundColor = VPNDrawing.color(palette[.primaryButton, light:0x25674d]) }
                context.saveGState();context.translateBy(x:checkbox.minX,y:checkbox.minY)
                if busy { context.setAlpha(0.5) }
                layer.render(in:context);context.restoreGState()
            }
            if remember { scene.icon(.check,x:27,y:y+3,size:14,color:palette[.onAccent, light:0xffffff]) }
            scene.text("Remember on this Mac",x:52,y:y+12,size:11,weight:550)
            scene.text("Saved in macOS Keychain after a successful connection.",x:52,y:y+32,size:10,color:palette[.secondaryText, light:0x77847b])
            scene.hits.append(WorkspaceHitRegion(rect:CGRect(x:26,y:y,width:inner,height:36),title:"Remember on this Mac",action:.toggleRemember,enabled:!busy,role:.checkbox,checked:remember))
            y += 36
        } else {
            y += scene.paragraph("This profile does not allow passwords to be saved.",x:26,y:y,width:inner)
        }
        if !error.isEmpty { y += 19+scene.paragraph(error,x:26,y:y+21,width:inner,size:11,lineHeight:18,color:palette[.errorText, light:0xa64035]) }
        y += 28
        let label = busy ? "Connecting…" : "Connect"
        let connectWidth = max(98,ceil(VPNDrawing.textWidth(label,size:12,weight:550)*64)/64+59)
        let cancelWidth = max(98,ceil(VPNDrawing.textWidth("Cancel",size:12,weight:550)*64)/64+36)
        scene.button("Cancel",x:width-26-connectWidth-cancelWidth-10,y:y,action:.closeModal,enabled:!busy,fixedWidth:cancelWidth,fontSize:12)
        scene.button(label,x:width-26-connectWidth,y:y,action:.submitCredentials,style:.primary,icon:.power,enabled:!busy && hasPassword,fixedWidth:connectWidth,fontSize:12)
        return CredentialsScene(scene:scene,passwordRect:passwordRect,bottom:y+42)
    }
}
