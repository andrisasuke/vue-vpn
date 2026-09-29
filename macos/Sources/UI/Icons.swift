import AppKit

/// Original VueVPN vector geometry. Each SVG element remains a separate stroke.
/// Rendering uses CoreGraphics only; there is no SVG/HTML/WebView runtime.
enum VPNIcon: String, CaseIterable {
    case grid, lock, route, plus, upload, server, chevron, power, shield, laptop, clock, globe, activity, info, edit, trash, terminal, close, eye, file, check, arrow, home, brand

    func draw(in rect: CGRect, color: UInt32, context: CGContext, snap: Bool = true) {
        if self == .lock || self == .eye {
            VPNDrawing.icon(self == .lock ? .lock : .eye, in: rect, color: color, context: context)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        let origin = snap ? VPNDrawing.iconOrigin(rect.origin,in:context) : rect.origin
        context.translateBy(x:origin.x,y:origin.y)
        let size: CGFloat = self == .brand ? 40 : 24
        context.scaleBy(x: rect.width / size, y: rect.height / size)
        context.setStrokeColor(VPNDrawing.color(color))
        context.setLineWidth(self == .brand ? 4 : CGFloat(Float(1.65)))
        context.setLineCap(.round); context.setLineJoin(.round)
        switch self {
        case .grid:
            stroke(CGPath(roundedRect: CGRect(x: 3, y: 3, width: 7, height: 7), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil), in: context)
            stroke(CGPath(roundedRect: CGRect(x: 14, y: 3, width: 7, height: 7), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil), in: context)
            stroke(CGPath(roundedRect: CGRect(x: 3, y: 14, width: 7, height: 7), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil), in: context)
            stroke(CGPath(roundedRect: CGRect(x: 14, y: 14, width: 7, height: 7), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil), in: context)
        case .lock:
            stroke(CGPath(roundedRect: CGRect(x: 5, y: 10, width: 14, height: 11), cornerWidth: 3, cornerHeight: 3, transform: nil), in: context)
            stroke(path("M8 10V7a4 4 0 0 1 8 0v3M12 15v2"), in: context)
        case .route:
            context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 4, height: 4))
            context.strokeEllipse(in: CGRect(x: 17, y: 17, width: 4, height: 4))
            stroke(path("M7 5h8a4 4 0 0 1 0 8H9a4 4 0 0 0 0 8h4M17 3l2 2-2 2"), in: context)
        case .plus:
            stroke(path("M12 5v14M5 12h14"), in: context)
        case .upload:
            stroke(path("M12 16V3m-4 4 4-4 4 4M4 15v4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"), in: context)
        case .server:
            stroke(CGPath(roundedRect: CGRect(x: 3, y: 3, width: 18, height: 7), cornerWidth: 2, cornerHeight: 2, transform: nil), in: context)
            stroke(CGPath(roundedRect: CGRect(x: 3, y: 14, width: 18, height: 7), cornerWidth: 2, cornerHeight: 2, transform: nil), in: context)
            stroke(path("M7 6.5h.01M7 17.5h.01M11 6.5h6M11 17.5h6"), in: context)
        case .chevron:
            stroke(path("m9 5 7 7-7 7"), in: context)
        case .power:
            stroke(path("M12 2v10M6 5a9 9 0 1 0 12 0"), in: context)
        case .shield:
            stroke(path("M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6l-8-3Z"), in: context)
            stroke(path("m8.5 12 2.5 2.5 4.5-5"), in: context)
        case .laptop:
            stroke(CGPath(roundedRect: CGRect(x: 5, y: 3, width: 14, height: 12), cornerWidth: 2, cornerHeight: 2, transform: nil), in: context)
            stroke(path("m5 15-3 5h20l-3-5M10 17h4"), in: context)
        case .clock:
            context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            stroke(path("M12 7v5l3 2"), in: context)
        case .globe:
            context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            context.strokeEllipse(in: CGRect(x: 8, y: 3, width: 8, height: 18))
            stroke(path("M3 12h18"), in: context)
        case .activity:
            stroke(path("M2 12h5l3-8 4 16 3-8h5"), in: context)
        case .info:
            context.strokeEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            stroke(path("M12 11v6M12 7h.01"), in: context)
        case .edit:
            stroke(path("m15 5 4 4M4 20l4-1L20 7a2.8 2.8 0 0 0-4-4L4 15v5Z"), in: context)
        case .trash:
            stroke(path("M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"), in: context)
        case .terminal:
            stroke(path("m4 6 5 6-5 6M13 18h7"), in: context)
        case .close:
            stroke(path("m6 6 12 12M18 6 6 18"), in: context)
        case .eye:
            stroke(path("M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"), in: context)
            context.strokeEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
        case .file:
            stroke(path("M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6Z M14 2v6h6M8 13h8M8 17h5"), in: context)
        case .check:
            stroke(path("m5 12 4 4L19 6"), in: context)
        case .arrow:
            stroke(path("M4 12h16m-6-6 6 6-6 6"), in: context)
        case .home:
            stroke(path("m3 10 9-7 9 7M5 9v12h14V9M9 21v-8h6v8"), in: context)
        case .brand:
            stroke(path("m6 10 14 22 14-22"), in: context)
            stroke(path("m14 10 6 10 6-10"), in: context)
        }
    }

    private func stroke(_ path: CGPath, in context: CGContext) {
        context.addPath(path); context.strokePath()
    }

    private func path(_ commands: String) -> CGPath {
        if let cached = DrawingResources.paths.value(for:commands) { return cached }
        let result = VectorPath.make(commands)
        DrawingResources.paths.insert(result,for:commands)
        return result
    }
}
