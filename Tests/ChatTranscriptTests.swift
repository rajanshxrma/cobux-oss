import XCTest
@testable import Cobux

/// Guards copy and share.
///
/// The failure these prevent is not cosmetic: he copies a reply to send to a
/// real person, and it arrives full of `**asterisks**` and `> ` markers, or
/// three separate candidate replies arrive fused into one unusable block.
final class ChatTranscriptTests: XCTestCase {
    func testPlainTextCarriesNoMarkdownMachinery() {
        let src = "Here is **the point**, plainly.\n\n> Send this one back to her.\n\nAnd a *closing* line."
        let plain = ChatTranscript.plainText(src)
        XCTAssertFalse(plain.contains("**"), "asterisks must not reach a real person's messages")
        XCTAssertFalse(plain.contains("> "), "quote markers must not survive either")
        XCTAssertTrue(plain.contains("the point"))
        XCTAssertTrue(plain.contains("Send this one back to her."))
    }

    /// The rule that keeps several candidate replies separately copyable.
    func testABareQuoteMarkerEndsTheQuote() {
        let blocks = ChatTranscript.blocks(in: "> first option\n>\n> second option")
        XCTAssertEqual(blocks.filter(\.isQuote).count, 2,
                       "two candidates stay two blocks, not one fused card")
    }

    func testAMultiLinePassageStaysOneBlock() {
        let blocks = ChatTranscript.blocks(in: "> a passage that runs\n> across two lines")
        XCTAssertEqual(blocks.filter(\.isQuote).count, 1)
    }

    /// He copies counsel to send to a person. An app signature under it makes
    /// his words read as the app's.
    func testNoWatermarkIsAppended() {
        XCTAssertEqual(
            ChatTranscript.plainText("Just a line.")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "Just a line.")
    }
}
