// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A coarse summary of what one byte position did across a set of captured
/// samples — everything `detect(_:)` needs, and nothing device-specific.
///
/// Deliberately narrower than a full per-byte statistics type (no value list,
/// no truncation flag): the detector only ever buckets `distinctCount` and
/// `max`, so callers can build this straight from whatever summary they
/// already keep rather than reshaping one.
@_spi(TabletKitInternals) public struct ByteVarianceSignature: Equatable {
    public let distinctCount: Int
    public let max: Int

    public init(distinctCount: Int, max: Int) {
        self.distinctCount = distinctCount
        self.max = max
    }
}

/// One level of repeating byte-stride structure: a stride, how many times it
/// repeats, and how confidently.
///
/// Both `RepeatingReportStructure.outer` and `.nested` are this same type —
/// nesting is capped at one level rather than made recursive (a struct can't
/// contain itself, and an indirect/boxed type would let a caller construct an
/// arbitrarily deep result the detector itself never produces). One level of
/// nesting is also as deep as `detect(_:)` ever searches, so the type says
/// exactly as much as the algorithm can actually claim.
@_spi(TabletKitInternals) public struct RepeatingRun: Equatable {
    /// Byte offset where the repeating region begins.
    public let startOffset: Int
    /// Stride between repeats, in bytes.
    public let period: Int
    /// How many full repeats fit inside the covered range.
    public let repeatCount: Int
    /// Fraction of adjacent-repeat byte pairs whose coarse signature agreed.
    /// 1.0 means every compared position matched its counterpart one period
    /// away.
    public let matchFraction: Double
}

/// A repeating byte-stride structure detected in a report, with an optional
/// second level found inside one repeat of the first.
///
/// `RepeatingReportStructureDetector.detect(_:)` is the only way to construct
/// one — the fields are read-only outside the module the same way a decoded
/// frame is, since a hand-built value would misrepresent evidence nothing
/// actually observed.
@_spi(TabletKitInternals) public struct RepeatingReportStructure: Equatable {
    /// The outermost repeating structure found.
    public let outer: RepeatingRun
    /// A structure found by re-running detection inside a single repeat of
    /// `outer`, at offsets relative to `outer.startOffset`. `nil` when no
    /// sub-period cleared the same thresholds.
    public let nested: RepeatingRun?
}

/// Finds repeating byte-stride structure in a report using only the kind of
/// per-position variance statistics `DiscoveryAccumulator` already collects —
/// no descriptor, no knowledge of what the bytes mean.
///
/// Exists because the descriptor-driven tools in this file
/// (`PrecisionTouchLayout`, `classifyDigitizerInterface`) are blind on the
/// devices that need this most: classic Wacom BT reports declare every field
/// as vendor page `0xFF0D` usage `0x00`, opaque by construction, so there is
/// no descriptor to derive from. A capture's byte statistics are the only
/// evidence available, and the shape of that evidence — a block of bytes that
/// behaves the same way every N positions — is itself the signal that the
/// report packs several repeated sub-records (touch contacts, frames, slots),
/// which is exactly the fact a capture's flat byte-position list currently
/// hides.
///
/// Confirmed against two real captures rather than synthetic data: a PTH-860
/// BT report where this recovers the kernel-documented 4×43-byte frame /
/// 5×8-byte contact layout from statistics alone, and a CTH-690 report with
/// no repeating structure, where every candidate period is correctly
/// rejected.
@_spi(TabletKitInternals) public enum RepeatingReportStructureDetector {

    /// Two byte positions are treated as behaving alike when their variance
    /// falls in the same coarse bucket, not when it matches exactly. Real
    /// repeated fields never agree byte-for-byte across samples (an X low
    /// byte and a Y low byte both look "wide and noisy" without being
    /// identical), so an exact-equality test would find nothing; the buckets
    /// below are wide enough to call those alike while still separating a
    /// status/flags byte from a coordinate byte.
    private static func bucket(_ signature: ByteVarianceSignature) -> (Int, Int) {
        (Swift.min(signature.distinctCount, 3), signature.max / 32)
    }

    /// Fraction of positions `period` apart, within `range`, whose buckets
    /// agree — and the number of pairs that comparison was based on, since a
    /// fraction computed from very few pairs is not evidence of anything.
    private static func score(
        period: Int,
        range: ClosedRange<Int>,
        signatures: [Int: ByteVarianceSignature]
    ) -> (matchFraction: Double, pairCount: Int) {
        var hits = 0
        var total = 0
        for offset in range.lowerBound...(range.upperBound - period) {
            guard let a = signatures[offset], let b = signatures[offset + period] else { continue }
            total += 1
            if bucket(a) == bucket(b) { hits += 1 }
        }
        guard total > 0 else { return (0, 0) }
        return (Double(hits) / Double(total), total)
    }

    /// Best period found in `range`, or `nil` when nothing clears the
    /// thresholds.
    ///
    /// Requiring `minRepeatCount` full repeats is what keeps this from
    /// declaring victory on a coincidence: without it, a period close to the
    /// width of a small varying range "matches" on a single compared pair and
    /// scores 100%, which is exactly the kind of degenerate case a narrow
    /// report (a handful of varying bytes with nothing repeating) produces.
    private static func bestPeriod(
        in range: ClosedRange<Int>,
        signatures: [Int: ByteVarianceSignature],
        minMatchFraction: Double,
        minRepeatCount: Int
    ) -> RepeatingRun? {
        let span = range.upperBound - range.lowerBound + 1
        guard span >= minRepeatCount * 2 else { return nil }

        var best: (period: Int, matchFraction: Double, pairCount: Int)?
        for period in 2...(span / minRepeatCount) {
            let repeatCount = span / period
            guard repeatCount >= minRepeatCount else { continue }
            let (fraction, pairCount) = score(period: period, range: range, signatures: signatures)
            guard fraction >= minMatchFraction else { continue }
            // Prefer the strongest match; a tie goes to the larger period —
            // the outer frame, not one of its own harmonics (a period-43
            // structure always also "matches" at 86, 129, ... with equal or
            // lower confidence, and the frame is the more useful annotation).
            if best == nil || fraction > best!.matchFraction
                || (fraction == best!.matchFraction && period > best!.period) {
                best = (period, fraction, pairCount)
            }
        }
        guard let best else { return nil }
        return RepeatingRun(
            startOffset: range.lowerBound, period: best.period,
            repeatCount: span / best.period, matchFraction: best.matchFraction)
    }

    /// Detects repeating structure in one report's byte-variance signatures.
    ///
    /// - Parameters:
    ///   - signatures: Per-byte-position summaries, keyed by offset. Only
    ///     positions that vary need be present — omit constant and absent
    ///     positions rather than representing them with a degenerate
    ///     signature, since either would bias the match count.
    ///   - minMatchFraction: How well adjacent repeats must agree to count.
    ///     0.75 by default — loose enough to survive one differing byte in a
    ///     mixed status/coordinate frame, tight enough that the 60% found in
    ///     the CTH-690 negative case does not qualify.
    ///   - minRepeatCount: How many full repeats must fit before a period is
    ///     considered, not merely detected once. 3 by default.
    /// - Returns: The best-scoring structure, with a nested structure found
    ///   inside its first repeat when one clears the same thresholds. `nil`
    ///   when nothing does — the correct answer for a report with no
    ///   repeating structure, not a caller error.
    public static func detect(
        signatures: [Int: ByteVarianceSignature],
        minMatchFraction: Double = 0.75,
        minRepeatCount: Int = 3
    ) -> RepeatingReportStructure? {
        let offsets = signatures.keys
        guard let lo = offsets.min(), let hi = offsets.max() else { return nil }

        guard let outer = bestPeriod(
            in: lo...hi, signatures: signatures,
            minMatchFraction: minMatchFraction, minRepeatCount: minRepeatCount)
        else { return nil }

        // The nested search only looks inside the outer period's first
        // repeat. Real sub-structure (one contact slot within one touch
        // frame) recurs identically in every outer repeat, so the first is
        // representative — and searching the full range a second time would
        // just rediscover the outer period itself as a "nested" harmonic.
        let innerRange = lo...Swift.min(lo + outer.period - 1, hi)
        let nested = bestPeriod(
            in: innerRange, signatures: signatures,
            minMatchFraction: minMatchFraction, minRepeatCount: minRepeatCount)

        return RepeatingReportStructure(outer: outer, nested: nested)
    }
}
