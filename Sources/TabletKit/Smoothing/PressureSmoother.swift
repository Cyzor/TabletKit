// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Per-report pressure smoothing. Extracted alongside `CursorSmoother` so the
/// math can be unit-tested directly.
///
/// Unlike `CursorSmoother`'s position filter — which opens up as *speed*
/// rises — this one opens up as *pressure* rises. Pressure sensors are
/// noisiest right near the activation threshold (the low-pressure band),
/// which shows up as visible line-width variation on slow, light strokes;
/// firm pressure is comparatively clean and shouldn't be touched.
///
/// HIDThread-local from the caller's perspective, same as `CursorSmoother`.
public struct PressureSmoother: Sendable {

    public private(set) var smoothedPressure: Double = 0.0
    private var hasSmoothedPressure = false

    /// 0 = raw passthrough (exact, no filter math at all). 1 = strongest
    /// smoothing near zero pressure, opening up toward passthrough as
    /// pressure rises toward a firm stroke.
    public var smoothingStrength: Double = 0.0

    /// Same rescale as `CursorSmoother.referenceRateHz` — the cutoffs were
    /// per-sample under the old Te=1 model.
    private static let referenceRateHz: Double = 133.0
    /// Cutoff at pressure ≈ 0, strength = 1: strongest smoothing.
    private static let minCutoffFloor: Double = 0.05 * referenceRateHz
    /// Cutoff at pressure = 1 (any strength), or at strength = 0: effectively passthrough.
    private static let minCutoffCeiling: Double = 8.0 * referenceRateHz

    /// alpha(cutoff, dt) = 1 / (1 + tau/dt), tau = 1/(2*pi*cutoff).
    private static func alpha(forCutoff cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    /// Same stall guard as `CursorSmoother.maxPlausibleDt`.
    private static let maxPlausibleDt: Double = 0.25

    public init() {}

    /// Smooth `rawPressure` (expected 0...1) and return the filtered value.
    /// `strokeStarting` (first report after tip-down) adopts the raw value
    /// verbatim so a new stroke's initial line width isn't delayed by a
    /// fade-in. `smoothingStrength <= 0` is an exact passthrough. `dt` is
    /// real elapsed seconds since the previous report (see CursorSmoother).
    public mutating func applySmoothing(
        rawPressure: Double, strokeStarting: Bool, dt: Double
    ) -> Double {
        guard smoothingStrength > 0 else {
            smoothedPressure = rawPressure
            hasSmoothedPressure = true
            return rawPressure
        }
        let freshStart = strokeStarting || dt <= 0 || dt > Self.maxPlausibleDt
        guard !freshStart, hasSmoothedPressure else {
            smoothedPressure = rawPressure
            hasSmoothedPressure = true
            return rawPressure
        }
        // Cutoff interpolates from a strength-scaled floor at pressure ≈ 0
        // up to the ceiling (near-passthrough) at pressure = 1, regardless
        // of strength — firm pressure is left alone.
        let cutoff =
            Self.minCutoffCeiling
            - (1.0 - rawPressure) * smoothingStrength * (Self.minCutoffCeiling - Self.minCutoffFloor)
        let alpha = Self.alpha(forCutoff: cutoff, dt: dt)
        smoothedPressure += alpha * (rawPressure - smoothedPressure)
        return smoothedPressure
    }

    /// Clears smoothing history (e.g. on tip-up / proximity exit) without
    /// touching `smoothingStrength`, which is a per-tool setting, not
    /// per-stroke state.
    public mutating func reset() {
        hasSmoothedPressure = false
    }
}
