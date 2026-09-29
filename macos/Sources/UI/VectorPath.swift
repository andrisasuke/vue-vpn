import CoreGraphics
import Foundation

/// Decodes the app's fixed vector path commands into native CGPaths. No external
/// documents or user-supplied markup are accepted by this renderer.
enum VectorPath {
    static func make(_ string: String) -> CGPath {
        let regex = try! NSRegularExpression(pattern: #"[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?"#)
        let tokens = regex.matches(in: string, range: NSRange(string.startIndex..., in: string))
            .map { String(string[Range($0.range, in: string)!]) }
        let path = CGMutablePath()
        var i = 0, command = "", current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
        func point(relative: Bool) -> CGPoint {
            let p = CGPoint(x: number(), y: number())
            return relative ? CGPoint(x: p.x + current.x, y: p.y + current.y) : p
        }
        while i < tokens.count {
            if tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
            let relative = command == command.lowercased()
            switch command.uppercased() {
            case "M":
                current = point(relative: relative); path.move(to: current); start = current
                command = relative ? "l" : "L"; lastControl = nil
            case "L": current = point(relative: relative); path.addLine(to: current); lastControl = nil
            case "H": current.x = number() + (relative ? current.x : 0); path.addLine(to: current); lastControl = nil
            case "V": current.y = number() + (relative ? current.y : 0); path.addLine(to: current); lastControl = nil
            case "C":
                let a = point(relative: relative), b = point(relative: relative), end = point(relative: relative)
                path.addCurve(to: end, control1: a, control2: b); current = end; lastControl = b
            case "S":
                let a = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let b = point(relative: relative), end = point(relative: relative)
                path.addCurve(to: end, control1: a, control2: b); current = end; lastControl = b
            case "A":
                let rx = number(), ry = number(), rotation = number(), large = number() != 0, sweep = number() != 0
                let end = point(relative: relative)
                arc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil
            case "Z": path.closeSubpath(); current = start; lastControl = nil; command = ""
            default: preconditionFailure("Unsupported bundled vector command")
            }
        }
        return path
    }

    private static func arc(_ path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                            rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        guard start != end else { return }
        guard rx != 0 && ry != 0 else { path.addLine(to: end); return }
        // SVG arcs are flattened into cubic segments of at most 90 degrees.
        // CoreGraphics' arc helper uses a different subdivision, visibly changing
        // the power icon. Float coordinates preserve the bundled vector geometry.
        let angle = rotation * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        var rx = Float(abs(rx)), ry = Float(abs(ry))
        let dx = Float((start.x-end.x)/2), dy = Float((start.y-end.y)/2)
        let mx = Float(cosine*Double(dx)+sine*Double(dy))
        let my = Float(-sine*Double(dx)+cosine*Double(dy))
        let stretch = mx*mx/(rx*rx)+my*my/(ry*ry)
        if stretch > 1 { rx *= sqrt(stretch); ry *= sqrt(stretch) }
        func normalized(_ p: CGPoint) -> (Float, Float) {
            (Float((cosine*p.x+sine*p.y)*Double(1/rx)),
             Float((-sine*p.x+cosine*p.y)*Double(1/ry)))
        }
        let (ax, ay) = normalized(start), (bx, by) = normalized(end)
        let vx = bx-ax, vy = by-ay
        let factor = sqrt(max(0, 1/(vx*vx+vy*vy)-0.25)) * (sweep == large ? -1 : Float(1))
        let cx = (ax+bx)*0.5-vy*factor, cy = (ay+by)*0.5+vx*factor
        let first = atan2(ay-cy, ax-cx)
        var span = atan2(by-cy, bx-cx)-first
        if sweep && span < 0 { span += 2*Float.pi }
        if !sweep && span > 0 { span -= 2*Float.pi }
        let count = max(1, Int(ceil(abs(span/(Float.pi/2+0.001)))))
        func mapped(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: CGFloat(Float(cosine*Double(rx)*Double(x)-sine*Double(ry)*Double(y))),
                    y: CGFloat(Float(sine*Double(rx)*Double(x)+cosine*Double(ry)*Double(y))))
        }
        for i in 0..<count {
            let a = first+Float(i)*span/Float(count), b = first+Float(i+1)*span/Float(count)
            let k = (Float(8)/6)*tan((b-a)*0.25)
            let ex = cos(b)+cx, ey = sin(b)+cy
            path.addCurve(to: mapped(ex, ey),
                          control1: mapped(cos(a)-k*sin(a)+cx, sin(a)+k*cos(a)+cy),
                          control2: mapped(ex+k*sin(b), ey-k*cos(b)))
        }
    }
}
