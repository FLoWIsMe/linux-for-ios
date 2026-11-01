import XCTest
@testable import TernCore

final class DeleteKeyAcceleratorTests: XCTestCase {
    /// Presses the key the way iOS auto-repeat does: once, then after `delay` every `interval`.
    /// The defaults are exact binary fractions so the sums below have no rounding.
    private func hold(_ accelerator: inout DeleteKeyAccelerator, from start: TimeInterval, delay: TimeInterval = 0.5, interval: TimeInterval = 0.125, repeats: Int) -> [DeleteKeyAccelerator.Action] {
        var actions = [accelerator.press(at: start)]
        var time = start + delay
        for _ in 0..<repeats {
            actions.append(accelerator.press(at: time))
            time += interval
        }
        return actions
    }

    func testSeparateTapsDeleteCharacters() {
        var accelerator = DeleteKeyAccelerator()
        var time: TimeInterval = 10
        for _ in 0..<30 {
            XCTAssertEqual(accelerator.press(at: time), .character)
            time += 0.4
        }
        XCTAssertTrue(accelerator.isHolding)
    }

    func testHoldSpeedsUpToWordsAfterAWhile() {
        var accelerator = DeleteKeyAccelerator()
        let actions = hold(&accelerator, from: 100, repeats: 40)
        // The press itself and the first repeats delete characters.
        XCTAssertEqual(Array(actions.prefix(10)), Array(repeating: .character, count: 10))
        XCTAssertTrue(actions.contains(.word))
        let firstWord = actions.firstIndex(of: .word)!
        // The press at 100 is too far from the first repeat at 100.5 to count as the same hold, so
        // the hold starts there; the eleventh press of it, at 101.75, is the first past 1.2 seconds.
        XCTAssertEqual(firstWord, 11)
        // After that words leave at the slower pace: a word, a pause, a word.
        XCTAssertFalse(actions[firstWord...].contains(.character))
        XCTAssertEqual(actions[firstWord + 1], .pause)
        XCTAssertEqual(actions[firstWord + 2], .word)
    }

    func testQuickTapsDoNotTurnIntoWords() {
        var accelerator = DeleteKeyAccelerator()
        var time: TimeInterval = 5
        // Nine taps a quarter second apart span two seconds but stay under the press count.
        for _ in 0..<9 {
            XCTAssertEqual(accelerator.press(at: time), .character)
            time += 0.25
        }
    }

    func testReleasingStartsOver() {
        var accelerator = DeleteKeyAccelerator()
        var actions = hold(&accelerator, from: 0, repeats: 20)
        XCTAssertTrue(actions.contains(.word))
        // A pause longer than the repeat gap is a new press.
        actions = hold(&accelerator, from: 10, repeats: 5)
        XCTAssertEqual(actions, Array(repeating: .character, count: 6))
    }

    func testResetForgetsTheHold() {
        var accelerator = DeleteKeyAccelerator()
        _ = hold(&accelerator, from: 0, repeats: 20)
        accelerator.reset()
        XCTAssertFalse(accelerator.isHolding)
        // Without the reset this press would still be part of the hold.
        XCTAssertEqual(accelerator.press(at: 3.0), .character)
    }

    func testSlowerRepeatRateStillAccelerates() {
        var accelerator = DeleteKeyAccelerator()
        let actions = hold(&accelerator, from: 0, interval: 0.2, repeats: 20)
        XCTAssertTrue(actions.contains(.word))
        XCTAssertFalse(actions.contains(.pause), "at five repeats a second every repeat can take a word")
    }
}
