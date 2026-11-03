import CoreGraphics
import Testing
@testable import InputCore

@Suite struct HostCoordinateMapperTests {
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func cornersAndCenterOfMainDisplay() {
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 0, normalizedY: 0, displayFrame: main) == CGPoint(x: 0, y: 0))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 1, normalizedY: 1, displayFrame: main) == CGPoint(x: 1511, y: 981))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 1, normalizedY: 0, displayFrame: main) == CGPoint(x: 1511, y: 0))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 0, normalizedY: 1, displayFrame: main) == CGPoint(x: 0, y: 981))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 0.5, normalizedY: 0.5, displayFrame: main) == CGPoint(x: 756, y: 491))
    }

    @Test func outOfRangeAndNonFiniteInputIsClamped() {
        #expect(HostCoordinateMapper.globalPoint(normalizedX: -3, normalizedY: 7, displayFrame: main) == CGPoint(x: 0, y: 981))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: .nan, normalizedY: .infinity, displayFrame: main) == CGPoint(x: 0, y: 981))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: -.infinity, normalizedY: .nan, displayFrame: main) == CGPoint(x: 0, y: 0))
    }

    @Test func secondaryDisplayWithNegativeOrigin() {
        // A display arranged to the left of and above the main display.
        let left = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 0, normalizedY: 0, displayFrame: left) == CGPoint(x: -1920, y: -300))
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 0.5, normalizedY: 0.5, displayFrame: left) == CGPoint(x: -960, y: 240))
        // The right edge must stay on this display (x = -1), never spill onto the main display at x = 0.
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 1, normalizedY: 1, displayFrame: left) == CGPoint(x: -1, y: 779))
    }

    @Test func displayToTheRightUsesItsOwnOrigin() {
        let right = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 0.25, normalizedY: 0.75, displayFrame: right) == CGPoint(x: 2152, y: 1080))
    }

    /// Mapping works in points; a Retina display's 2x pixel size never enters it, so the same normalized point
    /// lands on the same place whatever the capture resolution was.
    @Test func retinaScaleIsIrrelevantBecauseFramesAreInPoints() {
        let retinaInPoints = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let p = HostCoordinateMapper.globalPoint(normalizedX: 0.5, normalizedY: 0.5, displayFrame: retinaInPoints)
        #expect(p == CGPoint(x: 864, y: 558.5))
        #expect(p.x < 1728 && p.y < 1117)
    }

    @Test func nonStandardizedAndDegenerateFrames() {
        let flipped = CGRect(x: 100, y: 100, width: -100, height: -100) // standardizes to (0,0,100,100)
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 1, normalizedY: 1, displayFrame: flipped) == CGPoint(x: 99, y: 99))
        let tiny = CGRect(x: 10, y: 20, width: 0.5, height: 0)
        #expect(HostCoordinateMapper.globalPoint(normalizedX: 1, normalizedY: 1, displayFrame: tiny) == CGPoint(x: 10, y: 20))
    }
}
