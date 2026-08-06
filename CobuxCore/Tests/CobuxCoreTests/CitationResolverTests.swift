import XCTest
@testable import CobuxCore

final class CitationResolverTests: XCTestCase {

    func testParsesDeclaredTitlesAndStripsTag() {
        let raw = "Attachment theory suggests naming the anxiety directly.\n<sources>Attached</sources>"
        let parsed = CitationResolver.parse(rawReply: raw)
        XCTAssertEqual(parsed.displayText, "Attachment theory suggests naming the anxiety directly.")
        XCTAssertEqual(parsed.declaredTitles, ["Attached"])
    }

    func testParsesMultipleTitlesPipeDelimited() {
        let raw = "Some answer.\n<sources>Attached|The Value of Others</sources>"
        let parsed = CitationResolver.parse(rawReply: raw)
        XCTAssertEqual(parsed.declaredTitles, ["Attached", "The Value of Others"])
    }

    func testEmptySourcesTagYieldsNoTitles() {
        let raw = "General knowledge answer, no book used.\n<sources></sources>"
        let parsed = CitationResolver.parse(rawReply: raw)
        XCTAssertEqual(parsed.declaredTitles, [])
        XCTAssertEqual(parsed.displayText, "General knowledge answer, no book used.")
    }

    func testMissingTagIsHandledGracefully() {
        // Older cached responses or a model that forgets the instruction shouldn't crash —
        // just yield zero citations rather than a wrong guess from retrieval.
        let raw = "A reply with no sources tag at all."
        let parsed = CitationResolver.parse(rawReply: raw)
        XCTAssertEqual(parsed.displayText, raw)
        XCTAssertEqual(parsed.declaredTitles, [])
    }

    func testDeduplicatesCaseInsensitively() {
        let raw = "x\n<sources>Attached|attached|ATTACHED</sources>"
        let parsed = CitationResolver.parse(rawReply: raw)
        XCTAssertEqual(parsed.declaredTitles.count, 1)
    }

    // MARK: The actual bug this fixes — a hallucinated/wrong title never becomes a chip

    func testResolveDropsTitlesNotInLibrary() {
        let library = ["Attached", "12 Rules for Life", "Robbins & Cotran Pathologic Basis of Disease"]
        let resolved = CitationResolver.resolve(
            declaredTitles: ["Attached", "Essentials of Medical Microbiology"],
            libraryTitles: library
        )
        XCTAssertEqual(resolved, ["Attached"], "a title the model declares that isn't in the user's actual library must never surface as a chip")
    }

    func testResolveIsCaseInsensitiveButReturnsCanonicalLibraryCasing() {
        let library = ["Robbins & Cotran Pathologic Basis of Disease"]
        let resolved = CitationResolver.resolve(declaredTitles: ["robbins & cotran pathologic basis of disease"], libraryTitles: library)
        XCTAssertEqual(resolved, ["Robbins & Cotran Pathologic Basis of Disease"])
    }

    // MARK: The original incident, reproduced and fixed

    func testRelationshipQuestionNeverCitesMedicalBooksWhenModelDidntUseThem() {
        let raw = """
        Attachment theory suggests naming the anxiety directly rather than masking it — \
        "Attached" calls this the anxious-avoidant trap.
        <sources>Attached</sources>
        """
        let library = ["Attached", "The Value of Others", "Essentials of Medical Microbiology", "Robbins & Cotran Pathologic Basis of Disease"]
        let parsed = CitationResolver.parse(rawReply: raw)
        let resolved = CitationResolver.resolve(declaredTitles: parsed.declaredTitles, libraryTitles: library)
        XCTAssertEqual(resolved, ["Attached"])
        XCTAssertFalse(resolved.contains("Essentials of Medical Microbiology"))
        XCTAssertFalse(resolved.contains("Robbins & Cotran Pathologic Basis of Disease"))
    }
}
