import XCTest
@testable import CobuxCore

final class SpeechChunkerTests: XCTestCase {

    // MARK: - Basic sentence cutting

    func testEmitsSentenceAsSoonAsTerminatorArrives() {
        let chunker = SpeechChunker()
        let chunks = chunker.ingest("This is the first sentence. ")
        XCTAssertEqual(chunks, ["This is the first sentence."])
    }

    func testHoldsIncompleteTrailingTextUntilTerminatorArrives() {
        let chunker = SpeechChunker()
        let chunks = chunker.ingest("This sentence has no end yet")
        XCTAssertEqual(chunks, [])
    }

    func testSentenceSplitsAcrossMultipleDeltas() {
        let chunker = SpeechChunker()
        XCTAssertEqual(chunker.ingest("The mitochondria is the "), [])
        let chunks = chunker.ingest("powerhouse of the cell. And that matters because")
        XCTAssertEqual(chunks, ["The mitochondria is the powerhouse of the cell."])
    }

    func testMultipleSentencesInOneDeltaEachEmit() {
        let chunker = SpeechChunker()
        let chunks = chunker.ingest("This is the first full sentence. This is the second full sentence. Third one has no end yet")
        XCTAssertEqual(chunks, ["This is the first full sentence.", "This is the second full sentence."])
    }

    func testShortSentencesMergeTogetherRatherThanSpeakingChoppyFragments() {
        // "First one." and "Second one." are each individually under minSpeakableLength —
        // speaking either alone would sound choppy, so they merge into one carried-forward
        // chunk. Neither is long enough on its own to cross the bar mid-stream, so both stay
        // held until finish() flushes whatever's left.
        let chunker = SpeechChunker()
        let midStream = chunker.ingest("First one. Second one. ")
        XCTAssertEqual(midStream, [])
        let final = chunker.finish()
        XCTAssertEqual(final, ["First one. Second one."])
    }

    func testDoesNotCutOnTerminatorAtBufferEdgeMidStream() {
        // A period right at the edge of what's arrived so far might just be the start of
        // "..." or "?!" — don't cut until either more text disproves that or finish() is called.
        let chunker = SpeechChunker()
        let chunks = chunker.ingest("Wait for it.")
        XCTAssertEqual(chunks, [])
    }

    func testFinishFlushesTrailingTerminatorAtBufferEdge() {
        let chunker = SpeechChunker()
        _ = chunker.ingest("Wait for it.")
        let final = chunker.finish()
        XCTAssertEqual(final, ["Wait for it."])
    }

    // MARK: - Fallback cut for long unterminated runs

    func testForcesCutAfterFallbackLengthWithNoTerminator() {
        let chunker = SpeechChunker()
        let runOn = String(repeating: "word ", count: 60) // 300 chars, no terminator
        let chunks = chunker.ingest(runOn)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks[0].count, SpeechChunker.fallbackCutLength)
        XCTAssertFalse(chunks[0].isEmpty)
    }

    func testFallbackCutPrefersClauseBreakOverHardCut() {
        let chunker = SpeechChunker()
        let prefix = String(repeating: "a", count: 240)
        let text = "\(prefix), and then it kept going with no end in sight for quite a while longer than expected"
        let chunks = chunker.ingest(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasSuffix(","), "should cut at the last clause break within budget, not mid-word")
    }

    // MARK: - Short-fragment merging

    func testShortFragmentMergesIntoNextSentence() {
        let chunker = SpeechChunker()
        // "Dr." looks like a sentence end but is only a 3-char fragment — merges forward into
        // the sentence it actually belongs to rather than being spoken as its own utterance.
        let midStream = chunker.ingest("Dr. Smith explained the diagnosis clearly. Next sentence here.")
        XCTAssertEqual(midStream, ["Dr. Smith explained the diagnosis clearly."])
        // The trailing sentence sits at the buffer edge with no confirming whitespace yet —
        // held back until finish() confirms nothing more is coming.
        let final = chunker.finish()
        XCTAssertEqual(final, ["Next sentence here."])
    }

    func testGenuinelyShortFinalFragmentIsEmittedOnFinish() {
        let chunker = SpeechChunker()
        let midStream = chunker.ingest("Some longer opening sentence here that clears the bar on its own. ")
        XCTAssertEqual(midStream, ["Some longer opening sentence here that clears the bar on its own."])
        _ = chunker.ingest("OK.")
        let final = chunker.finish()
        // Nothing left to merge "OK." into once the stream is done — it must still surface,
        // even though it's under minSpeakableLength.
        XCTAssertEqual(final, ["OK."])
    }

    // MARK: - <sources> withholding

    func testSourcesTagInSingleDeltaNeverSpoken() {
        let chunker = SpeechChunker()
        let midStream = chunker.ingest("The answer to your question is clear enough.\n<sources>Attached</sources>")
        XCTAssertEqual(midStream, ["The answer to your question is clear enough."])
        let final = chunker.finish()
        XCTAssertTrue(final.allSatisfy { !$0.contains("sources") && !$0.contains("Attached") })
    }

    func testSourcesTagSplitAcrossDeltasNeverSpoken() {
        let chunker = SpeechChunker()
        var allChunks: [String] = []
        allChunks += chunker.ingest("The answer is clear.\n<sour")
        allChunks += chunker.ingest("ces>Attached</sour")
        allChunks += chunker.ingest("ces>")
        allChunks += chunker.finish()
        XCTAssertEqual(allChunks, ["The answer is clear."])
    }

    func testPartialTagPrefixThatNeverCompletesIsFlushedOnFinish() {
        // Edge case: text that happens to start like the tag but the stream ends before it
        // could ever complete — since it can never become the real tag, it's just ordinary
        // text and must be spoken, not silently dropped.
        let chunker = SpeechChunker()
        _ = chunker.ingest("The answer involves less than sign, sources")
        let final = chunker.finish()
        XCTAssertFalse(final.isEmpty)
        XCTAssertTrue(final.joined().contains("less than sign"))
    }

    func testTextAfterSourcesTagOpenIsNeverEmittedEvenIfSentenceLike() {
        let chunker = SpeechChunker()
        var allChunks: [String] = []
        allChunks += chunker.ingest("Real answer here. <sources>Book One. Book Two.</sources>")
        allChunks += chunker.finish()
        XCTAssertEqual(allChunks, ["Real answer here."])
    }

    func testRawTextIncludesSourcesTagForCitationParsing() {
        let chunker = SpeechChunker()
        _ = chunker.ingest("Real answer here.\n<sources>Attached</sources>")
        XCTAssertEqual(chunker.rawText, "Real answer here.\n<sources>Attached</sources>")
    }

    // MARK: - Markdown sanitizing

    func testStripsBoldAndItalic() {
        let chunker = SpeechChunker()
        let chunks = chunker.ingest("This is **very** important and *quite* clear. ")
        XCTAssertEqual(chunks, ["This is very important and quite clear."])
    }

    func testStripsInlineCodeAndLinks() {
        let chunker = SpeechChunker()
        let chunks = chunker.ingest("Call `fetchData()` per the [docs](https://example.com) here. ")
        XCTAssertEqual(chunks, ["Call fetchData() per the docs here."])
    }

    func testStripsHeadingAndBulletMarkers() {
        let chunker = SpeechChunker()
        _ = chunker.ingest("# Summary\n- First point here.")
        let final = chunker.finish()
        XCTAssertTrue(final.joined(separator: " ").contains("Summary"))
        XCTAssertFalse(final.joined().contains("#"))
        XCTAssertFalse(final.joined().hasPrefix("- "))
    }

    // MARK: - Full simulated stream

    func testFullSimulatedStreamEndToEnd() {
        let chunker = SpeechChunker()
        var allChunks: [String] = []
        let deltas = [
            "Atomic habits ", "compound over time. ", "Small changes ",
            "**really** do add up. ", "\n<sources>Atomic", " Habits</sources>"
        ]
        for delta in deltas {
            allChunks += chunker.ingest(delta)
        }
        allChunks += chunker.finish()

        XCTAssertEqual(allChunks, ["Atomic habits compound over time.", "Small changes really do add up."])
        XCTAssertFalse(allChunks.joined().contains("sources"))
        XCTAssertTrue(chunker.rawText.contains("<sources>Atomic Habits</sources>"))
    }
}
