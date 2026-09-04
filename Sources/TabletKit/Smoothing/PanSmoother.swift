// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Speed-adaptive low-pass filter for the Pan View anchor point.
///
/// Panning amplifies hand tremor in a way ordinary cursor motion does not: the
/// whole canvas moves, so a sub-pixel wobble that reads as a steady cursor
/// reads as a shivering document. This damps that during slow, deliberate
/// pans while staying out of the way of gross motion.
///
/// Same 1€ filter family as `CursorSmoother` (Casiez, Godin & Pucheu, CHI
/// 2012) — the cutoff frequency rises with estimated speed, which is the
/// "easing" property: at rest the filter is heavy, and a fast flick passes
/// through almost unfiltered rather than arriving late. Two deliberate
/// differences from `CursorSmoother`:
///
///   - Time is real elapsed seconds, not samples. `PanScrollTracker.process`
///     already receives a `dt`, so there is no reason to assume a fixed
///     report rate here. Cutoffs below are therefore in Hz and do **not**
///     transfer numerically from `CursorSmoother`'s Te = 1 constants.
///   - The filter is *positional*, not applied to deltas. The caller derives
///     its scroll delta from how far the smoothed anchor moved. Filtering the
///     deltas directly would lose travel — a long slow pan would come up
///     short of where the pen actually went, which reads as a bug rather than
///     as smoothing. A positional anchor always converges on the raw point,
///     so total travel is preserved to within the filter's momentary lag.
///
/// Independent of `CursorSmoother` by design: Stabilization has already run
/// on the point that reaches this filter, and the two settings are separately
/// controllable (either may be zero while the other is at maximum).
public struct PanSmoother: Sendable {

    /// 0 = raw passthrough (exact, no filter math at all). 1 = strongest
    /// damping at rest, still opening up at speed.
    public var strength: Double = 0.0

    private var anchor: CGPoint = .zero
    private var hasAnchor = false
    private var lastRaw: CGPoint = .zero
    private var filteredSpeed: Double = 0.0
    private var hasFilteredSpeed = false

    /// strength → 0: cutoff stays high, i.e. barely filters even at rest.
    private static let minCutoffCeiling: Double = 15.0
    /// strength = 1, speed ≈ 0: strongest damping (~130 ms time constant at
    /// a 133 Hz report rate).
    private static let minCutoffFloor: Double = 1.2
    /// strength = 1: how fast the filter opens up, in Hz per point/second.
    /// At a brisk 2000 pt/s pan this lifts the cutoff past 25 Hz, which is
    /// effectively passthrough at pen report rates.
    private static let betaMax: Double = 0.012
    /// Cutoff for the speed estimate's own low-pass, in Hz — steadies the
    /// estimate against per-report noise.
    private static let derivativeCutoff: Double = 1.0

    /// How far the anchor is allowed to trail the raw point, per unit of
    /// speed (seconds — lag budget = this × points/second).
    ///
    /// This trailing distance is not an artifact to be minimized. When the
    /// hand stops, the anchor keeps catching up, and the caller emits that
    /// catch-up as scroll deltas — a coast, expressed purely as displacement,
    /// with no scroll-phase or momentum-phase fields attached. That reaches
    /// apps our explicit momentum tail cannot: recognizers that reject a
    /// phased stream lacking real gesture backing (Calendar Month/Year, and
    /// the same class of custom scroll views elsewhere) accept this, because
    /// to them it is simply continued scrolling.
    ///
    /// Scaling the budget by speed is what makes the coast feel earned: a
    /// slow, deliberate pan carries almost no lag and stops dead where the
    /// pen stopped, while a fast flick banks a proportionally longer glide.
    /// A fixed clamp cannot express that — it either kills the flick or
    /// makes slow panning mushy.
    private static let lagPerSpeed: Double = 0.0085

    /// Ceiling on the above, in screen points, so a violently fast flick
    /// can't bank an unrecoverable amount of travel.
    private static let maxLag: Double = 40.0

    public init() {}

    /// Forget the anchor. Call on gesture start and on suspend (pen out of
    /// range mid-pan): a stale anchor would replay the gap as a jump, which
    /// is the very thing the caller's suspend/resume handling exists to
    /// prevent.
    public mutating func reset() {
        hasAnchor = false
        hasFilteredSpeed = false
        filteredSpeed = 0
    }

    /// Feed one raw screen point and get the smoothed anchor back. `dt` is
    /// seconds since the previous call. `strength <= 0` is an exact
    /// passthrough — no filter math runs.
    public mutating func process(raw: CGPoint, dt: Double) -> CGPoint {
        guard strength > 0, dt > 0, hasAnchor else {
            anchor = raw
            lastRaw = raw
            hasAnchor = true
            hasFilteredSpeed = false
            filteredSpeed = 0
            return raw
        }

        let instantSpeed = hypot(raw.x - lastRaw.x, raw.y - lastRaw.y) / dt
        lastRaw = raw
        if hasFilteredSpeed {
            let dAlpha = Self.alpha(cutoff: Self.derivativeCutoff, dt: dt)
            filteredSpeed += dAlpha * (instantSpeed - filteredSpeed)
        } else {
            filteredSpeed = instantSpeed
            hasFilteredSpeed = true
        }

        let minCutoff =
            Self.minCutoffCeiling - strength * (Self.minCutoffCeiling - Self.minCutoffFloor)
        let beta = strength * Self.betaMax
        let a = Self.alpha(cutoff: minCutoff + beta * filteredSpeed, dt: dt)

        anchor = CGPoint(
            x: anchor.x + a * (raw.x - anchor.x),
            y: anchor.y + a * (raw.y - anchor.y))

        // Bound the trailing distance (see `lagPerSpeed`). The budget grows
        // with speed, so this binds on a violent flick and is otherwise
        // slack — the filter's own dynamics set the lag below it.
        let budget = min(Self.maxLag, Self.lagPerSpeed * filteredSpeed)
        let lag = hypot(raw.x - anchor.x, raw.y - anchor.y)
        if lag > budget {
            let pull = (lag - budget) / lag
            anchor = CGPoint(
                x: anchor.x + pull * (raw.x - anchor.x),
                y: anchor.y + pull * (raw.y - anchor.y))
        }
        return anchor
    }

    /// alpha = 1 / (1 + tau/dt), tau = 1 / (2·pi·cutoff).
    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
