import XCTest
@testable import Earmark

final class QuickTagReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> (Data, URL) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp3"))
        return (try Data(contentsOf: url), url)
    }

    func testReadsID3TagsAndDurationFromTheHead() async throws {
        let (data, url) = try fixture("raven")
        let head = data.prefix(QuickTagReader.initialWindow)
        let quick = try XCTUnwrap(QuickTagReader.parseMP3(head: Data(head), fileSize: Int64(data.count)))
        XCTAssertEqual(quick.title, "The Raven")
        XCTAssertEqual(quick.artist, "Edgar Allan Poe")
        XCTAssertEqual(quick.album, "The Raven")
        XCTAssertEqual(quick.trackNumber, 1)
        let reference = try await MetadataReader().read(url: url)
        XCTAssertEqual(quick.duration, reference.duration, accuracy: 0.5, "quick duration should agree with AVFoundation")
        XCTAssertGreaterThan(quick.duration, 5)
    }

    func testTrackAndTotalAndRequiredLength() throws {
        let (data, _) = try fixture("chapter1")
        let tagSize = try XCTUnwrap(QuickTagReader.id3TagSize(data))
        XCTAssertGreaterThan(tagSize, 10)
        XCTAssertEqual(QuickTagReader.requiredLength(data), tagSize + QuickTagReader.frameWindow)
        let quick = try XCTUnwrap(QuickTagReader.parseMP3(head: data, fileSize: Int64(data.count)))
        XCTAssertEqual(quick.title, "Chapter 1")
        XCTAssertEqual(quick.artist, "Jane Austen")
        XCTAssertEqual(quick.trackNumber, 1)
        XCTAssertEqual(quick.trackTotal, 4)
    }

    func testSniffsContainerFromHeader() throws {
        let (mp3, _) = try fixture("raven")
        XCTAssertEqual(QuickTagReader.container(of: mp3), "mp3", "ID3-tagged MP3")
        var frame = Data([0xFF, 0xFB, 0x90, 0x00]); frame.append(Data(count: 16))
        XCTAssertEqual(QuickTagReader.container(of: frame), "mp3", "bare MPEG frame sync")
        var mp4 = Data([0x00, 0x00, 0x00, 0x18]); mp4.append(Data("ftypM4A ".utf8)); mp4.append(Data(count: 8))
        XCTAssertEqual(QuickTagReader.container(of: mp4), "mp4")
        XCTAssertEqual(QuickTagReader.container(of: Data("fLaC0000000000".utf8)), "flac")
        XCTAssertEqual(QuickTagReader.container(of: Data("RIFF....WAVEfmt ".utf8)), "wav")
        XCTAssertNil(QuickTagReader.container(of: Data("hello world!".utf8)))
    }

    func testRejectsNonMP3Data() {
        XCTAssertNil(QuickTagReader.parseMP3(head: Data(repeating: 0x41, count: 4096), fileSize: 4096))
        XCTAssertNil(QuickTagReader.id3TagSize(Data("hello".utf8)))
    }

    func testDecodesTextEncodings() {
        XCTAssertEqual(QuickTagReader.text([0x00] + Array("Latin".utf8)), "Latin")
        XCTAssertEqual(QuickTagReader.text([0x03] + Array("Ünïcode".utf8)), "Ünïcode")
        var utf16: [UInt8] = [0x01, 0xFF, 0xFE]
        for scalar in "Bom".utf16 { utf16 += [UInt8(scalar & 0xFF), UInt8(scalar >> 8)] }
        XCTAssertEqual(QuickTagReader.text(utf16), "Bom")
        XCTAssertEqual(QuickTagReader.text([0x00] + Array("First\0Second".utf8)), "First")
    }
}
