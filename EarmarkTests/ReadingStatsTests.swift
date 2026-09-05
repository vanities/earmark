import XCTest
@testable import Earmark

final class ReadingStatsTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testCountsPerYearAndTotals() {
        let now = date(2026, 3, 1)
        let items: [ReadingStatsBuilder.Item] = [
            .init(finishedAt: date(2024), hours: 10, rating: 5, author: "Erikson"),
            .init(finishedAt: date(2025), hours: 8, rating: 4, author: "Erikson"),
            .init(finishedAt: date(2025), hours: 12, rating: nil, author: "Hobb"),
            .init(finishedAt: date(2026, 1), hours: 6, rating: 3, author: "Hobb"),
        ]
        let s = ReadingStatsBuilder.build(items, now: now, calendar: cal)
        XCTAssertEqual(s.totalBooks, 4)
        XCTAssertEqual(s.totalHours, 36, accuracy: 0.001)
        XCTAssertEqual(s.thisYear, 1, "one book finished in 2026")
        XCTAssertEqual(s.years.map(\.year), [2026, 2025, 2024], "descending")
        XCTAssertEqual(s.years.first { $0.year == 2025 }?.count, 2)
        XCTAssertEqual(s.bestYear?.year, 2025)
    }

    func testAverageRatingOnlyOverRated() {
        let items: [ReadingStatsBuilder.Item] = [
            .init(finishedAt: date(2025), hours: 1, rating: 5, author: nil),
            .init(finishedAt: date(2025), hours: 1, rating: 3, author: nil),
            .init(finishedAt: date(2025), hours: 1, rating: nil, author: nil),
        ]
        let s = ReadingStatsBuilder.build(items, now: date(2025), calendar: cal)
        XCTAssertEqual(s.ratedCount, 2)
        XCTAssertEqual(s.averageRating ?? 0, 4, accuracy: 0.001)
    }

    func testTopAuthorsRanked() {
        let items: [ReadingStatsBuilder.Item] = [
            .init(finishedAt: date(2025), hours: 1, rating: nil, author: "Hobb"),
            .init(finishedAt: date(2025), hours: 1, rating: nil, author: "Hobb"),
            .init(finishedAt: date(2025), hours: 1, rating: nil, author: "Erikson"),
        ]
        let s = ReadingStatsBuilder.build(items, now: date(2025), calendar: cal)
        XCTAssertEqual(s.topAuthors.first?.author, "Hobb")
        XCTAssertEqual(s.topAuthors.first?.count, 2)
    }

    func testEmptyIsEmpty() {
        XCTAssertTrue(ReadingStatsBuilder.build([]).isEmpty)
    }
}
