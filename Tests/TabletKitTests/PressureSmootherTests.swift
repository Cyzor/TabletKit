// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import TabletKit

final class PressureSmootherTests: XCTestCase {

    /// The invariant that makes this filter safe to ship as a drop-in:
    /// strength=0 must be bit-for-bit identical to raw input.
    func testStrengthZeroIsExactPassthrough() {
        var s = PressureSmoother()
        s.smoothingStrength = 0.0
        _ = s.applySmoothing(rawPressure: 0.02, strokeStarting: true)
        for p in [0.02, 0.021, 0.3, 0.019, 0.9] {
            XCTAssertEqual(s.applySmoothing(rawPressure: p, strokeStarting: false), p)
        }
    }

    /// A new stroke's first sample must not be delayed by a fade-in — the
    /// initial line width should track the pen's actual starting pressure.
    func testStrokeStartAdoptsRawVerbatim() {
        var s = PressureSmoother()
        s.smoothingStrength = 1.0
        _ = s.applySmoothing(rawPressure: 0.5, strokeStarting: true)
        _ = s.applySmoothing(rawPressure: 0.5, strokeStarting: false)
        // New stroke begins at a very different pressure — should snap, not slide.
        let out = s.applySmoothing(rawPressure: 0.05, strokeStarting: true)
        XCTAssertEqual(out, 0.05)
    }

    /// The core adaptive property: the same jitter amplitude riding on light
    /// pressure should be damped more than on firm pressure, since firm
    /// pressure's cutoff is pinned near the ceiling regardless of strength.
    func testLightPressureIsDampenedMoreThanFirmPressure() {
        func residualAmplitude(basePressure: Double) -> Double {
            var s = PressureSmoother()
            s.smoothingStrength = 1.0
            _ = s.applySmoothing(rawPressure: basePressure, strokeStarting: true)
            var maxResidual = 0.0
            for i in 0..<40 {
                let jitter = (i % 2 == 0) ? 0.02 : -0.02
                let out = s.applySmoothing(
                    rawPressure: basePressure + jitter, strokeStarting: false)
                if i > 20 {  // skip warm-up
                    maxResidual = max(maxResidual, (out - basePressure).magnitude)
                }
            }
            return maxResidual
        }

        let lightResidual = residualAmplitude(basePressure: 0.03)
        let firmResidual = residualAmplitude(basePressure: 0.8)
        XCTAssertLessThan(lightResidual, firmResidual)
    }

    func testResetClearsHistoryButPreservesStrength() {
        var s = PressureSmoother()
        s.smoothingStrength = 0.6
        _ = s.applySmoothing(rawPressure: 0.5, strokeStarting: true)
        _ = s.applySmoothing(rawPressure: 0.5, strokeStarting: false)
        XCTAssertTrue(s.smoothedPressure > 0)

        s.reset()

        XCTAssertEqual(s.smoothingStrength, 0.6)
        // Post-reset sample without strokeStarting should still snap, since
        // reset cleared hasSmoothedPressure.
        let out = s.applySmoothing(rawPressure: 0.9, strokeStarting: false)
        XCTAssertEqual(out, 0.9)
    }
}
