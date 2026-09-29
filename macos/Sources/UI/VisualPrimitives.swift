import AppKit
import CoreText

/// Drawing primitives for the native UI. Coordinates use macOS points with a
/// top-left origin. No WebKit, HTML, image replay, or VPN dependencies.
enum VPNDrawing {
    static func iconOrigin(_ origin:CGPoint,in context:CGContext) -> CGPoint {
        let transform = context.ctm
        guard transform.b == 0,transform.c == 0,transform.a != 0,transform.d != 0 else { return origin }
        let x = transform.tx/transform.a,y = transform.ty/transform.d
        return CGPoint(x:floor(origin.x+x+0.5)-x,y:floor(origin.y+y+0.5)-y)
    }

    /// CSS painting rounds both edges independently to physical pixels. Text
    /// keeps its fractional layout origin; only the painted box is snapped.
    static func pixelAligned(_ rect: CGRect, in context: CGContext) -> CGRect {
        let scale = hypot(context.ctm.a, context.ctm.b)
        guard scale > 0 else { return rect }
        let left = (rect.minX*scale).rounded()/scale, top = (rect.minY*scale).rounded()/scale
        return CGRect(x:left,y:top,width:(rect.maxX*scale).rounded()/scale-left,
                      height:(rect.maxY*scale).rounded()/scale-top)
    }

    static func routingChoice(_ rect: CGRect, selected: Bool, hovered: Bool = false, palette:ThemePalette = .light, in context: CGContext) {
        rounded(rect,radius:11,fill:selected ? palette[.selected, light:0xf1f6eb] : palette[.surface, light:0xffffff],
                border:selected ? palette[.controlBorder, light:0x9ab786] : hovered ? palette[.controlBorder, light:0xb5c8a7] : palette[.border, light:0xe5e9df],in:context)
        if selected {
            // The inset shadow is composited inside the padding edge, after
            // the border. Its fractional spread changes the inner radii even
            // when the hole's rectangle snaps to a whole device pixel.
            context.saveGState()
            context.addPath(CGPath(roundedRect:rect.insetBy(dx:1,dy:1),cornerWidth:10,cornerHeight:10,transform:nil))
            context.clip()
            context.setFillColor(color(palette[.controlBorder, light:0x9ab786]))
            context.addRect(rect)
            context.addPath(CGPath(roundedRect:pixelAligned(rect.insetBy(dx:1.3,dy:1.3),in:context),cornerWidth:9.7,cornerHeight:9.7,transform:nil))
            context.drawPath(using:.eoFill)
            context.restoreGState()
        }
        let radio = CGRect(x:rect.minX+11,y:rect.minY+15,width:15,height:15)
        rounded(radio,radius:7.5,fill:selected ? palette[.primaryButton, light:0x25674d] : palette[.surface, light:0xffffff],
                border:selected ? palette[.primaryButton, light:0x25674d] : palette[.controlBorder, light:0xc8d1bf],in:context)
        if selected {
            context.setFillColor(color(palette[.overlay, light:0xffffff]))
            context.fillEllipse(in:radio.insetBy(dx:5,dy:5))
        }
    }

    static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(Float((rgb >> 16) & 255)/255),
                green: CGFloat(Float((rgb >> 8) & 255)/255),
                blue: CGFloat(Float(rgb & 255)/255), alpha: alpha)
    }

    static func systemFont(size: CGFloat, weight: CGFloat, tabular: Bool = false, monospace: Bool = false) -> NSFont {
        let key = "\(size):\(weight):\(tabular):\(monospace)"
        if let font = DrawingResources.fonts.value(for:key) { return font }
        let base = monospace ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) :
            tabular ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: .regular)
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontVariationAttribute: [NSNumber(value: 0x77676874): weight,
                                       NSNumber(value: 0x6f70737a): size]
        ] as CFDictionary)
        let font = CTFontCreateCopyWithAttributes(base, size, nil, descriptor) as NSFont
        DrawingResources.fonts.insert(font,for:key)
        return font
    }

    static func text(_ string: String, in context: CGContext, at baseline: CGPoint,
                     size: CGFloat, weight: CGFloat, tracking: CGFloat = 0,
                     color: UInt32 = 0x1d332d, tabular: Bool = false, monospace: Bool = false) {
        context.saveGState()
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(true)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = baseline
        var attributes: [NSAttributedString.Key: Any] = [
            .font: systemFont(size: size, weight: weight, tabular: tabular, monospace: monospace),
            .ligature: tracking == 0 ? 1 : 0,
            .foregroundColor: NSColor(cgColor: self.color(color))!,
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let attributed = NSAttributedString(string: string, attributes: attributes)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.restoreGState()
    }

    static func textWidth(_ string: String, size: CGFloat, weight: CGFloat,
                          tracking: CGFloat = 0, tabular: Bool = false, monospace: Bool = false) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: systemFont(size: size, weight: weight, tabular: tabular, monospace: monospace),
            .ligature: tracking == 0 ? 1 : 0,
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func truncatedText(_ string: String, width: CGFloat, in context: CGContext, at baseline: CGPoint,
                              size: CGFloat, weight: CGFloat, color: UInt32) {
        context.saveGState(); defer { context.restoreGState() }
        context.setShouldSmoothFonts(false)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(true)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = baseline
        let attributes: [NSAttributedString.Key: Any] = [
            .font: systemFont(size: size, weight: weight), .foregroundColor: NSColor(cgColor: self.color(color))!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        CTLineDraw(CTLineCreateTruncatedLine(line, Double(max(0, width)), .end, token) ?? line, context)
    }

    static func wrappedLines(_ string: String, width: CGFloat, size: CGFloat, weight: CGFloat) -> [String] {
        let attributed = NSAttributedString(string: string, attributes: [.font: systemFont(size: size, weight: weight)])
        let setter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = string as NSString
        var offset = 0, lines: [String] = []
        while offset < ns.length {
            let length = max(1, CTTypesetterSuggestLineBreak(setter, offset, Double(width)))
            lines.append(ns.substring(with: NSRange(location: offset, length: length)).trimmingCharacters(in: .whitespacesAndNewlines))
            offset += length
        }
        return lines
    }

    static func rounded(_ rect: CGRect, radius: CGFloat, fill: UInt32,
                        border: UInt32? = nil, width: CGFloat = 1, background: Bool = true, in context: CGContext) {
        let outer = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if background && border != nil {
            // Inset the opaque background one device pixel, retaining its radius,
            // then paint the border ring above it. Painting white over the border
            // instead reverses antialias compositing and changes corner pixels.
            let pixel = 1 / abs(context.ctm.a)
            context.setFillColor(color(fill))
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: pixel, dy: pixel),
                                   cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.setFillColor(color(border ?? fill))
        context.addPath(outer)
        if border != nil {
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: width, dy: width),
                                   cornerWidth: max(0, radius-width), cornerHeight: max(0, radius-width), transform: nil))
        }
        context.drawPath(using: border == nil ? .fill : .eoFill)
    }

    static func solidShadow(_ rect: CGRect, radius: CGFloat, color: UInt32, alpha: CGFloat = 1,
                            in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect.insetBy(dx: -2, dy: -2))
        let displacement = rect.width+4
        context.setShadow(offset: CGSize(width: -displacement*context.ctm.a,
                                        height: -displacement*context.ctm.b),
                          blur: 0, color: self.color(color, alpha: alpha))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: rect.offsetBy(dx: displacement, dy: 0),
                              cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    /// CSS-style soft shadow evaluated in point space before the destination
    /// transform. Three separable box passes approximate the Gaussian kernel.
    static func shadow(_ rect: CGRect, radius: CGFloat, blur: CGFloat, offset: CGSize,
                       color: UInt32, alpha: CGFloat, in context: CGContext) {
        let padding = Int(ceil(blur * 2)) + 2
        let w = Int(ceil(rect.width)) + padding*2, h = Int(ceil(rect.height)) + padding*2
        let axisAligned = context.ctm.b == 0 && context.ctm.c == 0
        let key = "shadow:\(rect.width):\(rect.height):\(radius):\(blur):\(color):\(alpha):\(axisAligned)"
        let image:CGImage
        if let cached = DrawingResources.images.value(for:key) { image = cached }
        else {
        guard let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        mask.translateBy(x: CGFloat(padding), y: CGFloat(h-padding)); mask.scaleBy(x: 1, y: -1)
        mask.setFillColor(CGColor(gray: 0, alpha: 1))
        mask.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: radius, cornerHeight: radius, transform: nil))
        mask.fillPath()
        let raw = mask.data!.assumingMemoryBound(to: UInt8.self)
        var pixels: [UInt8] = (0..<w*h).map { raw[$0*4+3] }
        let diameter = max(2, Int(floor(Float(blur)/2 * (0.75 * sqrt(2 * Float.pi)) * 0.88 + 0.5)))
        let n = diameter/2
        let passes = diameter % 2 == 1 ? [(n,n),(n,n),(n,n)] : [(n,n-1),(n-1,n),(n,n)]
        for vertical in [false, true] {
            let length = vertical ? h : w, rows = vertical ? w : h
            for (left, right) in passes {
                var output = [UInt8](repeating: 0, count: pixels.count)
                let divisor = left+right+1, reciprocal = (32768+divisor-1)/divisor
                for row in 0..<rows {
                    let base = vertical ? row : row*w, stride = vertical ? w : 1
                    var sum = 0
                    for k in -left...right { sum += Int(pixels[base+min(length-1,max(0,k))*stride]) }
                    for column in 0..<length {
                        output[base+column*stride] = UInt8((sum*reciprocal)>>15)
                        sum -= Int(pixels[base+max(0,column-left)*stride])
                        sum += Int(pixels[base+min(length-1,column+right+1)*stride])
                    }
                }
                pixels = output
            }
        }
        for i in pixels.indices { raw[i*4+3] = pixels[i] }
        // Axis-aligned box shadows use a colorized image; transformed boxes
        // use an alpha mask. Keep their different compositing order intact.
        if axisAligned {
            mask.concatenate(mask.ctm.inverted())
            mask.setBlendMode(.sourceIn)
            mask.setFillColor(self.color(color, alpha: alpha))
            mask.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let generated = mask.makeImage() else { return }
        DrawingResources.images.insert(generated,for:key,cost:generated.bytesPerRow*generated.height)
        image = generated
        }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX + offset.width - CGFloat(padding), y: rect.minY + offset.height - CGFloat(padding) + CGFloat(h))
        context.scaleBy(x: 1, y: -1)
        let destination = CGRect(x: 0, y: 0, width: w, height: h)
        if axisAligned { context.draw(image, in: destination) }
        else {
            context.clip(to: destination, mask: image)
            context.setFillColor(self.color(color, alpha: alpha))
            context.fill(destination)
        }
    }

    enum Icon { case lock, eye }

    static func icon(_ icon: Icon, in rect: CGRect, color: UInt32, context: CGContext) {
        context.saveGState()
        let origin = iconOrigin(rect.origin,in:context)
        context.translateBy(x:origin.x,y:origin.y)
        context.scaleBy(x: rect.width/24, y: rect.height/24)
        context.setStrokeColor(self.color(color))
        context.setLineWidth(CGFloat(Float(1.65)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let path = CGMutablePath()
        switch icon {
        case .lock:
            path.addRoundedRect(in: CGRect(x: 5, y: 10, width: 14, height: 11), cornerWidth: 3, cornerHeight: 3)
            context.addPath(path)
            context.strokePath()
            let shackle = CGMutablePath()
            shackle.move(to: CGPoint(x: 8, y: 10))
            shackle.addLine(to: CGPoint(x: 8, y: 7))
            shackle.addArc(center: CGPoint(x: 12, y: 7), radius: 4, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            shackle.addLine(to: CGPoint(x: 16, y: 10))
            shackle.move(to: CGPoint(x: 12, y: 15))
            shackle.addLine(to: CGPoint(x: 12, y: 17))
            context.addPath(shackle)
            context.strokePath()
        case .eye:
            path.move(to: CGPoint(x: 2, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 5), control1: CGPoint(x: 2, y: 12), control2: CGPoint(x: 6, y: 5))
            path.addCurve(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 18, y: 5), control2: CGPoint(x: 22, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 19), control1: CGPoint(x: 22, y: 12), control2: CGPoint(x: 18, y: 19))
            path.addCurve(to: CGPoint(x: 2, y: 12), control1: CGPoint(x: 6, y: 19), control2: CGPoint(x: 2, y: 12))
            path.closeSubpath()
            context.addPath(path)
            context.strokePath()
            context.strokeEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
        }
        context.restoreGState()
    }

    static func emptyPasswordField(in rect: CGRect, focused:Bool = false, palette:ThemePalette = .light, context: CGContext) {
        rounded(rect, radius: 9, fill: palette[.surface, light:0xffffff], border: focused ? palette[.focusBorder, light:0xa8afa4] : palette[.border, light:0xe5e9df], in: context)
        icon(.lock, in: CGRect(x: rect.minX+11, y: rect.midY-8, width: 16, height: 16), color: palette[.secondaryText, light:0x839676], context: context)
        rounded(CGRect(x:rect.maxX-37,y:rect.midY-14,width:28,height:28),radius:7,fill:palette[.surface, light:0xffffff],border:palette[.border, light:0xe5e9df],background:false,in:context)
        icon(.eye, in: CGRect(x: rect.maxX-31, y: rect.midY-8, width: 16, height: 16), color: palette[.secondaryText, light:0x8e9b81], context: context)
    }
}
