import XCTest
@testable import Cobux

/// Guards against the exact drift the plan called out about `BuildInfo`:
/// *"currently 2026-07-24 — the TestFlight countdown lies otherwise"*. The
/// version/build numbers here have to be kept in sync with `project.yml`'s
/// `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` by hand (there's no single
/// source of truth linking a Swift literal to a build-setting), so this
/// fails loudly the next time someone bumps one and forgets the other —
/// same self-failing-chore spirit as `RateTableTests.testPricingConstantsAreCurrent`.
final class BuildInfoTests: XCTestCase {
    func testNewestChangelogEntryMatchesCurrentShippedVersion() {
        // Mirrors project.yml's MARKETING_VERSION/CURRENT_PROJECT_VERSION —
        // update both together when bumping either.
        //
        // This assertion is NOT the real gate and must not be trusted as one.
        // It sat here asserting 2.5.21 / build 34 while builds 35 through 53
        // shipped, because this target needs a booted iOS Simulator and that
        // is a standing never-do-this on the machine Cobux is built on — so
        // the self-failing chore was never in a position to fail. A gate that
        // cannot run is worse than no gate: everyone believes it is watching.
        //
        // `scripts/check-version-sync.py` is the gate. It runs from ship.sh
        // before the archive, reads both files off disk so it cannot go stale,
        // and additionally enforces that the version string moves every build.
        // Keep these literals current anyway, so this says something true if
        // the suite is ever run somewhere it can be.
        let expectedVersion = "3.2.0"
        let expectedBuild = "58"

        guard let newest = BuildInfo.changelog.first else {
            XCTFail("BuildInfo.changelog is empty")
            return
        }
        XCTAssertEqual(newest.version, expectedVersion, "the newest changelog entry's version must match the currently shipped MARKETING_VERSION")
        XCTAssertEqual(newest.build, expectedBuild, "the newest changelog entry's build must match the currently shipped CURRENT_PROJECT_VERSION")
    }

    func testChangelogEntriesWithinAVersionAreOrderedNewestBuildFirst() {
        // ChangelogView renders this list top-to-bottom assuming newest-first.
        // Only compares consecutive entries that share a marketing version --
        // the build counter resets on every marketing version bump (2.0.0
        // starts back at build 1), so a global numeric sort across versions
        // isn't a meaningful invariant.
        var previous: (version: String, build: Int)?
        for entry in BuildInfo.changelog {
            let build = Int(entry.build) ?? -1
            if let previous, previous.version == entry.version {
                XCTAssertLessThan(build, previous.build, "\(entry.version) build \(entry.build) should sort after build \(previous.build) within the same version")
            }
            previous = (entry.version, build)
        }
    }

    func testEveryChangelogEntryHasAtLeastOneChange() {
        for entry in BuildInfo.changelog {
            XCTAssertFalse(entry.changes.isEmpty, "\(entry.version) (\(entry.build)) has no listed changes")
        }
    }
}
