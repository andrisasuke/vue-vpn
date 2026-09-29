import Foundation

/// Timing curves from the original CSS keyframes. Resolve x(t) before y(t);
/// substituting a sine wave gives different opacity/spread between keyframes.
enum AnimationTiming {
    static func cubic(_ progress: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let inverse = 1-t
            return 3*inverse*inverse*t*a+3*inverse*t*t*b+t*t*t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let midpoint = (low+high)/2
            if coordinate(midpoint,x1,x2) < progress { low = midpoint } else { high = midpoint }
        }
        return coordinate((low+high)/2,y1,y2)
    }

    static func keyframeProgress(elapsed: Double, duration: Double, easeInOut: Bool) -> Double {
        guard elapsed.isFinite, elapsed >= 0, duration > 0 else { return 0 }
        let cycle = elapsed.truncatingRemainder(dividingBy:duration)/duration
        let segment = cycle < 0.5 ? cycle*2 : (cycle-0.5)*2
        let progress = easeInOut ? cubic(segment,x1:0.42,y1:0,x2:0.58,y2:1) : cubic(segment,x1:0.25,y1:0.1,x2:0.25,y2:1)
        return cycle < 0.5 ? progress : 1-progress
    }
}
