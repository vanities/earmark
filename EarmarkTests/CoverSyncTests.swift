import XCTest
@testable import Earmark

/// Cover choices sync by `Book.syncKey`, newest wins. The plan turns the merged choices into the few
/// things one device must do: fetch a cover chosen elsewhere, adopt one an older build stored, or drop one.
final class CoverSyncTests: XCTestCase {
    private let source = UUID()
    private let a = URL(string: "https://covers.example/a.jpg")!
    private let b = URL(string: "https://covers.example/b.jpg")!

    private func book(_ path: String, group: String = "", source: UUID? = nil) -> Book {
        let sourceID = source ?? self.source
        return Book(id: Book.makeID(sourceID: sourceID, relativePath: path, groupKey: group), sourceID: sourceID,
                    relativePath: path, kind: .folder, title: path, tracks: [], chapters: [], addedAt: .now, totalBytes: 0)
    }

    private func online(_ url: URL, at seconds: TimeInterval) -> CoverChoice {
        CoverChoice(kind: .online, url: url.absoluteString, chosenAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: merge

    func testNewerChoiceWinsInEitherDirection() {
        let local = ["austen/pride": online(a, at: 100)]
        let cloud = ["austen/pride": online(b, at: 200)]
        XCTAssertEqual(CoverSync.merged(local: local, cloud: cloud)["austen/pride"]?.url, b.absoluteString, "a replacement from another device lands")
        XCTAssertEqual(CoverSync.merged(local: cloud, cloud: local)["austen/pride"]?.url, b.absoluteString, "an older cloud copy doesn't undo it")
    }

    func testTieKeepsLocal() {
        let local = ["k": online(a, at: 100)]
        XCTAssertEqual(CoverSync.merged(local: local, cloud: ["k": online(b, at: 100)]), local)
    }

    func testCloudOnlyChoicesAreAdded() {
        let merged = CoverSync.merged(local: ["mine": online(a, at: 1)], cloud: ["theirs": online(b, at: 1)])
        XCTAssertEqual(Set(merged.keys), ["mine", "theirs"])
    }

    func testGoingBackToTheOriginalSyncsLikeAnyChoice() {
        let back = CoverChoice(kind: .original, chosenAt: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(CoverSync.merged(local: ["k": online(a, at: 100)], cloud: ["k": back])["k"]?.kind, .original)
    }

    func testLegacyURLsLoseToAnyRealChoice() {
        let legacy = CoverSync.legacyChoices(["k": a.absoluteString])
        XCTAssertEqual(legacy["k"]?.kind, .online)
        XCTAssertEqual(legacy["k"]?.chosenAt, .distantPast)
        XCTAssertEqual(CoverSync.merged(local: legacy, cloud: ["k": online(b, at: 1)])["k"]?.url, b.absoluteString)
    }

    // MARK: plan

    func testDownloadsACoverChosenElsewhere() {
        let pride = book("Austen/Pride")
        let plan = CoverSync.plan(books: [pride], choices: [pride.syncKey: online(a, at: 100)], customArtwork: [:]) { _ in false }
        XCTAssertEqual(plan[pride.id], .download(a, artworkID: ArtworkStore.customID(for: pride.id, sourceURL: a)))
    }

    func testNothingToDoWhenTheChosenCoverIsHere() {
        let pride = book("Austen/Pride")
        let id = ArtworkStore.customID(for: pride.id, sourceURL: a)
        let plan = CoverSync.plan(books: [pride], choices: [pride.syncKey: online(a, at: 100)], customArtwork: [pride.id: id]) { $0 == id }
        XCTAssertTrue(plan.isEmpty)
    }

    func testRefetchesWhenTheArtCacheLostIt() {
        // "Rebuild Cover Art" or an iOS cache purge: the choice is remembered but the thumbnail is gone.
        let pride = book("Austen/Pride")
        let id = ArtworkStore.customID(for: pride.id, sourceURL: a)
        let plan = CoverSync.plan(books: [pride], choices: [pride.syncKey: online(a, at: 100)], customArtwork: [pride.id: id]) { _ in false }
        XCTAssertEqual(plan[pride.id], .download(a, artworkID: id))
    }

    func testReplacementFromAnotherDeviceIsDownloadedOverTheOldCover() {
        let pride = book("Austen/Pride")
        let old = ArtworkStore.customID(for: pride.id, sourceURL: a)
        let plan = CoverSync.plan(books: [pride], choices: [pride.syncKey: online(b, at: 200)], customArtwork: [pride.id: old]) { $0 == old }
        XCTAssertEqual(plan[pride.id], .download(b, artworkID: ArtworkStore.customID(for: pride.id, sourceURL: b)))
    }

    func testAdoptsACoverAnOlderBuildStoredInsteadOfDownloadingIt() {
        let pride = book("Austen/Pride")
        let legacy = CoverSync.legacyChoices([pride.syncKey: a.absoluteString])
        let plan = CoverSync.plan(books: [pride], choices: legacy, customArtwork: [pride.id: "legacy-id"]) { $0 == "legacy-id" }
        XCTAssertEqual(plan[pride.id], .adopt(from: "legacy-id", to: ArtworkStore.customID(for: pride.id, sourceURL: a)))
    }

    func testOriginalDropsACustomCoverOnlyWhereThereIsOne() {
        let pride = book("Austen/Pride"), emma = book("Austen/Emma")
        let back = CoverChoice(kind: .original)
        let plan = CoverSync.plan(books: [pride, emma], choices: [pride.syncKey: back, emma.syncKey: back],
                                  customArtwork: [pride.id: "x"]) { _ in true }
        XCTAssertEqual(plan, [pride.id: .removeCustom])
    }

    func testDeviceOnlyChoiceLeavesOtherDevicesAlone() {
        let pride = book("Austen/Pride")
        let plan = CoverSync.plan(books: [pride], choices: [pride.syncKey: CoverChoice(kind: .deviceOnly)],
                                  customArtwork: [pride.id: "their-old-cover"]) { _ in true }
        XCTAssertTrue(plan.isEmpty)
    }

    func testNASBookAndItsDownloadedCopyBothGetTheCover() {
        let remote = book("Austen/Pride", source: UUID()), local = book("Austen/Pride", source: UUID())
        XCTAssertEqual(remote.syncKey, local.syncKey)
        let plan = CoverSync.plan(books: [remote, local], choices: [remote.syncKey: online(a, at: 1)], customArtwork: [:]) { _ in false }
        XCTAssertEqual(plan.count, 2)
    }

    func testBooksSplitFromOneFolderKeepSeparateChoices() {
        // One folder holding two album-tagged books: same path, different group keys.
        let first = book("Box Set", group: "book one"), second = book("Box Set", group: "book two")
        XCTAssertNotEqual(first.syncKey, second.syncKey)
        let plan = CoverSync.plan(books: [first, second], choices: [first.syncKey: online(a, at: 1)], customArtwork: [:]) { _ in false }
        XCTAssertEqual(Array(plan.keys), [first.id], "a cover picked for one book must not land on its sibling")
    }

    func testOrdinaryFolderKeyIsUnchanged() {
        // Existing cloud progress and covers are keyed this way — it must not move.
        XCTAssertEqual(book("Austen/Pride And Prejudice").syncKey, "austen/pride and prejudice")
    }

    // MARK: decoding

    func testChoiceFromANewerBuildDecodesAsHarmless() throws {
        let json = #"{"kind":"somethingNew","chosenAt":"2026-09-21T12:00:00Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let choice = try decoder.decode(CoverChoice.self, from: Data(json.utf8))
        XCTAssertEqual(choice.kind, .deviceOnly, "an unknown kind changes nothing on this device")
        XCTAssertEqual(try decoder.decode(CoverChoice.self, from: Data("{}".utf8)).chosenAt, .distantPast)
    }

    func testChoiceTimesAreWholeSecondsSoTheyRoundTrip() throws {
        let choice = CoverChoice(kind: .online, url: a.absoluteString)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CoverChoice.self, from: encoder.encode(choice)), choice)
    }
}
