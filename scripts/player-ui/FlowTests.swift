import XCTest

/// Native journeys against generated narration in a dedicated simulator.
@MainActor
final class PlayerFlowTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.vanities.earmarkplayerqa")

    private func prepareWindow() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["QA_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
        // Boolean launch arguments are strings in NSArgumentDomain, so they do not
        // override this app's typed Bool preferences. Configure those through real UI.
        app.launchArguments = ["-library.grouping", "all"]
        app.launch()
        let landscape = ProcessInfo.processInfo.environment["QA_ORIENTATION"] == "landscape"
        let geometry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let frame = self.app.windows.firstMatch.frame
                return frame.width > 0 && (landscape ? frame.width > frame.height : frame.height > frame.width)
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [geometry], timeout: 10), .completed)
        print("PLAYER_UI_WINDOW: \(app.windows.firstMatch.frame)")
        // The production default can restore a recent player across test launches.
        if app.buttons["Playback speed"].waitForExistence(timeout: 2), app.buttons["Close"].isHittable {
            app.buttons["Close"].tap()
        }
    }

    private func tap(_ label: String) {
        let candidates = app.buttons.matching(identifier: label)
        XCTAssertTrue(candidates.firstMatch.exists || candidates.firstMatch.waitForExistence(timeout: 10), "Missing \(label): \(app.debugDescription)")
        let button = candidates.allElementsBoundByIndex.first { $0.isHittable } ?? candidates.firstMatch
        XCTAssertTrue(button.isHittable, "Unreachable \(label): \(app.debugDescription)")
        button.tap()
    }

    private func menu(_ label: String) {
        tap("More")
        if !app.buttons[label].firstMatch.exists {
            let nested = app.collectionViews.buttons["More"].firstMatch
            if nested.exists { nested.tap() }
        }
        tap(label)
    }

    private func pause() {
        let buttons = app.buttons.matching(identifier: "Pause")
        _ = buttons.firstMatch.waitForExistence(timeout: 2)
        if let button = buttons.allElementsBoundByIndex.first(where: { $0.isHittable }) { button.tap() }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                self.app.buttons.matching(identifier: "Play").allElementsBoundByIndex.contains { $0.isHittable }
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed, app.debugDescription)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func chooseSleepOff() {
        XCTAssertTrue(app.navigationBars["Sleep Timer"].waitForExistence(timeout: 5), app.debugDescription)
        let off = app.buttons["Off"].firstMatch
        for _ in 0..<5 where !off.isHittable {
            let list = app.collectionViews.allElementsBoundByIndex.last
            XCTAssertNotNil(list, app.debugDescription)
            list?.swipeUp()
        }
        tap("Off")
    }

    private func chooseChapter(_ title: String) {
        tap("PlayerChapterButton")
        XCTAssertTrue(app.navigationBars["Chapters"].waitForExistence(timeout: 5), app.debugDescription)
        let chapters = app.cells.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
        XCTAssertTrue(chapters.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let chapter = chapters.allElementsBoundByIndex.first { $0.isHittable } ?? chapters.firstMatch
        XCTAssertTrue(chapter.isHittable, app.debugDescription)
        chapter.tap()
    }

    private func openPausedFrankenstein() {
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Frankenstein")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        tap("BookDetailPlayButton")
        if !app.buttons["Playback speed"].waitForExistence(timeout: 2) {
            let mini = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing:")).firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 5), app.debugDescription)
            mini.tap()
        }
        pause()
        chooseChapter("Letter 1")
        pause()
        XCTAssertEqual(app.buttons["PlayerChapterButton"].label, "Letter 1")
        tap("Playback speed")
        tap("1×")
        tap("Done")
        tap("Sleep timer")
        chooseSleepOff()
        XCTAssertEqual(app.staticTexts["PlayerBookTitle"].label, "Frankenstein")
    }

    private func typeNoteDraft(_ note: String) {
        let alert = app.alerts["Bookmark Note"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        let field = alert.textFields.firstMatch
        let previous = field.value as? String ?? ""
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + note)
    }

    private func firstLetterBookmark() -> XCUIElement {
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 5), app.debugDescription)
        let rows = app.cells.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Letter 1"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let row = rows.allElementsBoundByIndex.first { $0.isHittable } ?? rows.firstMatch
        XCTAssertTrue(row.isHittable, app.debugDescription)
        return row
    }

    private func editNote(_ note: String, save: Bool) {
        typeNoteDraft(note)
        app.alerts["Bookmark Note"].buttons[save ? "Save" : "Cancel"].tap()
    }

    private let queueBooks = ["Alice's Adventures in Wonderland", "Moby-Dick", "The Raven"]

    private func assertQueue(_ expected: [String]) {
        let ordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let list = self.app.collectionViews["ListeningQueueList"]
                var previousY = -CGFloat.infinity
                for title in expected {
                    let labels = list.staticTexts.matching(identifier: title)
                    guard labels.count == 1 else { return false }
                    let frame = labels.firstMatch.frame
                    guard frame.minY.isFinite, frame.width > 0, frame.height > 0,
                          frame.intersects(self.app.windows.firstMatch.frame), frame.minY > previousY else { return false }
                    previousY = frame.minY
                }
                return self.queueBooks.filter { !expected.contains($0) }.allSatisfy { !list.staticTexts[$0].exists }
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ordered], timeout: 5), .completed, app.debugDescription)
    }

    private func queueRow(_ title: String) -> XCUIElement {
        let row = app.collectionViews["ListeningQueueList"].cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        return row
    }

    private func finishQueueEditing() {
        let buttons = app.navigationBars["Listening queue"].buttons.matching(identifier: "Done").allElementsBoundByIndex
        let leading = buttons.min { $0.frame.minX < $1.frame.minX }
        XCTAssertNotNil(leading, app.debugDescription)
        leading?.tap()
        XCTAssertTrue(app.navigationBars["Listening queue"].buttons["Edit"].waitForExistence(timeout: 5))
    }

    private func switchControl(_ label: String) -> XCUIElement {
        let outer = app.switches.matching(identifier: label).firstMatch
        XCTAssertTrue(outer.exists, app.debugDescription)
        return outer.switches.firstMatch.exists ? outer.switches.firstMatch : outer
    }

    private func emptyQueue() {
        XCTAssertTrue(app.navigationBars["Listening queue"].waitForExistence(timeout: 5))
        for _ in 0..<30 {
            let row = app.collectionViews["ListeningQueueList"].cells.allElementsBoundByIndex.first { cell in
                let frame = cell.frame
                return frame.minX.isFinite && frame.minY.isFinite && frame.width > 0 && frame.height > 0
                    && cell.buttons.count > 0 && cell.switches.count == 0 && cell.isHittable
            }
            guard let row else { break }
            row.swipeLeft()
            tap("Delete")
        }
        XCTAssertTrue(app.staticTexts["Your queue is empty"].exists, app.debugDescription)
    }

    private func configureDriving(speed: String, boostQuiet: Bool, skipSilence: Bool, volume: String, sleepMinutes: Int) {
        XCTAssertTrue(app.navigationBars["Listening presets"].waitForExistence(timeout: 5))
        let speedPicker = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Speed,")).firstMatch
        XCTAssertTrue(speedPicker.isHittable, app.debugDescription)
        speedPicker.tap()
        tap(speed)
        for (label, enabled) in [("Boost quiet voices", boostQuiet), ("Skip silence", skipSilence)] {
            let toggle = switchControl(label)
            if toggle.value as? String != (enabled ? "1" : "0") { toggle.tap() }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        }
        let volumePicker = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Volume boost,")).firstMatch
        volumePicker.tap()
        tap(volume)
        for _ in 0..<37 {
            let stepper = app.steppers.firstMatch
            XCTAssertTrue(stepper.isHittable, app.debugDescription)
            let current = stepper.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? 0
            if current == sleepMinutes { break }
            let direction = current < sleepMinutes ? "Increment" : "Decrement"
            let button = stepper.buttons.matching(NSPredicate(format: "label CONTAINS %@", direction)).firstMatch
            XCTAssertTrue(button.isHittable, app.debugDescription)
            button.tap()
        }
        XCTAssertEqual(app.steppers.firstMatch.label, sleepMinutes == 0 ? "Sleep timer off" : "Sleep in \(sleepMinutes) minutes")
    }

    func testQueueReorderAndRemovalSurviveRelaunch() {
        prepareWindow()
        openPausedFrankenstein()
        menu("Listening queue…")
        XCTAssertTrue(app.navigationBars["Listening queue"].waitForExistence(timeout: 5))
        let autoplay = switchControl("Play queued books automatically")
        if autoplay.value as? String != "0" { autoplay.tap() }
        XCTAssertEqual(autoplay.value as? String, "0")
        emptyQueue()
        tap("Add")
        let picker = app.collectionViews["QueueBookPickerList"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
        for title in queueBooks {
            let choices = picker.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
            let choice = choices.allElementsBoundByIndex.first { $0.isHittable } ?? choices.firstMatch
            XCTAssertTrue(choice.isEnabled && choice.isHittable, app.debugDescription)
            choice.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { !choices.firstMatch.isEnabled }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                           "An enqueued book must not be added twice.\n\(app.debugDescription)")
        }
        tap("Done")
        assertQueue(queueBooks)
        tap("Edit")
        // iOS 26 calls this "Reorder Remove"; iOS 27 includes the book's title.
        let reorder = NSPredicate(format: "label BEGINSWITH %@", "Reorder ")
        let last = queueRow("The Raven").buttons.matching(reorder).firstMatch
        let first = queueRow("Alice's Adventures in Wonderland").buttons.matching(reorder).firstMatch
        XCTAssertTrue(last.isHittable && first.isHittable, app.debugDescription)
        last.press(forDuration: 0.7, thenDragTo: first)
        let reordered = ["The Raven", "Alice's Adventures in Wonderland", "Moby-Dick"]
        assertQueue(reordered)
        capture("Reordered listening queue")
        finishQueueEditing()
        tap("Done")
        pause()
        app.terminate()
        prepareWindow()
        openPausedFrankenstein()
        menu("Listening queue…")
        assertQueue(reordered)
        queueRow("Alice's Adventures in Wonderland").swipeLeft()
        tap("Delete")
        assertQueue(["The Raven", "Moby-Dick"])
        capture("Queue after removal")
        tap("Done")
        app.terminate()
        prepareWindow()
        openPausedFrankenstein()
        menu("Listening queue…")
        assertQueue(["The Raven", "Moby-Dick"])
        tap("Done")
        pause()
    }

    func testCustomizedPresetPersistsAndAppliesWithoutStartingPlayback() {
        prepareWindow()
        openPausedFrankenstein()
        menu("Listening presets…")
        configureDriving(speed: "1.5×", boostQuiet: false, skipSilence: true, volume: "2×", sleepMinutes: 5)
        capture("Customized Driving preset")
        tap("Done")
        pause()
        app.terminate()
        prepareWindow()
        openPausedFrankenstein()
        menu("Listening presets…")
        XCTAssertTrue(app.cells.buttons.matching(NSPredicate(format: "label == %@", "Speed, 1.5×")).firstMatch.exists)
        XCTAssertEqual(switchControl("Boost quiet voices").value as? String, "0")
        XCTAssertEqual(switchControl("Skip silence").value as? String, "1")
        XCTAssertTrue(app.cells.buttons.matching(NSPredicate(format: "label == %@", "Volume boost, 2×")).firstMatch.exists)
        XCTAssertEqual(app.steppers.firstMatch.label, "Sleep in 5 minutes")
        tap("Apply Driving")
        tap("Done")
        XCTAssertEqual(app.buttons["Playback speed"].value as? String, "1.5 times")
        XCTAssertTrue(app.buttons.matching(identifier: "Play").allElementsBoundByIndex.contains { $0.isHittable },
                      "Applying customized controls must retain the paused state")
        tap("Sleep timer")
        let timer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Pausing in ")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5), app.debugDescription)
        let clock = timer.label.replacingOccurrences(of: "Pausing in ", with: "")
        let seconds = clock.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        XCTAssertTrue((270...300).contains(seconds), "The preset must install its five-minute timer: \(timer.label)")
        capture("Customized preset applied while paused")
        chooseSleepOff()
        tap("Close")
        tap("Settings")
        let silence = app.switches["Skip Silence"].firstMatch
        for _ in 0..<6 where !silence.isHittable { app.swipeUp() }
        XCTAssertEqual(switchControl("Skip Silence").value as? String, "1")
        XCTAssertEqual(switchControl("Boost Quiet Voices").value as? String, "0")
        let volume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Volume Boost,")).firstMatch
        XCTAssertTrue(volume.label.contains("2×"), app.debugDescription)
        capture("Applied audio controls in Settings")
        // Return the generated QA app to a predictable preset for later audit journeys.
        let mini = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing:")).firstMatch
        XCTAssertTrue(mini.isHittable, app.debugDescription)
        mini.tap()
        pause()
        menu("Listening presets…")
        configureDriving(speed: "1×", boostQuiet: true, skipSilence: false, volume: "1×", sleepMinutes: 0)
        tap("Apply Driving")
        tap("Done")
        pause()
    }

    func testBookmarkNoteCancelSaveDeleteAndRelaunch() {
        prepareWindow()
        openPausedFrankenstein()
        menu("Add Bookmark")
        menu("Bookmarks…")
        let mark = firstLetterBookmark()
        mark.swipeLeft()
        tap("Note")
        let note = "Native bookmark audit " + UUID().uuidString.prefix(8)
        editNote(note, save: false)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch.exists)
        mark.swipeLeft()
        tap("Note")
        editNote(note, save: true)
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), app.debugDescription)
        capture("Saved bookmark note")
        tap("Done")
        pause()
        app.terminate()
        prepareWindow()
        openPausedFrankenstein()
        menu("Bookmarks…")
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The note must survive relaunch")
        saved.swipeLeft()
        tap("Delete")
        XCTAssertFalse(saved.exists)
        capture("Deleted bookmark note")
        tap("Done")
        app.terminate()
        prepareWindow()
        openPausedFrankenstein()
        menu("Bookmarks…")
        XCTAssertFalse(saved.exists, "A deleted bookmark must stay deleted after relaunch")
        tap("Done")
        pause()
    }

    func testBookmarkNoteStaysWithItsBookWhenQueueAdvancesDuringEditing() {
        prepareWindow()
        openPausedFrankenstein()
        menu("Listening queue…")
        emptyQueue()
        tap("Add")
        let moby = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Moby-Dick")).firstMatch
        XCTAssertTrue(moby.waitForExistence(timeout: 5), app.debugDescription)
        moby.tap()
        tap("Done")
        let toggle = app.switches["Play queued books automatically"].firstMatch
        let control = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        if control.value as? String != "1" { control.tap() }
        XCTAssertEqual(control.value as? String, "1")
        tap("Done")
        // Leave enough real playback time to enter and verify a draft before autoplay.
        tap("Playback speed")
        tap("0.75×")
        tap("Done")
        menu("Add Bookmark")
        tap("Play")
        menu("Bookmarks…")
        let mark = firstLetterBookmark()
        mark.swipeLeft()
        tap("Note")
        let alert = app.alerts["Bookmark Note"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let note = "Original book note " + UUID().uuidString.prefix(8)
        typeNoteDraft(note)
        XCTAssertEqual(app.staticTexts["PlayerBookTitle"].label, "Frankenstein", "Begin editing before the book changes")
        capture("Bookmark draft before queue advances")
        let nextBook = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Moby-Dick"), object: app.staticTexts["PlayerBookTitle"])
        XCTAssertEqual(XCTWaiter.wait(for: [nextBook], timeout: 45), .completed, app.debugDescription)
        capture("Bookmark editor while next book is playing")
        XCTAssertTrue(alert.exists, "The editor must preserve a typed draft across actual queue autoplay")
        XCTAssertEqual(alert.textFields.firstMatch.value as? String, note)
        alert.buttons["Save"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch.exists,
                       "The old book's note must not be attached to the newly playing book")
        tap("Done")
        pause()
        tap("Close")
        tap("BookDetailPlayButton")
        if !app.buttons["Playback speed"].waitForExistence(timeout: 2) {
            app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Now playing:")).firstMatch.tap()
        }
        pause()
        XCTAssertEqual(app.staticTexts["PlayerBookTitle"].label, "Frankenstein")
        menu("Bookmarks…")
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", note)).firstMatch
        let persisted = saved.waitForExistence(timeout: 5)
        capture("Original book after note save")
        XCTAssertTrue(persisted, "Save must update the bookmark on the book where editing began.\n\(app.debugDescription)")
    }

    func testLibraryAndSettingsTabsFitNativeWindow() {
        prepareWindow()
        for tab in ["Stats", "Sources", "Settings", "Library"] {
            tap(tab)
            XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons[tab].firstMatch.isSelected, "The requested tab must actually become selected")
            capture(tab)
        }
    }

    func testBookmarkSeekingPresetAndQueuePlayback() {
        prepareWindow()
        openPausedFrankenstein()
        chooseChapter("Chapter 1")
        pause()
        menu("Add Bookmark")
        chooseChapter("Letter 1")
        pause()
        XCTAssertEqual(app.buttons["PlayerChapterButton"].label, "Letter 1")
        menu("Bookmarks…")
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 5))
        let marks = app.cells.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 1"))
        let mark = marks.allElementsBoundByIndex.first { $0.isHittable } ?? marks.firstMatch
        XCTAssertTrue(mark.isHittable, app.debugDescription)
        mark.tap()
        XCTAssertEqual(app.buttons["PlayerChapterButton"].label, "Chapter 1")
        XCTAssertTrue(app.buttons.matching(identifier: "Play").allElementsBoundByIndex.contains { $0.isHittable }, "A bookmark seek must retain the paused state")
        capture("Bookmark restored paused chapter")

        menu("Listening presets…")
        let bedtime = app.buttons["Apply Bedtime"]
        for _ in 0..<4 where !bedtime.isHittable { app.swipeUp() }
        tap("Apply Bedtime")
        tap("Done")
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists, "Applying a preset must not start audio")
        tap("Sleep timer")
        chooseSleepOff()

        menu("Listening queue…")
        emptyQueue()
        tap("Add")
        let alice = app.collectionViews["QueueBookPickerList"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alice's Adventures in Wonderland")).firstMatch
        XCTAssertTrue(alice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(alice.isEnabled && alice.isHittable)
        alice.tap()
        tap("Done")
        assertQueue(["Alice's Adventures in Wonderland"])
        let toggle = app.switches["Play queued books automatically"].firstMatch
        XCTAssertTrue(toggle.exists, app.debugDescription)
        let control = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        if control.value as? String != "1" { control.tap() }
        XCTAssertEqual(control.value as? String, "1")
        capture("Queued book and enabled autoplay")
        tap("Done")
        tap("Play")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                self.app.staticTexts["PlayerBookTitle"].label == "Alice's Adventures in Wonderland"
                && self.app.buttons.matching(identifier: "Pause").allElementsBoundByIndex.contains { $0.isHittable }
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 25), .completed, app.debugDescription)
        pause()
        capture("Automatically advanced queued book")
    }
}
