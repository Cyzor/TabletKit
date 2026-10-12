// TabletKit — HID decoder layer for drawing tablets
// SPDX-FileCopyrightText: 2026 Jay Petronis (Cyzor)
// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import TabletKit

/// Returns scripted results, one batch per report.
private struct ScriptedDecoder: TabletReportDecoder {
    var batches: [[DecodeResult]]
    var stamps: [[UInt16]] = []

    mutating func decode(
        report: HIDReport, spec: DigitizerSpec, state: inout DecoderState, deviceFamily: DeviceFamily
    ) -> [DecodeResult] {
        state.btTouchFrameStamps = stamps.isEmpty ? [] : stamps.removeFirst()
        return batches.isEmpty ? [] : batches.removeFirst()
    }
}

final class TabletEventTests: XCTestCase {

    private let digitizer = DigitizerSpec(maxX: 1000, maxY: 1000, maxPressure: 1023)

    private func point(inRange: Bool) -> TabletPoint {
        TabletPoint(
            x: 1, y: 2, maxX: 1000, maxY: 1000, pressure: 0, maxPressure: 1023,
            tiltX: 0, tiltY: 0, penButton1: false, penButton2: false, eraser: false,
            inProximity: inRange, hoverDistance: 0)
    }

    private func run(_ decoder: ScriptedDecoder, reports: Int, shape: PadShape? = nil) -> [[TabletEvent]] {
        var d = DeviceDecoder(decoder, digitizer: digitizer, family: .graphire)
        if let shape { d.padShape = shape }
        return (0..<reports).map { _ in HIDReport.withReport([0x02]) { d.events($0) } }
    }

    private let pen = ToolIdentity(serial: 7, toolCode: 0x0802, isEraser: false, isMouse: false)

    func testToolLeaveFollowsTheFirstOutOfRangePoint() {
        let out = run(ScriptedDecoder(batches: [
            [.toolEnter(pen), .pen(point(inRange: true))],
            [.pen(point(inRange: false))],
            [.pen(point(inRange: false))],
        ]), reports: 3)
        guard case .tool(let enter) = out[0][0] else { return XCTFail("\(out[0])") }
        XCTAssertEqual(enter, ToolEvent(identity: pen, phase: .enter))
        XCTAssertEqual(out[1].count, 2)
        guard case .tool(let leave) = out[1][1] else { return XCTFail("\(out[1])") }
        XCTAssertEqual(leave, ToolEvent(identity: pen, phase: .leave))
        XCTAssertEqual(out[2].count, 1, "leave once")
    }

    func testPadUsesNilForNoContactAndListsRingsTheReportUses() {
        var aux = AuxButtons(buttons: [true, false])
        aux.mechanicalMask = 0b01
        aux.touchRingActive = true
        aux.touchRingPosition = 12
        aux.touchRing2ButtonDown = true
        let out = run(ScriptedDecoder(batches: [[.aux(aux)]]), reports: 1)
        guard case .pad(let pad) = out[0][0] else { return XCTFail("\(out[0])") }
        XCTAssertEqual(pad.buttons, [true, false])
        XCTAssertEqual(pad.pressedThisReport, [0])
        XCTAssertEqual(pad.rings, [RingState(position: 12, buttonDown: false),
                                   RingState(position: nil, buttonDown: true)])
        XCTAssertEqual(pad.strips, [])
    }

    func testPadShapeFromTheSpecWithNothingTouched() {
        let out = run(ScriptedDecoder(batches: [[.aux(AuxButtons(buttons: []))]]), reports: 1,
                      shape: PadShape(rings: 1, strips: 2))
        guard case .pad(let pad) = out[0][0] else { return XCTFail() }
        XCTAssertEqual(pad.rings, [RingState(position: nil, buttonDown: false)])
        XCTAssertEqual(pad.strips, [StripState(position: nil), StripState(position: nil)])
    }

    func testTouchFramesCarryTheirStampsInOrder() {
        let c = TouchContact(id: 0, x: 1, y: 1, contactArea: nil)
        let out = run(ScriptedDecoder(
            batches: [[.touch([c]), .pen(point(inRange: false)), .touch([])]],
            stamps: [[100, 200]]), reports: 1)
        let times: [UInt16?] = out[0].compactMap { if case .touch(let f) = $0 { return f.deviceTime } else { return nil } }
        XCTAssertEqual(times, [100, 200])
    }

    func testEverythingElseIsADeviceEvent() {
        let out = run(ScriptedDecoder(batches: [[
            .none, .wheel(index: 1, delta: -2), .battery(percent: 40, charging: true),
            .wireless(.active), .remotePairing([]), .toolCompatibility("no"), .mouseButton(3),
        ]]), reports: 1)[0]
        XCTAssertEqual(out.count, 6, ".none is dropped")
        guard case .dial(1, -2) = out[0] else { return XCTFail("\(out[0])") }
        let kinds: [DeviceEvent.Kind] = out.compactMap { if case .device(let e) = $0 { return e.kind } else { return nil } }
        XCTAssertEqual(kinds, [.battery, .wireless, .remotePairing, .toolSupport, .mouseButtons])
        if case .device(let e) = out[1] { XCTAssertEqual(e.battery, .init(percent: 40, charging: true)) }
        if case .device(let e) = out[5] { XCTAssertEqual(e.mouseButtons, 3) }
    }

    func testResetForgetsTheTool() {
        var d = DeviceDecoder(
            ScriptedDecoder(batches: [[.toolEnter(pen)], [.pen(point(inRange: false))]]),
            digitizer: digitizer, family: .graphire)
        _ = HIDReport.withReport([0x02]) { d.events($0) }
        d.reset()
        let out = HIDReport.withReport([0x02]) { d.events($0) }
        XCTAssertEqual(out.count, 1, "no leave for a tool the reset forgot")
    }

    func testMovedConstantsKeepTheirValues() {
        XCTAssertEqual(TouchFrame.deviceTimeMsPerCount, 0.1)
        XCTAssertEqual(TouchFrame.deviceTimeCountsPerBluetoothFrame, 100)
        XCTAssertEqual(DecoderState.btTouchMsPerCount, TouchFrame.deviceTimeMsPerCount)
        XCTAssertEqual(DecoderState.btTouchCountsPerFrame, TouchFrame.deviceTimeCountsPerBluetoothFrame)
        XCTAssertEqual(ReportFormat.xencelabs.tiltMaxDegrees, 60)
        XCTAssertEqual(XencelabsDecoder.tiltMaxDegrees, 60)
        XCTAssertNil(ReportFormat.intuosV2.tiltMaxDegrees)
    }
}
