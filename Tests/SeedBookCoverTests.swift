import XCTest
import UIKit
@testable import Cobux

/// The self-failing chore that makes cover-less seed books structurally
/// impossible to ship again.
///
/// Rajan has had to report missing book thumbnails after *multiple* separate
/// book batches — his words: "with every new addition of books, I have to
/// literally tell you again and again for the thumbnails... why the fuck do I
/// have to say this again and again?" The reason it kept recurring is that
/// nothing mechanical ever caught it:
///
///   1. `docs/adding-a-book.md` documented `coverColorHex` and
///      `coverImageURL` but never mentioned `coverAssetName` or bundling an
///      image at all — so the authoring process itself structurally produced
///      cover-less books.
///   2. No test looked at covers, so a batch shipped, rendered as a plain
///      gradient on device, and only a human noticed.
///
/// The §4 batch (7 books, build 24) shipped with six JSONs missing the field
/// entirely and a seventh (`pushingtothefront`) naming an imageset that didn't
/// exist. This test fails loudly on both of those shapes, so the next batch
/// can't repeat it — same spirit as `BuildInfoTests`' version-drift guard.
final class SeedBookCoverTests: XCTestCase {

    /// Every bundled seed book must declare a `coverAssetName`.
    func testEverySeedBookDeclaresACoverAssetName() throws {
        let books = try Self.seedBookJSONs()
        XCTAssertFalse(books.isEmpty, "no seed books found — the bundle lookup itself is broken")

        let missing = books
            .filter { ($0.json["coverAssetName"] as? String)?.isEmpty ?? true }
            .map(\.slug)
            .sorted()

        XCTAssertTrue(
            missing.isEmpty,
            """
            \(missing.count) seed book(s) have no `coverAssetName`, so they render as a \
            plain gradient instead of a cover: \(missing.joined(separator: ", ")).
            Fix: add "coverAssetName": "<slug>" to each JSON and bundle a matching \
            Cover-<slug>.imageset — see docs/adding-a-book.md step 8.
            """
        )
    }

    /// Declaring the name isn't enough — the asset has to actually resolve at
    /// runtime, which is the exact failure `pushingtothefront` shipped with.
    /// This mirrors `BookCard.loadCoverImage()`'s own `UIImage(named:)` check,
    /// so if this passes, the real render path resolves too.
    func testEveryDeclaredCoverAssetActuallyResolves() throws {
        let books = try Self.seedBookJSONs()

        let unresolvable = books.compactMap { book -> String? in
            guard let name = book.json["coverAssetName"] as? String, !name.isEmpty else { return nil }
            // Same "Cover-" prefix + Bundle(for:) lookup the app uses.
            return UIImage(named: "Cover-\(name)", in: Bundle(for: Self.self), compatibleWith: nil) == nil
                ? "\(book.slug) -> Cover-\(name)"
                : nil
        }.sorted()

        XCTAssertTrue(
            unresolvable.isEmpty,
            """
            \(unresolvable.count) seed book(s) name a cover asset that does not exist in \
            Assets.xcassets: \(unresolvable.joined(separator: ", ")). \
            A named-but-missing asset renders as a gradient exactly like no cover at all.
            """
        )
    }

    // MARK: - Helpers

    private struct SeedBookFile {
        let slug: String
        let json: [String: Any]
    }

    /// Reads the seed JSONs out of the built app bundle's `SeedBooks/`
    /// subdirectory — the same `subdirectory:` lookup `SeedLoader` uses, so
    /// this also implicitly guards the folder-reference-vs-group packaging bug
    /// that once flattened every JSON to the bundle root.
    private static func seedBookJSONs() throws -> [SeedBookFile] {
        let bundle = Bundle(for: SeedBookCoverTests.self)
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: "SeedBooks") ?? []
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            return SeedBookFile(
                slug: url.deletingPathExtension().lastPathComponent,
                json: object as? [String: Any] ?? [:]
            )
        }
    }
}
