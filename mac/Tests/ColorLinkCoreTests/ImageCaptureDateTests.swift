import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ColorLinkCore

final class ImageCaptureDateTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 8 * 3600)!

    func testDateParsingHonorsOffsetAndRejectsInvalidDates() {
        let expected: Int64 = 1555858432 // 2019-04-21 22:53:52 +08:00
        XCTAssertEqual(ImageCaptureDate.parse("2019:04:21 22:53:52", offset: nil, timeZone: zone), expected)
        XCTAssertEqual(ImageCaptureDate.parse("2019:04:21 22:53:52", offset: "+08:00", timeZone: .gmt), expected)
        XCTAssertNil(ImageCaptureDate.parse("0000:00:00 00:00:00", offset: nil, timeZone: zone))
        XCTAssertNil(ImageCaptureDate.parse("2019:02:31 12:00:00", offset: nil, timeZone: zone))
        XCTAssertNil(ImageCaptureDate.read(Data("not an image".utf8)))
    }

    func testReadsOriginalDateFromJPEGWithoutDecodingPixels() throws {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2019:04:21 22:53:52"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(ImageCaptureDate.read(data as Data, timeZone: zone), 1555858432)
    }

    func testRecoveredDateLeavesServerSnapshotAndThumbnailIdentityUnchanged() throws {
        let raw = Data(#"{"id":78129,"kind":"image","name":"old.jpg","mime":"image/jpeg","size":242072,"modified":1793970801,"added":1793970799}"#.utf8)
        let original = try JSONDecoder().decode(MediaItem.self, from: raw)
        let recovered = original.recoveringCaptureDate(1555858432)
        XCTAssertNil(original.taken)
        XCTAssertEqual(recovered.capturedDate.timeIntervalSince1970, 1555858432)
        XCTAssertEqual(recovered.cacheKey, original.cacheKey)
        XCTAssertEqual(recovered.added, original.added)
        XCTAssertEqual(recovered.recoveringCaptureDate(123).taken, recovered.taken)
        XCTAssertEqual(original.recoveringCaptureDate(0), original)
    }
}
