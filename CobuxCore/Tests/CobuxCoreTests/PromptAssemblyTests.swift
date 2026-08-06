import XCTest
@testable import CobuxCore

final class PromptAssemblyTests: XCTestCase {

    let library = [
        BookIndexEntry(title: "Attached", author: "Amir Levine", chapterTitles: ["Ch 1", "Ch 2"]),
        BookIndexEntry(title: "Robbins & Cotran Pathologic Basis of Disease", author: "Kumar, Abbas & Aster", chapterTitles: Array(1...29).map { "Ch \($0)" }),
    ]

    func testStablePrefixContainsChapterTitlesNotFullSummaries() {
        let prefix = PromptAssembly.stablePrefix(baseInstructions: "You are Cobux.", library: library)
        XCTAssertTrue(prefix.contains("Attached"))
        XCTAssertTrue(prefix.contains("29 chapters"))
        // The whole point of the fix: this must stay an INDEX, not full chapter content —
        // there is no summary text anywhere in the library fixture, so if this ever grew
        // large enough to contain prose beyond titles, that would be the regression.
        XCTAssertFalse(prefix.contains("hydrolases"), "stable prefix must never contain chapter summary prose")
    }

    func testStablePrefixAlwaysIncludesTheSourcesInstruction() {
        let prefix = PromptAssembly.stablePrefix(baseInstructions: "Base.", library: [])
        XCTAssertTrue(prefix.contains("<sources>"))
    }

    func testStablePrefixIsByteIdenticalAcrossCallsForCaching() {
        let a = PromptAssembly.stablePrefix(baseInstructions: "Base.", library: library)
        let b = PromptAssembly.stablePrefix(baseInstructions: "Base.", library: library)
        XCTAssertEqual(a, b, "must be byte-stable for Anthropic prompt caching to hit")
    }

    func testDynamicContextIncludesOnlyRankedSnippets() {
        let context = PromptAssembly.dynamicContext(rankedSnippets: [
            (bookTitle: "Attached", text: "Anxious attachment involves...")
        ])
        XCTAssertTrue(context.contains("Attached"))
        XCTAssertTrue(context.contains("Anxious attachment"))
    }

    func testDynamicContextHandlesNoMatches() {
        let context = PromptAssembly.dynamicContext(rankedSnippets: [])
        XCTAssertTrue(context.lowercased().contains("none matched"))
    }

    func testCacheableFloorHeuristic() {
        XCTAssertFalse(PromptAssembly.isLikelyCacheable(stablePrefix: "short"))
        let long = String(repeating: "a", count: 4000)
        XCTAssertTrue(PromptAssembly.isLikelyCacheable(stablePrefix: long))
    }
}
