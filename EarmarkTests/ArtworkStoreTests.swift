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

    private func image(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    func testReplacingACustomCoverChangesItsID() {
        let first = store.customID(for: "src|Austen/Pride|folder", imageData: image(.red))
        let second = store.customID(for: "src|Austen/Pride|folder", imageData: image(.blue))
        XCTAssertNotEqual(first, second, "a new image must get a new id or the old cover stays on screen")
    }

    func testSameImageKeepsItsID() {
        let data = image(.red)
        XCTAssertEqual(store.customID(for: "book", imageData: data), store.customID(for: "book", imageData: data))
    }

    func testIDsArePerBook() {
        // Removing a replaced cover must never delete another book's thumbnail.
        let data = image(.red)
        XCTAssertNotEqual(store.customID(for: "book-a", imageData: data), store.customID(for: "book-b", imageData: data))
    }

    func testRemoveDropsTheThumbnailFromDiskAndMemory() {
        let data = image(.red)
        let id = store.customID(for: "book", imageData: data)
        XCTAssertTrue(store.store(imageData: data, id: id))
        XCTAssertNotNil(store.image(for: id))

        store.remove(id: id)

        XCTAssertFalse(store.hasImage(id: id))
        XCTAssertNil(store.image(for: id))
    }
}
