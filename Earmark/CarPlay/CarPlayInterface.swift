import CarPlay
import Foundation
import UIKit
import os

/// Builds the CarPlay UI: a "Continue" tab of in-progress books, a "Library" tab grouped
/// by author, and the shared Now Playing template with speed and chapter buttons.
@MainActor
final class CarPlayInterface: NSObject, CPNowPlayingTemplateObserver {
    private let interfaceController: CPInterfaceController
    private let environment: AppEnvironment
    private var continueTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var observing = false

    init(interfaceController: CPInterfaceController, environment: AppEnvironment) {
        self.interfaceController = interfaceController
        self.environment = environment
        super.init()
    }

    func start() {
        let continueTemplate = CPListTemplate(title: "Continue", sections: [])
        continueTemplate.tabTitle = "Continue"
        continueTemplate.tabImage = UIImage(systemName: "play.circle.fill")
        continueTemplate.emptyViewTitleVariants = ["Nothing in progress"]
        continueTemplate.emptyViewSubtitleVariants = ["Pick a book from Library to start listening."]

        let libraryTemplate = CPListTemplate(title: "Library", sections: [])
        libraryTemplate.tabTitle = "Library"
        libraryTemplate.tabImage = UIImage(systemName: "books.vertical.fill")
        libraryTemplate.emptyViewTitleVariants = ["No books yet"]
        libraryTemplate.emptyViewSubtitleVariants = ["Add a folder in Earmark on your iPhone."]

        self.continueTemplate = continueTemplate
        self.libraryTemplate = libraryTemplate
        refreshTemplates()

        let tabBar = CPTabBarTemplate(templates: [continueTemplate, libraryTemplate])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
        configureNowPlaying()
        observeChanges()
    }

    func stop() {
        observing = false
        CPNowPlayingTemplate.shared.remove(self)
    }

    // MARK: - Lists

    private func refreshTemplates() {
        let library = environment.library
        let sw = Stopwatch()

        let inProgress = Array(library.inProgressBooks.prefix(CPListTemplate.maximumItemCount))
        continueTemplate?.updateSections(inProgress.isEmpty ? [] : [CPListSection(items: inProgress.map(listItem))])

        var remaining = CPListTemplate.maximumItemCount
        var sections: [CPListSection] = []
        for group in library.groups(.author, from: library.visibleBooks) {
            guard remaining > 0, sections.count < CPListTemplate.maximumSectionCount else { break }
            let books = Array(group.books.prefix(remaining))
            remaining -= books.count
            sections.append(CPListSection(items: books.map(listItem), header: group.title, sectionIndexTitle: String(group.title.prefix(1)).uppercased()))
        }
        libraryTemplate?.updateSections(sections)
        Logger.carplay.debug("[carplay] refreshed continue=\(inProgress.count) sections=\(sections.count) in \(sw.ms, format: .fixed(precision: 0))ms")
    }

    private func listItem(for book: Book) -> CPListItem {
        let progress = environment.library.progress(for: book.id)
        var detail = book.displayAuthor
        if progress.isFinished {
            detail += " · Finished"
        } else if progress.hasStarted {
            detail += " · \(progress.remaining(in: book).shortDurationString) left"
        } else {
            detail += " · \(book.totalDuration.shortDurationString)"
        }
        let image = ArtworkStore.shared.image(for: book.artworkID) ?? UIImage(systemName: "book.closed.fill")
        let item = CPListItem(text: book.title, detailText: detail, image: image)
        item.playingIndicatorLocation = .trailing
        item.isPlaying = environment.player.book?.id == book.id && environment.player.isPlaying
        item.handler = { [weak self] _, completion in
            MainActor.assumeIsolated { self?.play(book) }
            completion()
        }
        return item
    }

    private func play(_ book: Book) {
        Logger.carplay.info("[carplay] play \(book.title, privacy: .public)")
        environment.player.load(book, autoplay: true)
        if interfaceController.topTemplate !== CPNowPlayingTemplate.shared {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    // MARK: - Now Playing

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.add(self)
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Chapters"
        template.isAlbumArtistButtonEnabled = false

        // No sleep timer here: nobody's going to sleep in the car. It stays on the phone's player.
        let rateButton = CPNowPlayingPlaybackRateButton { [weak self] _ in
            MainActor.assumeIsolated { self?.environment.player.cycleSpeed() }
        }
        template.updateNowPlayingButtons([rateButton])
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { pushChapters() }
    }

    private func pushChapters() {
        guard let book = environment.player.book else { return }
        let currentIndex = environment.player.currentChapterIndex
        let items = book.chapters.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, chapter -> CPListItem in
            let item = CPListItem(text: chapter.title, detailText: chapter.duration.shortDurationString)
            item.playingIndicatorLocation = .trailing
            item.isPlaying = index == currentIndex
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.environment.player.jump(to: chapter)
                    if !self.environment.player.isPlaying { self.environment.player.play() }
                    self.interfaceController.popTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Chapters", sections: [CPListSection(items: Array(items))])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Observation

    private func observeChanges() {
        observing = true
        withObservationTracking {
            _ = environment.library.books
            _ = environment.library.progress
            _ = environment.library.hiddenBookIDs
            _ = environment.player.book?.id
            _ = environment.player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.observing else { return }
                self.refreshTemplates()
                self.observeChanges()
            }
        }
    }
}
