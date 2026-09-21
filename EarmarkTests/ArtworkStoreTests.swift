import ImageIO
import UIKit
import XCTest
@testable import Earmark

/// Cover views reload only when `Book.artworkID` changes, so a replaced custom cover needs a new id.
final class ArtworkStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ArtworkStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "artwork-\(UUID().uuidString)")
        store = ArtworkStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func image(_ color: UIColor, size: CGFloat = 8) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    func testReplacingACustomCoverChangesItsID() {
        let first = ArtworkStore.customID(for: "src|Austen/Pride|folder", imageData: image(.red))
        let second = ArtworkStore.customID(for: "src|Austen/Pride|folder", imageData: image(.blue))
        XCTAssertNotEqual(first, second, "a new image must get a new id or the old cover stays on screen")
    }

    func testSameImageKeepsItsID() {
        let data = image(.red)
        XCTAssertEqual(ArtworkStore.customID(for: "book", imageData: data), ArtworkStore.customID(for: "book", imageData: data))
    }

    func testIDsArePerBook() {
        // Removing a replaced cover must never delete another book's thumbnail.
        let data = image(.red)
        XCTAssertNotEqual(ArtworkStore.customID(for: "book-a", imageData: data), ArtworkStore.customID(for: "book-b", imageData: data))
        let url = URL(string: "https://example.com/a.jpg")!
        XCTAssertNotEqual(ArtworkStore.customID(for: "book-a", sourceURL: url), ArtworkStore.customID(for: "book-b", sourceURL: url))
    }

    func testOnlineCoverIDFollowsTheURL() {
        // Every device derives the same id for the same choice, and a different pick gets a new one.
        let a = URL(string: "https://example.com/a.jpg")!
        let b = URL(string: "https://example.com/b.jpg")!
        XCTAssertEqual(ArtworkStore.customID(for: "book", sourceURL: a), ArtworkStore.customID(for: "book", sourceURL: a))
        XCTAssertNotEqual(ArtworkStore.customID(for: "book", sourceURL: a), ArtworkStore.customID(for: "book", sourceURL: b))
    }

    func testRemoveDropsTheThumbnailFromDiskAndMemory() {
        let data = image(.red)
        let id = ArtworkStore.customID(for: "book", imageData: data)
        XCTAssertTrue(store.store(imageData: data, id: id))
        XCTAssertNotNil(store.image(for: id))

        store.remove(id: id)

        XCTAssertFalse(store.hasImage(id: id))
        XCTAssertNil(store.image(for: id))
        store.remove(id: id)   // already gone: a no-op, not an error
    }

    func testMoveRefilesTheThumbnail() {
        XCTAssertTrue(store.store(imageData: image(.red), id: "old"))
        XCTAssertTrue(store.move(from: "old", to: "new"))
        XCTAssertFalse(store.hasImage(id: "old"))
        XCTAssertTrue(store.hasImage(id: "new"))
        XCTAssertNil(store.image(for: "old"))
        XCTAssertNotNil(store.image(for: "new"))
    }

    func testCoverJPEGIsDownsizedJPEG() throws {
        let big = image(.green, size: 3000)
        let jpeg = try XCTUnwrap(ArtworkStore.coverJPEG(from: big))
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8, 0xFF]), "a PNG comes out as a JPEG")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 1400)
        XCTAssertNil(ArtworkStore.coverJPEG(from: Data("not an image".utf8)))
    }
}
