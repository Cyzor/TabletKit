// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import XCTest

@testable import TabletKit

final class PanSmootherTests: XCTestCase {

    private let dt = 1.0 / 133.0

    func testZeroStrengthIsExactPassthrough() {
        var s = PanSmoother()
        for i in 0..<50 {
            let p = CGPoint(x: Double(i) * 1.37, y: Double(i) * -0.41)
            XCTAssertEqual(s.process(raw: p, dt: dt), p)
        }
    }

    func testFirstSampleAdoptsRawPoint() {
        var s = PanSmoother()
        s.strength = 1.0
        let p = CGPoint(x: 500, y: 300)
        XCTAssertEqual(s.process(raw: p, dt: dt), p, "no slide-in from a stale anchor")
    }

    /// The property the whole positional design exists to guarantee: a long
    /// pan must arrive where the pen arrived. A delta-domain filter loses
    /// travel here.
    func testLongPanPreservesTotalTravel() {
        var s = PanSmoother()
        s.strength = 1.0
        var last = CGPoint(x: 0, y: 0)
        _ = s.process(raw: last, dt: dt)
        for i in 1...400 {
            last = s.process(raw: CGPoint(x: Double(i) * 2.0, y: 0), dt: dt)
        }
        // Then hold still — the anchor converges on the raw point.
        for _ in 0..<200 {
            last = s.process(raw: CGPoint(x: 800, y: 0), dt: dt)
        }
        XCTAssertEqual(last.x, 800, accuracy: 0.5)
    }

    func testDampsJitterAtRest() {
        var s = PanSmoother()
        s.strength = 1.0
        _ = s.process(raw: .zero, dt: dt)
        var worst = 0.0
        for i in 0..<200 {
            // ±1.5 pt alternating tremor around the origin.
            let raw = CGPoint(x: i % 2 == 0 ? 1.5 : -1.5, y: 0)
            worst = max(worst, abs(s.process(raw: raw, dt: dt).x))
        }
        XCTAssertLessThan(worst, 0.4, "tremor should be damped to a fraction of its amplitude")
    }

    /// The "easing" property: a fast pan must not lag the way a slow one is
    /// damped, or gross motion would feel rubbery.
    func testFastMotionPassesThroughLessFiltered() {
        func lagFraction(speedPerSample: Double) -> Double {
            var s = PanSmoother()
            s.strength = 1.0
            _ = s.process(raw: .zero, dt: dt)
            var out = CGPoint.zero
            for i in 1...60 {
                out = s.process(raw: CGPoint(x: Double(i) * speedPerSample, y: 0), dt: dt)
            }
            let ideal = 60 * speedPerSample
            return (ideal - out.x) / ideal
        }
        XCTAssertLessThan(
            lagFraction(speedPerSample: 20.0), lagFraction(speedPerSample: 0.2),
            "cutoff should rise with speed")
    }

    /// Travel the anchor emits after the hand stops. This is the coast, and
    /// it is deliberate — see `PanSmoother.lagPerSpeed`. It must scale with
    /// how fast the pen was moving (a creep stops dead, a flick glides) and
    /// stay bounded at the top end.
    private func coastDistance(speed: Double) -> Double {
        var s = PanSmoother()
        s.strength = 1.0
        var x = 0.0
        _ = s.process(raw: .zero, dt: dt)
        for _ in 0..<25 {
            x += speed
            _ = s.process(raw: CGPoint(x: x, y: 0), dt: dt)
        }
        var coast = 0.0
        var prev = s.process(raw: CGPoint(x: x, y: 0), dt: dt)
        for _ in 0..<600 {
            let next = s.process(raw: CGPoint(x: x, y: 0), dt: dt)
            coast += hypot(next.x - prev.x, next.y - prev.y)
            prev = next
        }
        return coast
    }

    func testSlowPanStopsWhereThePenStops() {
        XCTAssertLessThan(
            coastDistance(speed: 0.5), 1.0,
            "a deliberate creep must not glide — that would read as mush, not momentum")
    }

    func testCoastScalesWithFlickSpeed() {
        let creep = coastDistance(speed: 1.0)
        let brisk = coastDistance(speed: 8.0)
        let flick = coastDistance(speed: 15.0)
        XCTAssertLessThan(creep, brisk)
        XCTAssertLessThan(brisk, flick)
    }

    func testCoastStaysBoundedOnAViolentFlick() {
        XCTAssertLessThan(
            coastDistance(speed: 40.0), 45.0,
            "the lag budget caps how much travel a flick can bank")
    }

    func testResetForgetsAnchorSoResumeDoesNotJump() {
        var s = PanSmoother()
        s.strength = 1.0
        _ = s.process(raw: CGPoint(x: 0, y: 0), dt: dt)
        s.reset()
        let far = CGPoint(x: 900, y: 900)
        XCTAssertEqual(s.process(raw: far, dt: dt), far)
    }
}
