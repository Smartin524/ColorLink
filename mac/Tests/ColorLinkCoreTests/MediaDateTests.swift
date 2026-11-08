import XCTest
@testable import ColorLinkCore

final class MediaDateTests: XCTestCase {
    private func item(_ dates: String) throws -> MediaItem {
        let json = """
        {"id":1,"kind":"image","name":"photo.jpg","mime":"image/jpeg","size":42,\(dates)}
        """
        return try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
    }

    func testMigrationUsesCaptureDateRatherThanImportDate() throws {
        let photo = try item(#""taken":1600000000,"modified":1700000000,"added":1800000000"#)
        XCTAssertEqual(photo.capturedDate.timeIntervalSince1970, 1600000000)
        XCTAssertEqual(photo.added, 1800000000)
    }

    func testLegacyMetadataUsesOriginalModificationDate() throws {
        let photo = try item(#""modified":1600000000,"added":1800000000"#)
        XCTAssertNil(photo.taken)
        XCTAssertEqual(photo.capturedDate.timeIntervalSince1970, 1600000000)
    }

    func testMissingOrZeroDatesFallBackSafely() throws {
        XCTAssertEqual(try item(#""taken":0,"modified":0,"added":1800000000"#).capturedDate.timeIntervalSince1970, 1800000000)
        XCTAssertEqual(try item(#""modified":0"#).capturedDate.timeIntervalSince1970, 0)
    }

    func testProtocolMetadataVersionDecodesWithoutBreakingOldServer() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(MediaPage.self, from: Data(#"{"total":0,"items":[]}"#.utf8)).metadataVersion)
        XCTAssertEqual(try decoder.decode(MediaPage.self, from: Data(#"{"total":0,"items":[],"metadataVersion":1}"#.utf8)).metadataVersion, 1)
    }
}
