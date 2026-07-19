// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import XCTest

@testable import TabletKit

final class CursorSmootherTests: XCTestCase {

    // MARK: - Smoothing

    func testFirstReportAdoptsRawPointVerbatim() {
        var s = CursorSmoother()
        s.smoothingStrength = 0.3
        let out = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 50), enteringProximity: true)
        XCTAssertEqual(out.x, 100, accuracy: 1e-9)
        XCTAssertEqual(out.y, 50, accuracy: 1e-9)
        XCTAssertTrue(s.hasSmoothedPoint)
    }

    func testEnteringProximityResetsToRawEvenWithExistingSmoothedPoint() {
        var s = CursorSmoother()
        s.smoothingStrength = 0.3
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        _ = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 100), enteringProximity: false)
        // Now re-enter proximity at a new spot: should snap, not slide.
        let out = s.applySmoothing(rawPoint: CGPoint(x: 500, y: 500), enteringProximity: true)
        XCTAssertEqual(out, CGPoint(x: 500, y: 500))
    }

    /// The invariant that makes this filter safe to ship as a drop-in:
    /// strength=0 must be bit-for-bit identical to raw input, since it's
    /// the default and existing users must see zero behavior change.
    func testStrengthZeroIsExactPassthrough() {
        var s = CursorSmoother()
        s.smoothingStrength = 0.0
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        let points: [CGPoint] = [
            CGPoint(x: 5, y: -3), CGPoint(x: 5.2, y: -3.1), CGPoint(x: 40, y: 12),
            CGPoint(x: 40, y: 12), CGPoint(x: -100, y: 500),
        ]
        for p in points {
            let out = s.applySmoothing(rawPoint: p, enteringProximity: false)
            XCTAssertEqual(out, p)
        }
    }

    func testConvergesTowardStationaryTargetAfterApproach() {
        var s = CursorSmoother()
        s.smoothingStrength = 1.0
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        // Approach gradually (small per-sample steps, like a real stroke),
        // then hold the target and confirm the filter settles onto it.
        var last = CGPoint.zero
        for i in 1...20 {
            last = s.applySmoothing(
                rawPoint: CGPoint(x: CGFloat(i) * 5, y: 0), enteringProximity: false)
        }
        var errors: [CGFloat] = []
        for _ in 0..<200 {
            last = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 0), enteringProximity: false)
            errors.append((100 - last.x).magnitude)
        }
        XCTAssertLessThan(errors.last!, 0.01)
        // Error should shrink monotonically once the target stops moving.
        for i in 1..<errors.count {
            XCTAssertLessThanOrEqual(errors[i], errors[i - 1] + 1e-9)
        }
    }

    /// The whole point of switching off a flat EMA: a fast, large motion
    /// should be tracked with far less lag than the old fixed-alpha filter
    /// would have produced at the same Strength. (The old EMA at max
    /// strength used alpha=0.15, reaching only 50/75/87.5 of a (0,0)->(100,0)
    /// step over three repeated calls at the same target.)
    func testFastMotionIsTrackedWithLessLagThanFlatEMA() {
        var s = CursorSmoother()
        s.smoothingStrength = 1.0
        _ = s.applySmoothing(rawPoint: CGPoint(x: 0, y: 0), enteringProximity: true)
        // A single large, fast jump — the derivative estimate reads this as
        // high speed, so the filter should open up and track closely.
        let p1 = s.applySmoothing(rawPoint: CGPoint(x: 100, y: 0), enteringProximity: false)
        XCTAssertGreaterThan(p1.x, 90)  // old flat EMA would have landed at 50.
    }

    /// The core adaptive property: the same jitter amplitude riding on a
    /// slow drift should be damped more than the same jitter riding on a
    /// fast drift, since the filter's cutoff — and therefore how much
    /// high-frequency jitter passes through — scales with estimated speed.
    func testSlowJitterIsDampenedMoreThanFastJitter() {
        func residualAmplitude(driftPerSample: CGFloat) -> CGFloat {
            var s = CursorSmoother()
            s.smoothingStrength = 1.0
            _ = s.applySmoothing(rawPoint: .zero, enteringProximity: true)
            var trend: CGFloat = 0
            var maxResidual: CGFloat = 0
            for i in 0..<200 {
                trend += driftPerSample
                let jitter: CGFloat = (i % 2 == 0) ? 1.0 : -1.0
                let out = s.applySmoothing(
                    rawPoint: CGPoint(x: trend + jitter, y: 0), enteringProximity: false)
                if i > 100 {  // skip warm-up
                    maxResidual = max(maxResidual, (out.x - trend).magnitude)
                }
            }
            return maxResidual
        }

        let slowResidual = residualAmplitude(driftPerSample: 0.1)
        let fastResidual = residualAmplitude(driftPerSample: 8.0)
        XCTAssertLessThan(slowResidual, fastResidual)
    }

    // MARK: - Jitter window

    func testJitterLevelZeroBelowMinSamples() {
        var s = CursorSmoother()
        // Need 10 samples before jitterLevel reports anything.
        for i in 0..<9 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 10, y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 0)
        XCTAssertFalse(s.isJittery)
    }

    func testJitterLevelAveragesRecentDeltas() {
        var s = CursorSmoother()
        // 11 samples spaced 5 pts apart => 10 deltas of 5.0.
        // jitterLevel = sum / count = 50 / 10 = 5.0
        for i in 0...10 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 5, y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 5.0, accuracy: 1e-9)
        XCTAssertTrue(s.isJittery)  // > 3.0
    }

    func testJitterRingWrapsAndEvictsOldestSample() {
        var s = CursorSmoother()
        // Fill the 60-sample window with steady 1-pt deltas → average 1.0.
        // First call seeds lastRawPoint (no delta added); next 60 each
        // contribute a delta of 1.
        for i in 0...60 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i), y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 1.0, accuracy: 1e-9)
        // Drop a 100-pt spike. Previous raw was x=60, so use x=160.
        // Ring is full, so adding evicts one 1.0 sample. Sum: 60 - 1 + 100 = 159.
        s.observeHoverRaw(CGPoint(x: 160, y: 0))
        XCTAssertEqual(s.jitterLevel, 159.0 / 60.0, accuracy: 1e-9)
        // 60 more 1-pt steps fully rotate the spike out of the ring.
        for i in 1...60 {
            s.observeHoverRaw(CGPoint(x: 160 + CGFloat(i), y: 0))
        }
        XCTAssertEqual(s.jitterLevel, 1.0, accuracy: 1e-9)
    }

    func testEndHoverClearsJitterAccumulator() {
        var s = CursorSmoother()
        for i in 0...20 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 5, y: 0))
        }
        XCTAssertGreaterThan(s.jitterLevel, 0)
        s.endHover()
        XCTAssertEqual(s.jitterLevel, 0)
        // Subsequent samples should seed a fresh series, not continue the old one.
        for i in 0..<5 {
            s.observeHoverRaw(CGPoint(x: 1000 + CGFloat(i), y: 0))
        }
        // Below the 10-sample floor, jitterLevel stays 0.
        XCTAssertEqual(s.jitterLevel, 0)
    }

    // MARK: - Velocity ring

    func testRecentVelocityAveragesLastFourDeltas() {
        var s = CursorSmoother()
        s.recordMoveDelta(0)
        s.recordMoveDelta(2)
        s.recordMoveDelta(4)
        s.recordMoveDelta(6)
        // (0 + 2 + 4 + 6) / 4 = 3
        XCTAssertEqual(s.recentVelocity, 3.0, accuracy: 1e-9)
    }

    func testVelocityRingWrapsAtFour() {
        var s = CursorSmoother()
        // Fill, then overwrite the oldest with a fifth value.
        for d in [10, 10, 10, 10] as [CGFloat] {
            s.recordMoveDelta(d)
        }
        XCTAssertEqual(s.recentVelocity, 10.0, accuracy: 1e-9)
        s.recordMoveDelta(2)  // overwrites first 10
        // ring now [2, 10, 10, 10] → avg 8
        XCTAssertEqual(s.recentVelocity, 8.0, accuracy: 1e-9)
    }

    // MARK: - Proximity-exit reset

    func testResetOnProximityExitClearsEverythingExceptStrength() {
        var s = CursorSmoother()
        s.smoothingStrength = 0.42
        _ = s.applySmoothing(rawPoint: CGPoint(x: 50, y: 50), enteringProximity: true)
        _ = s.applySmoothing(rawPoint: CGPoint(x: 60, y: 55), enteringProximity: false)
        for i in 0...20 {
            s.observeHoverRaw(CGPoint(x: CGFloat(i) * 7, y: 0))
        }
        for d in [5, 5, 5, 5] as [CGFloat] { s.recordMoveDelta(d) }
        XCTAssertTrue(s.hasSmoothedPoint)
        XCTAssertGreaterThan(s.jitterLevel, 0)
        XCTAssertGreaterThan(s.recentVelocity, 0)

        s.resetOnProximityExit()

        XCTAssertFalse(s.hasSmoothedPoint)
        XCTAssertEqual(s.jitterLevel, 0)
        XCTAssertEqual(s.recentVelocity, 0)
        // Strength is intentionally preserved; it's a per-tool setting, not
        // per-stroke state — re-applied fresh on the next proximity entry.
        XCTAssertEqual(s.smoothingStrength, 0.42)
        // The derivative filter must also reset: the first post-reset sample
        // should snap (enteringProximity), not compute speed against the
        // pre-reset history.
        let out = s.applySmoothing(rawPoint: CGPoint(x: 900, y: 900), enteringProximity: true)
        XCTAssertEqual(out, CGPoint(x: 900, y: 900))
    }
}
