import XCTest
import SwiftUI
import SnapshotTesting
@testable import Cobux

/// Phase 0's promised snapshot matrix ("the mechanism that catches the next
/// Robbins-class bug automatically") -- infra + real test cases, added here for the
/// first time. Covers `BookTitleText` (the exact component the Robbins overflow bug
/// lived in) at its shortest and longest real title, and `CobuxEmptyStateView`, each
/// across light and dark.
///
/// IMPORTANT, read before relying on this: these tests have never been run. This
/// machine has no iOS Simulator runtime installed at all (`xcrun simctl list runtimes`
/// returns nothing -- a known, pre-existing constraint for this whole project, not
/// specific to this change), and swift-snapshot-testing needs one to render a view and
/// record a reference image. The FIRST real run (on a machine/CI runner with a
/// simulator) will fail with "No reference was found on disk, automatically recorded"
/// and write PNGs under `Tests/__Snapshots__/SnapshotTests/` -- review those images,
/// commit them, and the suite goes green on every run after. Until that first real
/// run happens, treat this file as real, reviewed code that is NOT yet verified
/// end-to-end -- the same honesty standard this session has applied to every other
/// "build succeeded, never executed" case (no local simulator to run it against).
@MainActor
final class SnapshotTests: XCTestCase {

    private func assertLightAndDark<V: View>(
        _ view: V,
        named name: String,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        assertSnapshot(
            of: view, as: .image(layout: .device(config: .iPhone13)),
            named: "\(name)-light", file: file, testName: testName, line: line
        )
        assertSnapshot(
            of: view.preferredColorScheme(.dark), as: .image(layout: .device(config: .iPhone13)),
            named: "\(name)-dark", file: file, testName: testName, line: line
        )
    }

    func testBookTitleTextShortestRealTitle() {
        // "Sapiens" -- one of the shortest real seed-book titles.
        assertLightAndDark(
            BookTitleText(title: "Sapiens", font: .largeTitle, weight: .bold, expandsWidth: true)
                .padding(),
            named: "BookTitleText-short"
        )
    }

    func testBookTitleTextLongestRealTitleAtBoundedLineLimit() {
        // The exact string that caused the pre-2.0.0 Robbins overflow bug -- the whole
        // reason BookTitleText/lineLimit+minimumScaleFactor exists. If a future change
        // regresses that fix, this is the snapshot that should catch it.
        assertLightAndDark(
            BookTitleText(
                title: "Robbins & Cotran Pathologic Basis of Disease",
                font: .largeTitle, weight: .bold, lineLimit: 2, expandsWidth: true
            )
            .minimumScaleFactor(0.7)
            .padding(),
            named: "BookTitleText-longest"
        )
    }

    func testEmptyStateView() {
        assertLightAndDark(
            CobuxEmptyStateView(
                icon: "books.vertical",
                title: "Add your first book",
                message: "Start storing wisdom from your reading."
            ) {
                CobuxEmptyStateButton("Add Book") {}
            },
            named: "CobuxEmptyStateView"
        )
    }
}
