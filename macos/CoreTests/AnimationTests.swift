import XCTest

final class AnimationTests:XCTestCase {
    func testKeyframesReachOriginalExtremesAndRepeat() {
        for duration in [1.0,1.5] {
            for ease in [false,true] {
                XCTAssertEqual(AnimationTiming.keyframeProgress(elapsed:0,duration:duration,easeInOut:ease),0)
                XCTAssertEqual(AnimationTiming.keyframeProgress(elapsed:duration/2,duration:duration,easeInOut:ease),1)
                XCTAssertEqual(AnimationTiming.keyframeProgress(elapsed:duration,duration:duration,easeInOut:ease),0)
                XCTAssertEqual(AnimationTiming.keyframeProgress(elapsed:duration*1.5,duration:duration,easeInOut:ease),1)
            }
        }
    }
    func testEaseInterpolationUsesCSSBezierRatherThanSine() {
        XCTAssertEqual(AnimationTiming.cubic(0.5,x1:0.25,y1:0.1,x2:0.25,y2:1),0.8024033876,accuracy:1e-9)
        XCTAssertEqual(AnimationTiming.cubic(0.5,x1:0.42,y1:0,x2:0.58,y2:1),0.5,accuracy:1e-9)
        XCTAssertEqual(AnimationTiming.keyframeProgress(elapsed:0.75,duration:1,easeInOut:false),0.1975966124,accuracy:1e-9)
    }
    func testInvalidOrNegativeTimeNeverProducesNaN() {
        for time in [Double.nan,.infinity,-1] {
            XCTAssertEqual(AnimationTiming.keyframeProgress(elapsed:time,duration:1,easeInOut:true),0)
        }
    }
}
