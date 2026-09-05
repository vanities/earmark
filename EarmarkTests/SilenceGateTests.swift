import XCTest
@testable import Earmark

final class SilenceGateTests: XCTestCase {
    func testEntersSilenceOnlyAfterSustainedQuiet() {
        var gate = SilenceGate()
        // Loud speech: no change.
        XCTAssertNil(gate.step(rms: 0.2, seconds: 0.05))
        XCTAssertFalse(gate.isSilent)
        // A brief quiet blip shorter than the minimum does not trigger.
        XCTAssertNil(gate.step(rms: 0.005, seconds: 0.05))
        XCTAssertFalse(gate.isSilent, "a short word-gap must not count as silence")
        // Sustained quiet crosses the threshold.
        XCTAssertEqual(gate.step(rms: 0.005, seconds: 0.1), .enteredSilence)
        XCTAssertTrue(gate.isSilent)
    }

    func testEndsSilenceWhenSpeechReturns() {
        var gate = SilenceGate()
        _ = gate.step(rms: 0.001, seconds: 0.2)   // enter
        XCTAssertTrue(gate.isSilent)
        XCTAssertEqual(gate.step(rms: 0.2, seconds: 0.05), .endedSilence)
        XCTAssertFalse(gate.isSilent)
    }

    func testHysteresisAvoidsFlickerInTheDeadband() {
        var gate = SilenceGate()
        _ = gate.step(rms: 0.001, seconds: 0.2)   // enter silence
        // A value between exit and enter thresholds should not end silence.
        XCTAssertNil(gate.step(rms: 0.03, seconds: 0.05))
        XCTAssertTrue(gate.isSilent, "mid-band loudness keeps the current state")
    }

    func testFiresOncePerTransitionNotEveryBuffer() {
        var gate = SilenceGate()
        XCTAssertEqual(gate.step(rms: 0.001, seconds: 0.2), .enteredSilence)
        XCTAssertNil(gate.step(rms: 0.001, seconds: 0.2), "already silent — no repeat event")
        XCTAssertNil(gate.step(rms: 0.001, seconds: 0.2))
    }

    func testSilenceRateScalesWithBaseButIsCapped() {
        XCTAssertEqual(PlaybackAudioProcessor.Config(baseRate: 1).silenceRate, 3, accuracy: 0.001)
        XCTAssertEqual(PlaybackAudioProcessor.Config(baseRate: 1.5).silenceRate, 4, accuracy: 0.001, "capped at 4x")
        XCTAssertEqual(PlaybackAudioProcessor.Config(baseRate: 2).silenceRate, 4, accuracy: 0.001)
    }
}
