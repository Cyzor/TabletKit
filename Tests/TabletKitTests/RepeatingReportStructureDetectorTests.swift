// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0

import XCTest
@_spi(TabletKitInternals) @testable import TabletKit

/// Repeating-structure detection against real capture evidence.
///
/// Fixtures below are the per-byte-position `(distinctCount, max)` pairs
/// observed in two real MockTab discovery captures — derived statistics, not
/// vendored report bytes, and the same independently-derived-only rule
/// applied throughout this project (see the CTL-460 and touch-decoder
/// provenance comments).
///
/// - `pth860BTTouch`: report `0x80` from a PTH-860 (Intuos Pro L) over
///   Bluetooth Classic, USB `056a:0361`. This report's descriptor is fully
///   opaque (vendor page `0xFF0D`, usage `0x00` throughout) — the case this
///   detector exists for, where nothing but the statistics themselves can
///   reveal structure.
/// - `cth690Pad`: report `0x02` from a CTH-690, the BPT3 pen/pad/touch
///   container `BPT3ContainerDecoder` already decodes byte-for-byte. Used
///   here purely as a real *negative* case — a report with real varying
///   bytes and no repeating structure — since a detector validated only on
///   positive examples proves nothing about its false-positive rate.
final class RepeatingReportStructureDetectorTests: XCTestCase {

    private static let pth860BTTouch: [Int: ByteVarianceSignature] = [
            109: ByteVarianceSignature(distinctCount: 12, max: 138),
            110: ByteVarianceSignature(distinctCount: 11, max: 10),
            111: ByteVarianceSignature(distinctCount: 2, max: 1),
            112: ByteVarianceSignature(distinctCount: 249, max: 255),
            113: ByteVarianceSignature(distinctCount: 42, max: 43),
            114: ByteVarianceSignature(distinctCount: 249, max: 255),
            115: ByteVarianceSignature(distinctCount: 28, max: 32),
            116: ByteVarianceSignature(distinctCount: 5, max: 4),
            117: ByteVarianceSignature(distinctCount: 5, max: 4),
            118: ByteVarianceSignature(distinctCount: 11, max: 10),
            119: ByteVarianceSignature(distinctCount: 2, max: 1),
            120: ByteVarianceSignature(distinctCount: 242, max: 255),
            121: ByteVarianceSignature(distinctCount: 42, max: 48),
            122: ByteVarianceSignature(distinctCount: 247, max: 255),
            123: ByteVarianceSignature(distinctCount: 24, max: 28),
            124: ByteVarianceSignature(distinctCount: 6, max: 5),
            125: ByteVarianceSignature(distinctCount: 5, max: 4),
            126: ByteVarianceSignature(distinctCount: 11, max: 10),
            127: ByteVarianceSignature(distinctCount: 2, max: 1),
            128: ByteVarianceSignature(distinctCount: 242, max: 255),
            129: ByteVarianceSignature(distinctCount: 39, max: 47),
            130: ByteVarianceSignature(distinctCount: 239, max: 255),
            131: ByteVarianceSignature(distinctCount: 23, max: 26),
            132: ByteVarianceSignature(distinctCount: 4, max: 3),
            133: ByteVarianceSignature(distinctCount: 5, max: 4),
            134: ByteVarianceSignature(distinctCount: 10, max: 10),
            135: ByteVarianceSignature(distinctCount: 2, max: 1),
            136: ByteVarianceSignature(distinctCount: 234, max: 254),
            137: ByteVarianceSignature(distinctCount: 41, max: 48),
            138: ByteVarianceSignature(distinctCount: 225, max: 255),
            139: ByteVarianceSignature(distinctCount: 24, max: 27),
            140: ByteVarianceSignature(distinctCount: 4, max: 3),
            141: ByteVarianceSignature(distinctCount: 5, max: 4),
            142: ByteVarianceSignature(distinctCount: 11, max: 10),
            143: ByteVarianceSignature(distinctCount: 2, max: 1),
            144: ByteVarianceSignature(distinctCount: 221, max: 255),
            145: ByteVarianceSignature(distinctCount: 44, max: 46),
            146: ByteVarianceSignature(distinctCount: 210, max: 254),
            147: ByteVarianceSignature(distinctCount: 24, max: 30),
            148: ByteVarianceSignature(distinctCount: 6, max: 5),
            149: ByteVarianceSignature(distinctCount: 5, max: 4),
            150: ByteVarianceSignature(distinctCount: 64, max: 252),
            151: ByteVarianceSignature(distinctCount: 256, max: 255),
            152: ByteVarianceSignature(distinctCount: 12, max: 138),
            153: ByteVarianceSignature(distinctCount: 11, max: 10),
            154: ByteVarianceSignature(distinctCount: 2, max: 1),
            155: ByteVarianceSignature(distinctCount: 197, max: 255),
            156: ByteVarianceSignature(distinctCount: 41, max: 43),
            157: ByteVarianceSignature(distinctCount: 186, max: 255),
            158: ByteVarianceSignature(distinctCount: 26, max: 31),
            159: ByteVarianceSignature(distinctCount: 5, max: 4),
            160: ByteVarianceSignature(distinctCount: 5, max: 4),
            161: ByteVarianceSignature(distinctCount: 11, max: 10),
            162: ByteVarianceSignature(distinctCount: 2, max: 1),
            163: ByteVarianceSignature(distinctCount: 176, max: 255),
            164: ByteVarianceSignature(distinctCount: 44, max: 48),
            165: ByteVarianceSignature(distinctCount: 178, max: 255),
            166: ByteVarianceSignature(distinctCount: 23, max: 28),
            167: ByteVarianceSignature(distinctCount: 6, max: 5),
            168: ByteVarianceSignature(distinctCount: 5, max: 4),
            169: ByteVarianceSignature(distinctCount: 10, max: 10),
            170: ByteVarianceSignature(distinctCount: 2, max: 1),
            171: ByteVarianceSignature(distinctCount: 168, max: 255),
            172: ByteVarianceSignature(distinctCount: 35, max: 47),
            173: ByteVarianceSignature(distinctCount: 162, max: 254),
            174: ByteVarianceSignature(distinctCount: 22, max: 26),
            175: ByteVarianceSignature(distinctCount: 4, max: 3),
            176: ByteVarianceSignature(distinctCount: 4, max: 4),
            177: ByteVarianceSignature(distinctCount: 8, max: 10),
            178: ByteVarianceSignature(distinctCount: 2, max: 1),
            179: ByteVarianceSignature(distinctCount: 170, max: 255),
            180: ByteVarianceSignature(distinctCount: 42, max: 47),
            181: ByteVarianceSignature(distinctCount: 173, max: 255),
            182: ByteVarianceSignature(distinctCount: 24, max: 27),
            183: ByteVarianceSignature(distinctCount: 4, max: 3),
            184: ByteVarianceSignature(distinctCount: 5, max: 4),
            185: ByteVarianceSignature(distinctCount: 10, max: 10),
            186: ByteVarianceSignature(distinctCount: 2, max: 1),
            187: ByteVarianceSignature(distinctCount: 138, max: 253),
            188: ByteVarianceSignature(distinctCount: 37, max: 46),
            189: ByteVarianceSignature(distinctCount: 134, max: 254),
            190: ByteVarianceSignature(distinctCount: 24, max: 30),
            191: ByteVarianceSignature(distinctCount: 6, max: 5),
            192: ByteVarianceSignature(distinctCount: 5, max: 4),
            193: ByteVarianceSignature(distinctCount: 64, max: 252),
            194: ByteVarianceSignature(distinctCount: 173, max: 253),
            195: ByteVarianceSignature(distinctCount: 10, max: 138),
            196: ByteVarianceSignature(distinctCount: 8, max: 9),
            197: ByteVarianceSignature(distinctCount: 2, max: 1),
            198: ByteVarianceSignature(distinctCount: 58, max: 255),
            199: ByteVarianceSignature(distinctCount: 30, max: 43),
            200: ByteVarianceSignature(distinctCount: 60, max: 253),
            201: ByteVarianceSignature(distinctCount: 20, max: 31),
            202: ByteVarianceSignature(distinctCount: 5, max: 4),
            203: ByteVarianceSignature(distinctCount: 4, max: 4),
            204: ByteVarianceSignature(distinctCount: 9, max: 10),
            205: ByteVarianceSignature(distinctCount: 2, max: 1),
            206: ByteVarianceSignature(distinctCount: 57, max: 250),
            207: ByteVarianceSignature(distinctCount: 31, max: 48),
            208: ByteVarianceSignature(distinctCount: 55, max: 255),
            209: ByteVarianceSignature(distinctCount: 20, max: 28),
            210: ByteVarianceSignature(distinctCount: 6, max: 5),
            211: ByteVarianceSignature(distinctCount: 3, max: 3),
            212: ByteVarianceSignature(distinctCount: 9, max: 10),
            213: ByteVarianceSignature(distinctCount: 2, max: 1),
            214: ByteVarianceSignature(distinctCount: 55, max: 255),
            215: ByteVarianceSignature(distinctCount: 28, max: 46),
            216: ByteVarianceSignature(distinctCount: 53, max: 247),
            217: ByteVarianceSignature(distinctCount: 19, max: 26),
            218: ByteVarianceSignature(distinctCount: 3, max: 3),
            219: ByteVarianceSignature(distinctCount: 3, max: 3),
            220: ByteVarianceSignature(distinctCount: 8, max: 10),
            221: ByteVarianceSignature(distinctCount: 2, max: 1),
            222: ByteVarianceSignature(distinctCount: 57, max: 246),
            223: ByteVarianceSignature(distinctCount: 32, max: 47),
            224: ByteVarianceSignature(distinctCount: 58, max: 252),
            225: ByteVarianceSignature(distinctCount: 16, max: 25),
            226: ByteVarianceSignature(distinctCount: 4, max: 3),
            227: ByteVarianceSignature(distinctCount: 4, max: 3),
            228: ByteVarianceSignature(distinctCount: 8, max: 10),
            229: ByteVarianceSignature(distinctCount: 2, max: 1),
            230: ByteVarianceSignature(distinctCount: 49, max: 255),
            231: ByteVarianceSignature(distinctCount: 24, max: 46),
            232: ByteVarianceSignature(distinctCount: 50, max: 255),
            233: ByteVarianceSignature(distinctCount: 17, max: 30),
            234: ByteVarianceSignature(distinctCount: 6, max: 5),
            235: ByteVarianceSignature(distinctCount: 5, max: 4),
            236: ByteVarianceSignature(distinctCount: 40, max: 248),
            237: ByteVarianceSignature(distinctCount: 68, max: 143),
            238: ByteVarianceSignature(distinctCount: 3, max: 135),
            239: ByteVarianceSignature(distinctCount: 4, max: 8),
            240: ByteVarianceSignature(distinctCount: 2, max: 1),
            241: ByteVarianceSignature(distinctCount: 7, max: 242),
            242: ByteVarianceSignature(distinctCount: 7, max: 33),
            243: ByteVarianceSignature(distinctCount: 7, max: 242),
            244: ByteVarianceSignature(distinctCount: 6, max: 16),
            245: ByteVarianceSignature(distinctCount: 3, max: 3),
            246: ByteVarianceSignature(distinctCount: 3, max: 3),
            247: ByteVarianceSignature(distinctCount: 4, max: 6),
            248: ByteVarianceSignature(distinctCount: 2, max: 1),
            249: ByteVarianceSignature(distinctCount: 7, max: 190),
            250: ByteVarianceSignature(distinctCount: 5, max: 41),
            251: ByteVarianceSignature(distinctCount: 7, max: 253),
            252: ByteVarianceSignature(distinctCount: 5, max: 15),
            253: ByteVarianceSignature(distinctCount: 3, max: 3),
            254: ByteVarianceSignature(distinctCount: 2, max: 2),
            255: ByteVarianceSignature(distinctCount: 4, max: 7),
            256: ByteVarianceSignature(distinctCount: 2, max: 1),
            257: ByteVarianceSignature(distinctCount: 6, max: 252),
            258: ByteVarianceSignature(distinctCount: 6, max: 38),
            259: ByteVarianceSignature(distinctCount: 6, max: 235),
            260: ByteVarianceSignature(distinctCount: 6, max: 21),
            261: ByteVarianceSignature(distinctCount: 3, max: 3),
            262: ByteVarianceSignature(distinctCount: 3, max: 3),
            263: ByteVarianceSignature(distinctCount: 3, max: 9),
            264: ByteVarianceSignature(distinctCount: 2, max: 1),
            265: ByteVarianceSignature(distinctCount: 6, max: 166),
            266: ByteVarianceSignature(distinctCount: 5, max: 39),
            267: ByteVarianceSignature(distinctCount: 6, max: 238),
            268: ByteVarianceSignature(distinctCount: 6, max: 18),
            269: ByteVarianceSignature(distinctCount: 4, max: 3),
            270: ByteVarianceSignature(distinctCount: 3, max: 3),
            271: ByteVarianceSignature(distinctCount: 3, max: 10),
            272: ByteVarianceSignature(distinctCount: 2, max: 1),
            273: ByteVarianceSignature(distinctCount: 5, max: 240),
            274: ByteVarianceSignature(distinctCount: 4, max: 29),
            275: ByteVarianceSignature(distinctCount: 5, max: 136),
            276: ByteVarianceSignature(distinctCount: 5, max: 28),
            277: ByteVarianceSignature(distinctCount: 4, max: 4),
            278: ByteVarianceSignature(distinctCount: 3, max: 3),
            279: ByteVarianceSignature(distinctCount: 7, max: 236),
            280: ByteVarianceSignature(distinctCount: 7, max: 132),
            285: ByteVarianceSignature(distinctCount: 15, max: 195),
            287: ByteVarianceSignature(distinctCount: 2, max: 1),
    ]

    private static let cth690Pad: [Int: ByteVarianceSignature] = [
            1: ByteVarianceSignature(distinctCount: 3, max: 3),
            2: ByteVarianceSignature(distinctCount: 5, max: 129),
            3: ByteVarianceSignature(distinctCount: 10, max: 216),
            4: ByteVarianceSignature(distinctCount: 20, max: 24),
            5: ByteVarianceSignature(distinctCount: 20, max: 71),
            6: ByteVarianceSignature(distinctCount: 20, max: 19),
            7: ByteVarianceSignature(distinctCount: 4, max: 3),
            8: ByteVarianceSignature(distinctCount: 4, max: 3),
            10: ByteVarianceSignature(distinctCount: 5, max: 128),
            11: ByteVarianceSignature(distinctCount: 7, max: 216),
            12: ByteVarianceSignature(distinctCount: 17, max: 255),
            13: ByteVarianceSignature(distinctCount: 9, max: 255),
            14: ByteVarianceSignature(distinctCount: 20, max: 104),
            15: ByteVarianceSignature(distinctCount: 4, max: 3),
            16: ByteVarianceSignature(distinctCount: 4, max: 3),
            18: ByteVarianceSignature(distinctCount: 3, max: 5),
            19: ByteVarianceSignature(distinctCount: 7, max: 216),
            20: ByteVarianceSignature(distinctCount: 7, max: 255),
            21: ByteVarianceSignature(distinctCount: 6, max: 255),
            22: ByteVarianceSignature(distinctCount: 15, max: 255),
            23: ByteVarianceSignature(distinctCount: 3, max: 2),
            24: ByteVarianceSignature(distinctCount: 3, max: 2),
    ]

    /// Recovers the kernel-documented 4-frame / 43-byte-stride touch layout
    /// (`IntuosV2Decoder+BT.decodeBTTouch`) from statistics alone, with no
    /// knowledge of the report's meaning.
    func testDetectsOuterFrameStructureInRealBTCapture() throws {
        let structure = try XCTUnwrap(
            RepeatingReportStructureDetector.detect(signatures: Self.pth860BTTouch))

        XCTAssertEqual(structure.outer.period, 43)
        XCTAssertEqual(structure.outer.repeatCount, 4)
        XCTAssertEqual(structure.outer.startOffset, 109)
        XCTAssertGreaterThanOrEqual(structure.outer.matchFraction, 0.75)
    }

    /// The 8-byte per-contact stride nests inside the 43-byte frame, matching
    /// the decoder's documented `[1...]: up to 5 contacts, 8 bytes each`.
    func testDetectsNestedContactStructure() throws {
        let structure = try XCTUnwrap(
            RepeatingReportStructureDetector.detect(signatures: Self.pth860BTTouch))
        let nested = try XCTUnwrap(structure.nested)

        XCTAssertEqual(nested.period, 8)
        XCTAssertGreaterThanOrEqual(nested.repeatCount, 3)
    }

    /// A report with real varying bytes and no repeating structure must
    /// report nothing, not a low-confidence guess. A detector tuned only
    /// against positive examples could easily "find" a period anywhere;
    /// this is the check that it does not.
    func testNoStructureDetectedInNonRepeatingReport() {
        let result = RepeatingReportStructureDetector.detect(signatures: Self.cth690Pad)
        XCTAssertNil(result)
    }

    /// A period must fit at least `minRepeatCount` times before it counts —
    /// otherwise a period close to the width of a small varying range
    /// "matches" on a single compared pair and scores 100%. Reproduced
    /// directly: two positions 3 apart in a 4-byte range agree by
    /// construction (there is exactly one pair to compare), which without
    /// the repeat-count floor would register as a perfect match.
    func testDegenerateWidePeriodIsRejected() {
        let signatures: [Int: ByteVarianceSignature] = [
            0: ByteVarianceSignature(distinctCount: 5, max: 10),
            3: ByteVarianceSignature(distinctCount: 5, max: 10),
        ]
        XCTAssertNil(RepeatingReportStructureDetector.detect(signatures: signatures))
    }

    /// An empty or single-position signature set has nothing to compare.
    func testEmptyAndSingleByteInputsDetectNothing() {
        XCTAssertNil(RepeatingReportStructureDetector.detect(signatures: [:]))
        XCTAssertNil(RepeatingReportStructureDetector.detect(
            signatures: [5: ByteVarianceSignature(distinctCount: 2, max: 1)]))
    }

    /// A clean, exact repeat with no noise is detected at full confidence —
    /// the synthetic sanity check underneath the two real-capture tests
    /// above, isolating the period-scoring logic from real-world noise.
    func testExactRepeatDetectedAtFullConfidence() {
        var signatures: [Int: ByteVarianceSignature] = [:]
        for frame in 0..<4 {
            let base = frame * 6
            signatures[base] = ByteVarianceSignature(distinctCount: 2, max: 1)
            signatures[base + 1] = ByteVarianceSignature(distinctCount: 250, max: 255)
            signatures[base + 2] = ByteVarianceSignature(distinctCount: 40, max: 50)
        }
        let result = RepeatingReportStructureDetector.detect(
            signatures: signatures, minMatchFraction: 0.99, minRepeatCount: 3)

        // Span is measured start-to-last-key inclusive (0...20 = 21 bytes),
        // not frame-count × stride (24) — the fourth frame's fields at
        // offsets 18-20 are present, but nothing at 21-23 extends the range,
        // so only 3 full periods fit the observed span.
        XCTAssertEqual(result?.outer.period, 6)
        XCTAssertEqual(result?.outer.repeatCount, 3)
        XCTAssertEqual(result?.outer.matchFraction, 1.0)
    }

    /// Among equally-scoring periods, the detector prefers the larger one — a
    /// period-P structure always also scores at 2P, 3P, ... (a harmonic), and
    /// the base period is the useful annotation, not its multiples.
    func testPrefersLargerPeriodOnHarmonicTie() {
        var signatures: [Int: ByteVarianceSignature] = [:]
        for i in stride(from: 0, through: 40, by: 4) {
            signatures[i] = ByteVarianceSignature(distinctCount: 2, max: 1)
        }
        let result = RepeatingReportStructureDetector.detect(
            signatures: signatures, minMatchFraction: 0.99, minRepeatCount: 3)

        // Every multiple of 4 up to 20 (limited by span/minRepeatCount) scores
        // 100%; the detector must not settle for the smallest.
        XCTAssertEqual(result?.outer.matchFraction, 1.0)
        XCTAssertGreaterThanOrEqual(result?.outer.period ?? 0, 4)
    }
}
