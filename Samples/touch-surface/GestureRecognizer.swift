// SPDX-License-Identifier: MPL-2.0
//
// A small gesture recognizer over TabletKit's raw `TouchContact` stream.
// This is reference material, not a shipping component — no palm
// rejection, no support for more than two simultaneous contacts.

import Foundation
import TabletKit

enum Gesture {
    /// Single-finger drag, in the same raw device-unit space as
    /// `TouchContact.x`/`.y`. The caller scales it.
    case cursorMove(dx: Int, dy: Int)
    /// Two-finger drag. Same unit space as `cursorMove`.
    case pan(dx: Int, dy: Int)
    /// Two-finger pinch. `scale` > 1 means the fingers moved apart since
    /// the gesture started, < 1 means they moved together.
    case pinch(scale: Double)
    /// Two fingers touched down and lifted again without moving far or
    /// lingering — a gesture Wacom's own touch handling doesn't offer.
    case twoFingerTap
    /// One finger touched down and lifted without moving far or
    /// lingering. Left-click, so a `twoFingerTap` right-click's context
    /// menu has a way to select something, not just appear.
    case oneFingerTap
}

/// Tracks one continuous one- or two-finger interaction across frames and
/// emits `Gesture` values as it recognizes them. Feed it every
/// `TouchContact` frame in order.
final class GestureRecognizer {
    private struct ActiveTouch {
        var startX: Int
        var startY: Int
        var lastX: Int
        var lastY: Int
        var startTime: Date
    }

    /// Single-finger touch state. Cleared immediately on any frame that
    /// isn't exactly one contact — see `resetSingleFinger`.
    private var oneFingerTouch: ActiveTouch?
    private var twoFingerTouches: [Int: ActiveTouch] = [:]

    /// Which gesture the current two-finger sequence has committed to.
    /// `.undecided` emits nothing at all until `processTwoFinger` decides —
    /// see that function for why.
    private enum TwoFingerKind {
        case undecided
        case pan
        case pinch
    }
    private var twoFingerKind: TwoFingerKind = .undecided
    /// Centroid and inter-finger distance when the current two-finger
    /// sequence began. `processTwoFinger` measures motion against this
    /// while `.undecided`.
    private var undecidedOriginCentroid: (x: Double, y: Double)?
    private var undecidedOriginDistance: Double = 0
    /// Distance between the two fingers as of the last frame — used for a
    /// committed pinch's frame-to-frame scale.
    private var lastPinchDistance: Double = 0

    /// Consecutive frames that aren't exactly two contacts, while a
    /// two-finger gesture is in progress.
    private var twoFingerMismatchStreak = 0
    /// How many consecutive off-count frames to tolerate before treating a
    /// two-finger gesture as over. The touch sensor can drop to one
    /// contact for anywhere from 1 to ~100 frames in the middle of an
    /// otherwise continuous two-finger gesture, so this is generous —
    /// resetting too early breaks a real gesture, resetting late just
    /// delays the next one.
    private let dropGrace = 100

    /// A touch that lifts within this long, having moved less than
    /// `tapMoveThreshold`, counts as a tap rather than a drag.
    private let tapMaxDuration: TimeInterval = 0.2
    private let tapMoveThreshold = 400  // device units

    /// 1 point = 1/72 inch. Used to convert MockTab's screen-point-based
    /// tunables below into device units.
    private static let pointsToMM = 0.3528

    /// Device units per physical millimetre for the connected device,
    /// from its registry `touchMaxX`/`activeWidthMM`. This varies a lot
    /// across Wacom's touch-capable lineup, so it's supplied per device at
    /// init rather than hardcoded.
    private let deviceUnitsPerMM: Double

    /// Motion, in device units, needed to commit to pan or pinch for a
    /// two-finger sequence. Converted from MockTab's own
    /// `TouchStateTracker.twoFingerDecideDistance` (6.0 screen points) —
    /// enough to clear ordinary finger jitter.
    private let twoFingerDecideDistance: Double
    /// Pinch qualifies only when its own signal exceeds centroid
    /// translation by this ratio. Not one constant for every device — see
    /// `init`.
    private let pinchDominanceRatio: Double
    /// Absolute floor pinch's signal must also clear, on top of beating
    /// pan by `pinchDominanceRatio`.
    private let pinchNoiseFloor: Double

    /// - Parameters:
    ///   - deviceUnitsPerMM: the connected device's touch resolution
    ///     (registry `touchMaxX` / `activeWidthMM`).
    ///   - pinchDominanceRatio: how strongly a pinch must dominate
    ///     centroid translation before committing. MockTab's own
    ///     hardware-tuned value is 1.75, measured against its newer BPT3
    ///     5-slot touch sensor (the `intuosV2`/`bamboo` parser families).
    ///     That value doesn't hold for the older 16-slot sensor
    ///     (`intuosV1`): on a PTH-850, ordinary two-finger pans showed a
    ///     scale-change/translation ratio climbing past 1.75 within a few
    ///     frames, misclassifying every pan as pinch. Pass 5.0 for
    ///     `intuosV1` devices instead — this sample's own estimate, tuned
    ///     against that one device, not verified against others in the
    ///     same family.
    init(deviceUnitsPerMM: Double, pinchDominanceRatio: Double) {
        self.deviceUnitsPerMM = deviceUnitsPerMM
        self.pinchDominanceRatio = pinchDominanceRatio
        self.twoFingerDecideDistance = 6.0 * Self.pointsToMM * deviceUnitsPerMM
        self.pinchNoiseFloor = self.twoFingerDecideDistance
    }

    /// Debug switch (TOUCH_SURFACE_FORCE_PINCH=1): skips the undecided
    /// classifier and commits every two-finger touch straight to
    /// `.pinch`. Useful for telling apart "pinch is never recognized"
    /// from "pinch fires but nothing visibly happens." Not a real feature
    /// toggle.
    static let forcePinchForDebug = ProcessInfo.processInfo.environment["TOUCH_SURFACE_FORCE_PINCH"] != nil

    func process(_ contacts: [TouchContact]) -> Gesture? {
        // Single- and two-finger tracking run independently, so a
        // transition from two fingers to one (or back) doesn't leave
        // either half stuck mid-gesture.
        let oneFingerResult = contacts.count == 1
            ? processSingleFinger(contacts[0])
            : resetSingleFinger()

        switch contacts.count {
        case 2:
            return processTwoFinger(contacts[0], contacts[1])
        default:
            // A real 0-contact frame means both fingers are actually up.
            // A 1-contact frame seen mid-two-finger-gesture can just be
            // sensor dropout — only that case gets `dropGrace`'s
            // tolerance. Without this distinction, a fresh two-finger
            // touch right after a real lift can measure its first frame
            // against the previous gesture's leftover position and
            // misfire.
            let tapResult = processTwoFingerMismatch(isGenuineLift: contacts.isEmpty)
            return tapResult ?? oneFingerResult
        }
    }

    private func processSingleFinger(_ c: TouchContact) -> Gesture? {
        guard var touch = oneFingerTouch else {
            oneFingerTouch = ActiveTouch(startX: c.x, startY: c.y, lastX: c.x, lastY: c.y, startTime: Date())
            return nil
        }
        let dx = c.x - touch.lastX
        let dy = c.y - touch.lastY
        touch.lastX = c.x
        touch.lastY = c.y
        oneFingerTouch = touch
        guard dx != 0 || dy != 0 else { return nil }
        return .cursorMove(dx: dx, dy: dy)
    }

    /// Clears single-finger state immediately, with no grace period —
    /// unlike two-finger tracking, a single finger lifting is never
    /// sensor noise. Returns a completed tap if this frame is the actual
    /// moment of lift and the touch qualified as one.
    @discardableResult
    private func resetSingleFinger() -> Gesture? {
        guard let touch = oneFingerTouch else { return nil }
        oneFingerTouch = nil
        let elapsed = Date().timeIntervalSince(touch.startTime)
        let moved = abs(touch.lastX - touch.startX) < tapMoveThreshold
            && abs(touch.lastY - touch.startY) < tapMoveThreshold
        guard elapsed < tapMaxDuration, moved else { return nil }
        return .oneFingerTap
    }

    private func processTwoFinger(_ a: TouchContact, _ b: TouchContact) -> Gesture? {
        twoFingerMismatchStreak = 0
        defer { rememberTwoFinger([a, b]) }

        let currCentroid = (x: Double(a.x + b.x) / 2, y: Double(a.y + b.y) / 2)
        let currDist = distance(a.x, a.y, b.x, b.y)
        defer { lastPinchDistance = currDist }

        guard let prevA = twoFingerTouches[a.id], let prevB = twoFingerTouches[b.id] else {
            // First frame of a new two-finger touch (or the first after a
            // dropped-frame gap): anchor the undecided origin, nothing to
            // measure against yet.
            undecidedOriginCentroid = currCentroid
            undecidedOriginDistance = currDist
            twoFingerKind = Self.forcePinchForDebug ? .pinch : .undecided
            if Self.forcePinchForDebug {
                print("[debug] forced twoFingerKind to .pinch on two-finger touch-down")
            }
            return nil
        }

        let dx = ((a.x - prevA.lastX) + (b.x - prevB.lastX)) / 2
        let dy = ((a.y - prevA.lastY) + (b.y - prevB.lastY)) / 2

        switch twoFingerKind {
        case .pan:
            return dx != 0 || dy != 0 ? .pan(dx: dx, dy: dy) : nil

        case .pinch:
            guard currDist != lastPinchDistance, lastPinchDistance > 0 else { return nil }
            return .pinch(scale: currDist / lastPinchDistance)

        case .undecided:
            guard let origin = undecidedOriginCentroid else {
                // Shouldn't happen — origin is set alongside `.undecided`
                // above — but recover by anchoring now instead of using a
                // nil.
                undecidedOriginCentroid = currCentroid
                undecidedOriginDistance = currDist
                return nil
            }
            // Motion since the sequence started, not frame-to-frame:
            // per-frame deltas stay too small to mean anything at typical
            // report rates.
            let totalTranslation = (
                (currCentroid.x - origin.x) * (currCentroid.x - origin.x)
                    + (currCentroid.y - origin.y) * (currCentroid.y - origin.y)
            ).squareRoot()
            let totalScaleChange = abs(currDist - undecidedOriginDistance)

            guard totalScaleChange >= twoFingerDecideDistance
                || totalTranslation >= twoFingerDecideDistance
            else {
                // Neither signal has moved enough to mean anything yet.
                return nil
            }

            let pinchQualifies = totalScaleChange > totalTranslation * pinchDominanceRatio
                && totalScaleChange >= pinchNoiseFloor

            if pinchQualifies {
                twoFingerKind = .pinch
                return nil  // no prior distance yet to compute a scale from
            }

            twoFingerKind = .pan
            return dx != 0 || dy != 0 ? .pan(dx: dx, dy: dy) : nil
        }
    }

    /// Handles a frame that isn't exactly two contacts. Checks for a
    /// completed two-finger tap once, on the first mismatch frame — the
    /// actual moment of lift.
    ///
    /// A real 0-contact frame (`isGenuineLift`) resets state immediately.
    /// A 1-contact frame mid-gesture gets `dropGrace`'s tolerance instead,
    /// since it can be sensor dropout rather than a real lift.
    private func processTwoFingerMismatch(isGenuineLift: Bool) -> Gesture? {
        twoFingerMismatchStreak += 1
        let result = twoFingerMismatchStreak == 1 ? checkForTwoFingerTap() : nil
        if isGenuineLift || twoFingerMismatchStreak > dropGrace {
            twoFingerTouches = [:]
            twoFingerKind = .undecided
            undecidedOriginCentroid = nil
            undecidedOriginDistance = 0
        }
        return result
    }

    private func checkForTwoFingerTap() -> Gesture? {
        guard twoFingerTouches.count == 2 else { return nil }
        let all = twoFingerTouches.values
        let elapsed = all.map { Date().timeIntervalSince($0.startTime) }.max() ?? .infinity
        let moved = all.allSatisfy {
            abs($0.lastX - $0.startX) < tapMoveThreshold && abs($0.lastY - $0.startY) < tapMoveThreshold
        }
        guard elapsed < tapMaxDuration, moved else { return nil }
        return .twoFingerTap
    }

    private func rememberTwoFinger(_ contacts: [TouchContact]) {
        var next: [Int: ActiveTouch] = [:]
        for c in contacts {
            if var existing = twoFingerTouches[c.id] {
                existing.lastX = c.x
                existing.lastY = c.y
                next[c.id] = existing
            } else {
                next[c.id] = ActiveTouch(startX: c.x, startY: c.y, lastX: c.x, lastY: c.y, startTime: Date())
            }
        }
        twoFingerTouches = next
    }

    private func distance(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Double {
        let dx = Double(x1 - x2)
        let dy = Double(y1 - y2)
        return (dx * dx + dy * dy).squareRoot()
    }
}
