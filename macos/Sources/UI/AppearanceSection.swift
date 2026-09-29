import AppKit

@MainActor enum AppearanceSection {
    static let height:CGFloat = 218

    @discardableResult static func append(to scene:inout WorkspaceScene,preference:ThemePreference,
                                         x:CGFloat,y:CGFloat,width:CGFloat) -> CGFloat {
        let palette = scene.palette
        scene.box(CGRect(x:x,y:y,width:width,height:height),radius:16,fill:palette.surface,border:palette.border)
        scene.text("Appearance",x:x+22,y:y+34,size:16,weight:650)
        scene.text("Choose how VueVPN looks on your Mac.",x:x+22,y:y+55,size:11,color:palette.secondaryText)
        let optionWidth = (width-68)/3
        for (index,choice) in ThemePreference.allCases.enumerated() {
            let rect = CGRect(x:x+22+CGFloat(index)*(optionWidth+12),y:y+74,width:optionWidth,height:106)
            let selected = choice == preference
            scene.interactive(.theme(choice),in:rect) { context,feedback in
                VPNDrawing.rounded(rect,radius:10,
                    fill:selected ? palette[.selected,light:0xf1f6eb] : feedback.hovered ? palette[.hover,light:0xf1f4ed] : palette.surface,
                    border:selected ? palette[.controlBorder,light:0x9ab786] : palette.border,in:context)
                preview(choice,in:CGRect(x:rect.minX+12,y:rect.minY+11,width:rect.width-24,height:54),context:context)
                let radio = CGRect(x:rect.minX+12,y:rect.maxY-27,width:14,height:14)
                VPNDrawing.rounded(radio,radius:7,fill:selected ? palette[.primaryButton,light:0x25674d] : palette.surface,
                    border:palette[.controlBorder,light:0xc8d1bf],in:context)
                if selected {
                    context.setFillColor(VPNDrawing.color(palette[.onAccent,light:0xffffff]));context.fillEllipse(in:radio.insetBy(dx:4,dy:4))
                }
                VPNDrawing.text(choice.title,in:context,at:CGPoint(x:rect.minX+33,y:rect.maxY-16),size:11,weight:550,color:palette.text)
            }
            scene.hits.append(WorkspaceHitRegion(rect:rect,title:choice.title,action:.theme(choice),role:.radio,checked:selected))
        }
        let caption = preference == .system ? "Automatically follows your Mac’s appearance." : "Applies immediately and stays saved on this Mac."
        scene.text(caption,x:x+22,y:y+201,size:10,color:palette.secondaryText)
        return y+height
    }

    private static func preview(_ choice:ThemePreference,in rect:CGRect,context:CGContext) {
        let themes:[ResolvedTheme] = choice == .system ? [.light,.dark] : [choice.resolved(system:.light)]
        for (index,theme) in themes.enumerated() {
            let palette = ThemePalette(theme:theme)
            context.saveGState()
            context.addPath(CGPath(roundedRect:rect,cornerWidth:5,cornerHeight:5,transform:nil));context.clip()
            if themes.count == 2 { context.clip(to:CGRect(x:rect.minX+CGFloat(index)*rect.width/2,y:rect.minY,width:rect.width/2,height:rect.height)) }
            context.setFillColor(VPNDrawing.color(palette.background));context.fill(rect)
            context.setFillColor(VPNDrawing.color(palette[.sidebar,light:0x1c3029]));context.fill(CGRect(x:rect.minX,y:rect.minY,width:rect.width*0.22,height:rect.height))
            let left = rect.minX+rect.width*0.22+7,width = rect.width*0.78-14
            VPNDrawing.rounded(CGRect(x:left,y:rect.minY+9,width:width*0.6,height:3),radius:1.5,fill:palette.secondaryText,in:context)
            VPNDrawing.rounded(CGRect(x:left,y:rect.minY+18,width:width,height:25),radius:4,fill:palette[.connection,light:0xf0f4e9],border:palette.border,in:context)
            VPNDrawing.rounded(CGRect(x:left+5,y:rect.minY+32,width:width*0.35,height:5),radius:2,fill:palette[.primaryButton,light:0x25674d],in:context)
            context.restoreGState()
        }
    }
}
