// MockTab — native macOS driver for supported drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Pure-state helpers for the pen cursor's per-report smoothing, jitter
/// estimation, and short-window velocity tracking. Extracted from
/// `InputInjector` so the math can be unit-tested directly.
///
/// All mutating methods are HIDThread-local from the caller's perspective —
/// the struct itself imposes no thread model. `InputInjector` holds one
/// instance and owns its lifecycle.
public struct CursorSmoother {

    // MARK: - Jitter tracking
    //
    // Fixed ring buffer + running sum.
    // Eliminates O(n) Array.removeFirst() and a full reduce() on every jitterLevel read.

    public static let jitterWindow = 60  // ~0.5 s at 133 Hz
    private var hoverRing = ContiguousArray<CGFloat>(repeating: 0, count: CursorSmoother.jitterWindow)
    private var hoverHead = 0
    private var hoverCount = 0
    private var hoverSum: CGFloat = 0
    private var lastRawPoint: CGPoint = .zero
    private var hasLastRawPoint = false

    // MARK: - One-Euro smoothing
    //
    // Adaptive low-pass filter (Casiez, Godin & Pucheu, "1€ Filter", CHI 2012):
    // the cutoff frequency rises with estimated speed, so jitter is damped
    // heavily when the pen is nearly still and the filter gets out of the way
    // during fast strokes. The flat EMA this replaced applied the same lag
    // regardless of speed, which is fine at rest but causes corner-cutting
    // and stroke-end overshoot on fast motion.
    //
    // Time is measured in samples (Te = 1), not wall-clock seconds — reports
    // don't carry a reliable per-sample timestamp on this path (see
    // InputInjector.currentReportTimestampNs), and devices report at a
    // steady enough rate for a fixed-Te filter to behave predictably. If
    // cross-device feel testing shows `smoothingStrength` landing
    // differently on devices with very different report rates, switch this
    // to real elapsed time.

    public private(set) var smoothedPoint: CGPoint = .zero
    public private(set) var hasSmoothedPoint = false
    /// 0 = raw passthrough (exact, no filter math at all). 1 = strongest
    /// smoothing at rest, still opening up at high speed.
    public var smoothingStrength: Double = 0.0

    /// strength → 0: cutoff stays high, i.e. barely filters even at rest.
    private static let minCutoffCeiling: Double = 2.0
    /// strength = 1, speed ≈ 0: strongest smoothing.
    private static let minCutoffFloor: Double = 0.03
    /// strength = 1: how fast the filter opens up as speed increases.
    private static let betaMax: Double = 0.4
    /// Cutoff for the derivative's own low-pass — steadies the speed
    /// estimate against per-sample noise.
    private static let derivativeCutoff: Double = 1.0

    private var lastFilterRawPoint: CGPoint = .zero
    private var filteredDelta: CGVector = .zero
    private var hasFilteredDelta = false

    /// Te = 1 (one sample): alpha(cutoff) = 1 / (1 + tau), tau = 1/(2*pi*cutoff).
    private static func alpha(forCutoff cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau)
    }

    // MARK: - Short-window velocity (last 4 position deltas)

    private var recentDeltas = ContiguousArray<CGFloat>(repeating: 0, count: 4)
    private var recentDeltaHead = 0

    public init() {}

    // MARK: - Reads

    /// Mean hover-position delta over the rolling window (points per sample).
    /// Spikes above ~3 pt/sample while hovering suggest RF interference.
    public var jitterLevel: CGFloat {
        guard hoverCount >= 10 else { return 0 }
        return hoverSum / CGFloat(hoverCount)
    }

    public var isJittery: Bool { jitterLevel > 3.0 }

    /// Rolling 4-sample velocity estimate in screen points per sample.
    public var recentVelocity: CGFloat {
        recentDeltas.reduce(0, +) / CGFloat(recentDeltas.count)
    }

    // MARK: - Mutations

    /// Apply adaptive smoothing to `rawPoint` and return the smoothed result.
    /// On proximity entry (or first ever call) the raw point is adopted
    /// as-is to avoid an initial slide-in from the previous smoothedPoint.
    /// `smoothingStrength <= 0` is an exact passthrough — no filter math runs.
    public mutating func applySmoothing(rawPoint: CGPoint, enteringProximity: Bool) -> CGPoint {
        guard smoothingStrength > 0 else {
            smoothedPoint = rawPoint
            hasSmoothedPoint = true
            lastFilterRawPoint = rawPoint
            filteredDelta = .zero
            hasFilteredDelta = false
            return rawPoint
        }

        guard !enteringProximity, hasSmoothedPoint else {
            smoothedPoint = rawPoint
            hasSmoothedPoint = true
            lastFilterRawPoint = rawPoint
            filteredDelta = .zero
            hasFilteredDelta = false
            return smoothedPoint
        }

        // Estimate speed from a low-pass-filtered derivative (Te = 1 sample).
        let rawDelta = CGVector(
            dx: rawPoint.x - lastFilterRawPoint.x, dy: rawPoint.y - lastFilterRawPoint.y)
        lastFilterRawPoint = rawPoint
        let dAlpha = Self.alpha(forCutoff: Self.derivativeCutoff)
        if hasFilteredDelta {
            filteredDelta = CGVector(
                dx: filteredDelta.dx + dAlpha * (rawDelta.dx - filteredDelta.dx),
                dy: filteredDelta.dy + dAlpha * (rawDelta.dy - filteredDelta.dy))
        } else {
            filteredDelta = rawDelta
            hasFilteredDelta = true
        }
        let speed = hypot(filteredDelta.dx, filteredDelta.dy)

        let minCutoff =
            Self.minCutoffCeiling - smoothingStrength * (Self.minCutoffCeiling - Self.minCutoffFloor)
        let beta = smoothingStrength * Self.betaMax
        let alpha = Self.alpha(forCutoff: minCutoff + beta * speed)

        smoothedPoint = CGPoint(
            x: smoothedPoint.x + alpha * (rawPoint.x - smoothedPoint.x),
            y: smoothedPoint.y + alpha * (rawPoint.y - smoothedPoint.y)
        )
        return smoothedPoint
    }

    /// Feed a raw hover sample. Updates the rolling jitter window with the
    /// distance from the previous raw point (or seeds the previous point
    /// on first call).
    public mutating func observeHoverRaw(_ rawPoint: CGPoint) {
        if hasLastRawPoint {
            addHoverDelta(
                hypot(rawPoint.x - lastRawPoint.x, rawPoint.y - lastRawPoint.y))
        }
        lastRawPoint = rawPoint
        hasLastRawPoint = true
    }

    /// Called when the pen is no longer hovering (tip is down): pauses
    /// jitter accumulation and discards the existing window.
    public mutating func endHover() {
        hasLastRawPoint = false
        clearHoverDeltas()
    }

    /// Record a per-frame screen-space position delta (used by tip-up assist
    /// to gauge velocity at lift-off).
    public mutating func recordMoveDelta(_ delta: CGFloat) {
        recentDeltas[recentDeltaHead] = delta
        recentDeltaHead = (recentDeltaHead + 1) % recentDeltas.count
    }

    /// Full reset for proximity exit: clears smoothed point, the derivative
    /// filter's history, jitter ring, and velocity ring. Leaves
    /// `smoothingStrength` untouched (it's a per-tool setting, not per-stroke
    /// state).
    public mutating func resetOnProximityExit() {
        hasSmoothedPoint = false
        filteredDelta = .zero
        hasFilteredDelta = false
        hasLastRawPoint = false
        clearHoverDeltas()
        for i in recentDeltas.indices { recentDeltas[i] = 0 }
        recentDeltaHead = 0
    }

    // MARK: - Private helpers

    private mutating func addHoverDelta(_ delta: CGFloat) {
        if hoverCount == Self.jitterWindow {
            hoverSum -= hoverRing[hoverHead]
        } else {
            hoverCount += 1
        }
        hoverRing[hoverHead] = delta
        hoverSum += delta
        hoverHead = (hoverHead + 1) % Self.jitterWindow
    }

    private mutating func clearHoverDeltas() {
        guard hoverCount > 0 else { return }
        hoverCount = 0
        hoverSum = 0
    }
}
