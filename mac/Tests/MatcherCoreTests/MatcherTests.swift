import XCTest
@testable import MatcherCore

final class MatcherTests: XCTestCase {
    let outline = """
    Welcome and introductions
    Why sleep matters
      Memory consolidation [cues: remember, learning]
      Immune health
    Tips for better sleep
      Keep a consistent schedule
      Avoid screens before bed
    Questions
    """

    func testParsesNestingAndCues() {
        let items = parseOutline(outline)
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items[2].level, 1)
        XCTAssertEqual(items[2].cues, ["remember", "learning"])
        XCTAssertEqual(items[2].text, "Memory consolidation")
    }

    func testAdvancesInOrder() {
        let m = Matcher(items: parseOutline(outline))
        func say(_ t: String) { t.components(separatedBy: ". ").forEach { m.feed($0) } }
        say("Hi everyone welcome. Thanks for coming, quick introductions"); XCTAssertEqual(m.current, 0)
        say("So why does sleep matter so much. Sleep matters for everything"); XCTAssertEqual(m.current, 1)
        say("When you sleep your brain consolidates memory. You remember learning better"); XCTAssertEqual(m.current, 2)
        say("Your immune system and health also depend on it. Immune health improves"); XCTAssertEqual(m.current, 3)
        say("Now some tips for better sleep. Here are my tips"); XCTAssertEqual(m.current, 4)
        say("Keep a consistent schedule every day. Same schedule on weekends"); XCTAssertEqual(m.current, 5)
        say("Avoid screens before bed. Put phone screens away before bed"); XCTAssertEqual(m.current, 6)
        say("Any questions. Happy to take questions"); XCTAssertEqual(m.current, 7)
    }

    func testStrayWordDoesNotJump() {
        let m = Matcher(items: parseOutline(outline))
        m.feed("welcome everyone introductions")
        m.feed("screens")
        XCTAssertEqual(m.current, 0)
    }

    func testShouldLocate() {
        XCTAssertFalse(shouldLocate(now: 20, lastCallAt: 15, lastConfidentAt: 19, newWords: 10, inFlight: false))
        XCTAssertTrue(shouldLocate(now: 20, lastCallAt: 15, lastConfidentAt: 13, newWords: 10, inFlight: false))
        XCTAssertTrue(shouldLocate(now: 20, lastCallAt: 9, lastConfidentAt: 19, newWords: 10, inFlight: false))
        XCTAssertFalse(shouldLocate(now: 20, lastCallAt: 9, lastConfidentAt: 19, newWords: 10, inFlight: true))
        XCTAssertFalse(shouldLocate(now: 20, lastCallAt: 9, lastConfidentAt: 19, newWords: 3, inFlight: false))
    }

    func testTutorialPagesToShow() {
        let addedIn = [1, 1, 8, 13, 14]
        XCTAssertEqual(tutorialPagesToShow(addedIn: addedIn, lastSeen: 0), [0, 1, 2, 3, 4])   // new user: everything
        XCTAssertEqual(tutorialPagesToShow(addedIn: addedIn, lastSeen: 13), [4])              // after an update: what's new
        XCTAssertEqual(tutorialPagesToShow(addedIn: addedIn, lastSeen: 14), [])               // up to date
        // Today's tour: someone who saw everything up to 13 gets just "meaning" and "compare".
        let tour = [1, 1, 1, 14, 1, 12, 14, 1]
        XCTAssertEqual(tutorialPagesToShow(addedIn: tour, lastSeen: 13), [3, 6])
    }
}
