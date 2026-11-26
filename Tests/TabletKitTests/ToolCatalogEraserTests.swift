import XCTest
@testable import TabletKit

final class ToolCatalogEraserTests: XCTestCase {
    /// An eraser end the catalog doesn't list is still an eraser, not its tip.
    func testUnlistedEraserIsNotItsTip() throws {
        let listed = Set(ToolCatalog.allUniqueTools.map(\.toolCode))
        let tip = try XCTUnwrap(ToolCatalog.allUniqueTools.first {
            $0.toolType == .stylus && $0.toolCode & 0x000F != 0x0006
                && $0.toolCode & 0x0008 == 0 && !listed.contains($0.toolCode | 0x0008)
        })
        let eraser = tip.toolCode | 0x0008
        XCTAssertTrue(ToolCatalog.isEraser(toolCode: eraser))
        XCTAssertEqual(ToolCatalog.toolType(forToolCode: eraser), .eraser)
        XCTAssertNotEqual(ToolCatalog.name(forToolCode: eraser), tip.name)
        // Capabilities still come from the tip.
        XCTAssertEqual(ToolCatalog.spec(forToolCodeRaw: eraser)?.toolCode, tip.toolCode)
    }
}
