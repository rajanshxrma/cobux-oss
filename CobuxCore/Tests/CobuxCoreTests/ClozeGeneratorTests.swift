import XCTest
@testable import CobuxCore

final class ClozeGeneratorTests: XCTestCase {

    // Real-shaped example matching Cobux's actual Robbins seed data structure.
    let lysosomeHighlight = ClozeSourceHighlight(
        id: "h1",
        text: "Lysosomes vs. proteasomes — lysosomes contain roughly 40 acid hydrolases that digest macromolecules delivered by endocytosis or by autophagy, marked by the protein LC3; proteasomes are cytosolic multi-subunit grinders that degrade poly-ubiquitin-tagged cytosolic proteins.",
        tags: ["lysosome", "proteasome", "autophagy", "ubiquitin", "protein degradation"]
    )

    let siblingHighlights = [
        ClozeSourceHighlight(id: "h2", text: "Apoptosis is programmed cell death — mediated by caspases.", tags: ["apoptosis", "caspase", "programmed cell death"]),
        ClozeSourceHighlight(id: "h3", text: "Necrosis is uncontrolled cell death — causes inflammation.", tags: ["necrosis", "inflammation", "cell death"]),
        ClozeSourceHighlight(id: "h4", text: "Autophagy recycles organelles — regulated by mTOR.", tags: ["autophagy", "mTOR", "organelle recycling"]),
    ]

    /// Deterministic fake standing in for real embedding cosine similarity: shares a
    /// vocabulary bucket → high similarity, otherwise low. Lets tests be exact without
    /// depending on real NLContextualEmbedding output.
    func fakeSimilarity(_ a: String, _ b: String) -> Float {
        let related: [Set<String>] = [
            ["lysosome", "proteasome", "autophagy", "ubiquitin", "protein degradation", "mtor", "organelle recycling"],
            ["apoptosis", "caspase", "programmed cell death", "necrosis", "inflammation", "cell death"],
        ]
        let aLower = a.lowercased(), bLower = b.lowercased()
        for bucket in related where bucket.contains(aLower) && bucket.contains(bLower) {
            return aLower == bLower ? 1.0 : 0.7
        }
        return 0.1
    }

    // MARK: Headword/body split

    func testSplitsOnEmDash() {
        let (headword, body) = ClozeGenerator.splitHeadwordBody(lysosomeHighlight.text)
        XCTAssertEqual(headword, "Lysosomes vs. proteasomes")
        XCTAssertTrue(body.hasPrefix("lysosomes contain"))
    }

    func testNoSeparatorReturnsWholeTextAsBody() {
        let (headword, body) = ClozeGenerator.splitHeadwordBody("Just a plain sentence with no dash.")
        XCTAssertNil(headword)
        XCTAssertEqual(body, "Just a plain sentence with no dash.")
    }

    // MARK: Candidate scoring — tags are the highest-confidence source

    func testTagsThatAppearInBodyAreTopCandidates() {
        let (headword, body) = ClozeGenerator.splitHeadwordBody(lysosomeHighlight.text)
        let candidates = ClozeGenerator.scoredCandidates(body: body, tags: lysosomeHighlight.tags, headword: headword)
        let spans = candidates.map { $0.span.lowercased() }
        XCTAssertTrue(spans.contains("autophagy"))
    }

    func testHeadwordItselfIsPenalizedOutOfContention() {
        // "lysosomes vs proteasomes" duplicates the headword AND appears twice in the
        // body (multi-occurrence penalty stacks with the headword penalty); "autophagy"
        // is a distinct, single-occurrence, real concept. The headword duplicate must
        // rank below it despite also being a literal tag match.
        let candidates = ClozeGenerator.scoredCandidates(
            body: "The lysosomes vs proteasomes comparison is classic; lysosomes vs proteasomes differ by autophagy involvement.",
            tags: ["lysosomes vs proteasomes", "autophagy"],
            headword: "lysosomes vs proteasomes"
        )
        let top = candidates.first
        XCTAssertEqual(top?.span.lowercased(), "autophagy", "a distinct real concept must outrank a candidate that merely repeats the headword")
    }

    func testHeadwordPenaltyMakesItScoreLowerThanAnUnpenalizedEquivalent() {
        // Isolated check that the penalty itself fires, independent of ranking against
        // other candidates (which the test above already covers).
        let penalized = ClozeGenerator.scoredCandidates(
            body: "Ubiquitin marks ubiquitin for degradation.",
            tags: ["ubiquitin"],
            headword: "ubiquitin"
        ).first
        let unpenalized = ClozeGenerator.scoredCandidates(
            body: "Ubiquitin marks proteins for degradation.",
            tags: ["ubiquitin"],
            headword: "unrelated headword"
        ).first
        XCTAssertNotNil(penalized)
        XCTAssertNotNil(unpenalized)
        XCTAssertLessThan(penalized!.score, unpenalized!.score)
    }

    // MARK: Full generation — the real end-to-end shape

    func testGeneratesCardsFromRealShapedHighlight() {
        let cards = ClozeGenerator.generate(from: lysosomeHighlight, siblingHighlights: siblingHighlights, similarity: fakeSimilarity)
        XCTAssertFalse(cards.isEmpty)
        for card in cards {
            XCTAssertTrue(card.stem.contains(ClozeGenerator.blankMarker), "stem must contain the blank marker")
            XCTAssertFalse(card.stem.lowercased().contains(card.answer.lowercased()), "the answer must not still be visible anywhere in its own stem")
        }
    }

    func testDistractorsComeFromSameChapterSiblingsWithinSimilarityBand() {
        let cards = ClozeGenerator.generate(from: lysosomeHighlight, siblingHighlights: siblingHighlights, similarity: fakeSimilarity)
        guard let autophagyCard = cards.first(where: { $0.answer.lowercased() == "autophagy" }) else {
            XCTFail("expected an 'autophagy' cloze card from this highlight's own tags")
            return
        }
        // "autophagy" is IN the related bucket already (fakeSimilarity returns 1.0 for
        // itself), so its actual distractors should come from the same bucket at 0.7 —
        // "protein degradation", "ubiquitin", "lysosome", "proteasome" — not the
        // apoptosis/necrosis bucket, which sits at 0.1.
        XCTAssertFalse(autophagyCard.distractors.contains { ["apoptosis", "necrosis", "caspase"].contains($0.lowercased()) })
    }

    func testFewerThanThreeDistractorsDegradesToFreeRecall() {
        let isolated = ClozeSourceHighlight(id: "iso", text: "Vitamin K deficiency — causes bleeding disorders.", tags: ["vitamin k", "bleeding disorder"])
        let cards = ClozeGenerator.generate(from: isolated, siblingHighlights: [], similarity: { _, _ in 0.1 })
        for card in cards {
            XCTAssertTrue(card.isFreeRecall, "with zero sibling highlights, there can be no MCQ distractors — must degrade gracefully")
            XCTAssertTrue(card.distractors.isEmpty)
        }
    }

    // MARK: Quality gates

    func testRejectsAnswerShorterThanMinimumLength() {
        let short = ClozeSourceHighlight(id: "s", text: "The pH is 5 — acidic environment.", tags: ["pH"])
        let cards = ClozeGenerator.generate(from: short, siblingHighlights: [], similarity: { _, _ in 0.1 })
        XCTAssertFalse(cards.contains { $0.answer.count < ClozeGenerator.minAnswerLength })
    }

    func testAllOccurrencesOfAnswerAreBlankedNotJustFirst() {
        let repeated = ClozeSourceHighlight(
            id: "r",
            text: "Ubiquitin tags proteins — ubiquitin is a small protein that marks targets for degradation via ubiquitin chains.",
            tags: ["ubiquitin"]
        )
        let cards = ClozeGenerator.generate(from: repeated, siblingHighlights: [], similarity: { _, _ in 0.1 })
        guard let card = cards.first(where: { $0.answer.lowercased() == "ubiquitin" }) else {
            XCTFail("expected a ubiquitin card")
            return
        }
        XCTAssertFalse(card.stem.lowercased().contains("ubiquitin"))
    }

    func testEmptyHighlightProducesNoCards() {
        let empty = ClozeSourceHighlight(id: "e", text: "", tags: [])
        XCTAssertTrue(ClozeGenerator.generate(from: empty, siblingHighlights: [], similarity: { _, _ in 0 }).isEmpty)
    }
}
