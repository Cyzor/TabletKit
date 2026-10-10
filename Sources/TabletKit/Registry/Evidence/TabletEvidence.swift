// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

/// Something a tablet can do, such as report pressure or touch.
///
/// An open set: new features are added as static members, so code that
/// switches over features never breaks when one appears.
public struct TabletFeature: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let penPosition = TabletFeature(rawValue: "penPosition")
    public static let pressure = TabletFeature(rawValue: "pressure")
    public static let tilt = TabletFeature(rawValue: "tilt")
    public static let eraser = TabletFeature(rawValue: "eraser")
    public static let tabletButtons = TabletFeature(rawValue: "tabletButtons")
    public static let ring = TabletFeature(rawValue: "ring")
    public static let strips = TabletFeature(rawValue: "strips")
    public static let dial = TabletFeature(rawValue: "dial")
    public static let keyDisplays = TabletFeature(rawValue: "keyDisplays")
    public static let touch = TabletFeature(rawValue: "touch")
    public static let bluetooth = TabletFeature(rawValue: "bluetooth")
    public static let wirelessReceiver = TabletFeature(rawValue: "wirelessReceiver")
    public static let displayControls = TabletFeature(rawValue: "displayControls")
}

/// How well a feature is shown to work on a model, weakest first.
public enum EvidenceLevel: Int, Comparable, Sendable, CaseIterable {
    /// The registry says so, and nothing else has been checked.
    case claimed
    /// It matches an independent public source.
    case sourced
    /// A recording of this model decodes correctly.
    case recorded
    /// It has been used live on this model.
    case hardware

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a piece of evidence comes from.
public struct EvidenceSource: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let linuxKernel = EvidenceSource(rawValue: "linuxKernel")
    public static let libwacom = EvidenceSource(rawValue: "libwacom")
    public static let openTabletDriver = EvidenceSource(rawValue: "openTabletDriver")
    /// Public collections of HID report descriptors.
    public static let descriptorCorpus = EvidenceSource(rawValue: "descriptorCorpus")
    /// Public collections of report recordings.
    public static let publicRecording = EvidenceSource(rawValue: "publicRecording")
    /// Manuals and spec sheets.
    public static let manufacturerSpec = EvidenceSource(rawValue: "manufacturerSpec")
    public static let maintainerHardware = EvidenceSource(rawValue: "maintainerHardware")
    public static let testerHardware = EvidenceSource(rawValue: "testerHardware")
}

/// The evidence for one feature of one model.
public struct FeatureEvidence: Sendable, Equatable {
    public let level: EvidenceLevel
    public let sources: [EvidenceSource]
    /// One plain sentence, if the level needs explaining.
    public let note: String?

    public init(_ level: EvidenceLevel, _ sources: [EvidenceSource] = [], note: String? = nil) {
        self.level = level
        self.sources = sources
        self.note = note
    }

    public static let claimed = FeatureEvidence(.claimed)

    /// True when something besides a recording backs this, at `.sourced` or above.
    var hasNonRecordingSource: Bool {
        level >= .sourced && sources.contains { $0 != .publicRecording }
    }
}

/// Whether a model is one MockTab sets out to support fully.
public enum SupportScope: Sendable, Equatable {
    case inScope
    /// Still decoded, but left out of gap lists. The reason is public-facing.
    case outOfScope(String)
}

extension WacomDeviceSpec {
    /// The features this row says the model has, worked out from its flags.
    public var claimedFeatures: Set<TabletFeature> {
        var features = flagFeatures
        // Evidence can name a feature the flags can't express, such as
        // display controls found at runtime.
        if let listed = WacomEvidence.table[productID] { features.formUnion(listed.keys) }
        return features
    }

    /// Pen tablets always report pressure. A touch-only tablet, such as the
    /// Bamboo Touch, keeps its touch range in the pen fields with none.
    var hasPen: Bool { maxX > 0 && maxPressure > 0 }

    /// The features implied by the row's own flags.
    var flagFeatures: Set<TabletFeature> {
        var features = Set<TabletFeature>()
        if hasPen {
            features.insert(.penPosition)
            features.insert(.pressure)
            if hasTilt { features.insert(.tilt) }
        }
        if hasEraser { features.insert(.eraser) }
        if buttonCount > 0 || bezelButtonCount > 0 { features.insert(.tabletButtons) }
        // A dial reports through the ring fields, but it isn't a ring.
        if hasMechanicalDial {
            features.insert(.dial)
        } else if hasTouchRing {
            features.insert(.ring)
        }
        if hasTouchStrips { features.insert(.strips) }
        if hasKeyOLEDs { features.insert(.keyDisplays) }
        // A touch sensor row has no flags of its own; the pen row it pairs
        // with describes its touch. A touch-only tablet keeps its range in
        // the pen fields.
        if hasFingerTouch || WacomDeviceRegistry.touchCompanionPIDs.contains(productID)
            || (!hasPen && maxX > 0)
        {
            features.insert(.touch)
        }
        if WacomEvidence.bluetoothModels.contains(productID) { features.insert(.bluetooth) }
        if WacomEvidence.receiverModels.contains(productID) { features.insert(.wirelessReceiver) }
        return features
    }

    /// Evidence for every claimed feature. Features nothing has checked are `.claimed`.
    public var evidence: [TabletFeature: FeatureEvidence] {
        let listed = WacomEvidence.table[productID] ?? [:]
        var result: [TabletFeature: FeatureEvidence] = [:]
        for feature in claimedFeatures { result[feature] = listed[feature] ?? .claimed }
        return result
    }

    public var scope: SupportScope {
        WacomEvidence.outOfScope[productID].map(SupportScope.outOfScope) ?? .inScope
    }

    /// The tier this row's evidence supports. For a pen tablet, pen position
    /// and pressure decide it. A row without a pen, such as a touch sensor or
    /// a remote, is judged on everything it claims. All of them proven on
    /// hardware means verified, and all of them at least matching a public
    /// source means cross-referenced. A recording alone doesn't raise the
    /// tier, so the public status errs low.
    public var evidenceTier: ConfidenceTier {
        let deciding: [TabletFeature] =
            hasPen ? [.penPosition, .pressure] : Array(claimedFeatures)
        let core = deciding.compactMap { evidence[$0] }
        guard !core.isEmpty, core.count == deciding.count else { return .experimental }
        if core.allSatisfy({ $0.level == .hardware }) { return .verified }
        if core.allSatisfy({ $0.level == .hardware || $0.hasNonRecordingSource }) {
            return .crossReferenced
        }
        return .experimental
    }
}
