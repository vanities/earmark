import SwiftUI
import XCTest
@testable import Earmark

/// Measure the real player content in the space available below navigation and safe areas.
@MainActor
final class PlayerLayoutTests: XCTestCase {
    func testLandscapePhoneHasNoScrollableShell() async throws {
        try await checkLayout(size: CGSize(width: 756, height: 354), name: "landscape-phone") { scrolls in
            XCTAssertTrue(scrolls.isEmpty, "Landscape artwork and playback controls must stay fixed")
        }
    }

    func testLandscapeIPadOnlyScrollsChapters() async throws {
        try await checkLayout(size: CGSize(width: 1376, height: 984), name: "landscape-ipad") { scrolls in
            XCTAssertEqual(scrolls.count, 1)
            let chapters = try XCTUnwrap(scrolls.first)
            XCTAssertLessThanOrEqual(chapters.bounds.width, 460)
            XCTAssertLessThanOrEqual(chapters.bounds.height, 240)
            XCTAssertFalse(chapters.alwaysBounceVertical)
        }
    }

    func testShortLandscapePhoneHasNoScrollableShell() async throws {
        try await checkLayout(size: CGSize(width: 668, height: 278), name: "short-landscape-phone") { scrolls in
            XCTAssertTrue(scrolls.isEmpty)
        }
    }

    func testShortTabletWindowScrollsChaptersIndependently() async throws {
        try await checkLayout(size: CGSize(width: 800, height: 540), name: "short-tablet-window") { scrolls in
            XCTAssertEqual(scrolls.count, 1)
            let chapters = try XCTUnwrap(scrolls.first)
            XCTAssertLessThanOrEqual(chapters.bounds.width, 460)
            XCTAssertLessThanOrEqual(chapters.bounds.height, 240)
            XCTAssertGreaterThan(chapters.contentSize.height, chapters.bounds.height)
        }
    }

    func testPortraitIPadMiniOnlyScrollsChapters() async throws {
        try await checkLayout(size: CGSize(width: 744, height: 1068), name: "portrait-ipad-mini") { scrolls in
            XCTAssertEqual(scrolls.count, 1)
            let chapters = try XCTUnwrap(scrolls.first)
            XCTAssertLessThanOrEqual(chapters.bounds.width, 460)
            XCTAssertLessThanOrEqual(chapters.bounds.height, 240)
        }
    }

    func testAccessibilityTextScrollsOnlyWithinPanes() async throws {
        try await checkLayout(size: CGSize(width: 668, height: 278), name: "accessibility-landscape-phone",
                              textSize: .accessibility3) { scrolls in
            XCTAssertFalse(scrolls.isEmpty, "Large text must remain reachable")
            for scroll in scrolls {
                XCTAssertLessThan(scroll.bounds.width, 668, "Scrolling must not include the whole player")
                XCTAssertTrue(scroll.isScrollEnabled)
            }
        }
    }

    func testPortraitPhoneDoesNotBounceWhenContentFits() async throws {
        try await checkLayout(size: CGSize(width: 393, height: 760), name: "portrait-phone") { scrolls in
            let scroll = try XCTUnwrap(scrolls.first)
            XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
            XCTAssertFalse(scroll.alwaysBounceVertical)
        }
    }

    private func checkLayout(size: CGSize, name: String, textSize: DynamicTypeSize = .large,
                             check: ([UIScrollView]) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "PlayerLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.ambientPlayerBackground = false
        let library = LibraryModel(store: LibraryStore(directory: directory), settings: settings)
        let source = UUID()
        // No audio is played; use an empty track list so loading performs no filesystem/network IO.
        let book = Book(id: "layout-test", sourceID: source, relativePath: "test", kind: .folder,
                        title: "Pride and Prejudice", author: "Jane Austen", tracks: [],
                        chapters: (0..<3).map { Chapter(title: "Chapter \($0 + 1)", trackIndex: 0,
                                                      start: Double($0) * 60, duration: 60) },
                        addedAt: .now, totalBytes: 0)
        let player = PlayerEngine(library: library, settings: settings)
        player.load(book, autoplay: false)
        defer { player.unload() }
        let controller = UIHostingController(rootView: PlayerContentView(book: book, sheet: .constant(nil))
            .environment(player).environment(library).environment(settings)
            .environment(\.dynamicTypeSize, textSize)
            .frame(width: size.width, height: size.height))
        controller.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.didMove(toParent: container)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        for _ in 0..<10 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let scrolls = descendants(of: controller.view).compactMap { $0 as? UIScrollView }
        for scroll in scrolls {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            print("PLAYER_LAYOUT \(name): viewport=\(scroll.bounds.size) content=\(scroll.contentSize) bounce=\(scroll.alwaysBounceVertical)")
        }
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try check(scrolls)
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
