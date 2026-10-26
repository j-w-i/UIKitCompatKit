//
//  AutoLayoutParityTests.swift
//  UIKitCompatKitTests
//
//  Parity suite: real UIKit Auto Layout vs the Cassowary-backed LegacyLayoutEngine.
//
//  UIKit side:   UIView + NSLayoutConstraint + layoutIfNeeded (UIKitFixtureRun).
//  Legacy side:  RRLayoutConstraint + LegacyLayoutEngine (LegacyFixtureRun, AutoLayoutParityHarness.swift).
//
//  Assertions (never weakened):
//    1. UIKit must reproduce the frames recorded as literals in the fixtures
//       (guards against simulator runtime drift).
//    2. The legacy engine must reproduce the same frames within 0.5 pt.
//
//  Every fixture is fully determined; `LayoutFixture.determinism` documents why. Ambiguous
//  systems are never used as parity cases because they legitimately have multiple solutions.
//

import XCTest
import UIKit
import LegacyAutoLayout

@MainActor
final class AutoLayoutParityTests: XCTestCase {

    // MARK: - Fixture sanity

    /// Guards the suite's own definition of "meaningful parity": enough cases, all fully
    /// determined and all with recorded UIKit literals for every item.
    func testFixtureCatalogueIsDeterminedAndComplete() {
        let fixtures = ParityFixtures.all
        XCTAssertGreaterThanOrEqual(fixtures.count, 15,
                                    "Definition of done requires at least 15 fully determined parity fixtures")

        for fixture in fixtures {
            XCTAssertFalse(fixture.name.isEmpty, "fixture must be named")
            XCTAssertFalse(fixture.determinism.isEmpty,
                           "fixture '\(fixture.name)' must document why its layout is fully determined")
            XCTAssertFalse(fixture.expectedFrames.isEmpty,
                           "fixture '\(fixture.name)' must record UIKit's expected frames")

            // Every item (including the container) must have a recorded frame; otherwise the
            // parity comparison could silently skip the item that matters.
            var itemIDs: [String] = []
            collectIDs(fixture.root, into: &itemIDs)
            for id in itemIDs {
                XCTAssertNotNil(fixture.expectedFrames[id],
                                "fixture '\(fixture.name)': missing recorded UIKit frame for item '\(id)'")
            }

            if let resize = fixture.resize {
                XCTAssertGreaterThan(resize.newContainerSize.width, 0)
                XCTAssertGreaterThan(resize.newContainerSize.height, 0)
                for id in itemIDs {
                    XCTAssertNotNil(resize.expectedFrames[id],
                                    "fixture '\(fixture.name)': missing recorded post-resize frame for item '\(id)'")
                }
            }

            // A fixture that references an unknown item would fail to build; make sure the
            // declaration is internally consistent before running UIKit.
            let declaredIDs = Set(itemIDs)
            for constraint in fixture.constraints {
                XCTAssertTrue(declaredIDs.contains(constraint.firstItemID),
                              "fixture '\(fixture.name)': constraint references unknown item '\(constraint.firstItemID)'")
                if let secondID = constraint.secondItemID {
                    XCTAssertTrue(declaredIDs.contains(secondID),
                                  "fixture '\(fixture.name)': constraint references unknown item '\(secondID)'")
                }
            }
        }
    }

    private func collectIDs(_ item: ItemSpec, into ids: inout [String]) {
        ids.append(item.id)
        for child in item.children {
            collectIDs(child, into: &ids)
        }
    }

    // MARK: - (a) UIKit reproduces the recorded literals

    /// The recorded literals must match the runtime simulator/OS: this catches version drift
    /// before it can be mis-attributed to the legacy engine.
    func testUIKitMatchesRecordedLiterals() {
        for fixture in ParityFixtures.all {
            let run = UIKitFixtureRun(fixture: fixture)
            let actual = run.layout()
            let problems = FrameCompare.mismatches(actual: actual, expected: fixture.expectedFrames)
            XCTAssertTrue(problems.isEmpty,
                          "UIKit does not reproduce recorded literals for fixture '\(fixture.name)':\n"
                            + problems.joined(separator: "\n"))
        }
    }

    /// Constraint removal on the UIKit side: after removing the identified constraint the
    /// recorded post-removal frames must be reproduced.
    func testUIKitMatchesRecordedLiteralsAfterConstraintRemoval() {
        for fixture in ParityFixtures.all {
            guard let removal = fixture.removal else { continue }
            let run = UIKitFixtureRun(fixture: fixture)
            _ = run.layout()
            run.applyRemoval()
            let actual = run.layout()
            let problems = FrameCompare.mismatches(actual: actual, expected: removal.expectedFrames)
            XCTAssertTrue(problems.isEmpty,
                          "UIKit does not reproduce post-removal literals for fixture '\(fixture.name)':\n"
                            + problems.joined(separator: "\n"))
        }
    }

    /// Autoresizing-mask resize: after the container is resized 320 -> 400 (or 480 -> 600), UIKit
    /// must regenerate the §3.1 equations and reproduce the recorded literals.
    func testUIKitMatchesRecordedLiteralsAfterAutoresizingResize() {
        var exercised = 0
        for fixture in ParityFixtures.all {
            guard let resize = fixture.resize else { continue }
            exercised += 1
            let run = UIKitFixtureRun(fixture: fixture)
            let before = run.layout()
            let beforeProblems = FrameCompare.mismatches(actual: before, expected: fixture.expectedFrames)
            XCTAssertTrue(beforeProblems.isEmpty,
                          "UIKit does not reproduce pre-resize literals for fixture '\(fixture.name)':\n"
                            + beforeProblems.joined(separator: "\n"))
            run.applyResize()
            let after = run.layout()
            let problems = FrameCompare.mismatches(actual: after, expected: resize.expectedFrames)
            XCTAssertTrue(problems.isEmpty,
                          "UIKit does not reproduce post-resize literals for fixture '\(fixture.name)':\n"
                            + problems.joined(separator: "\n"))
        }
        XCTAssertGreaterThanOrEqual(exercised, 5, "expected at least five autoresizing-resize fixtures")
    }

    // MARK: - (b) Legacy engine reproduces UIKit

    /// The core parity claim: for every fully determined fixture, the Cassowary-backed
    /// `LegacyLayoutEngine` must reproduce the frames that real UIKit produced (within 0.5 pt).
    func testLegacyMatchesRecordedUIKitLiterals() {
        for fixture in ParityFixtures.all {
            ParityHarness.assertLegacyMatchesRecordedUIKit(fixture)
        }
    }

    /// The legacy engine must match UIKit after a constraint is removed and the layout re-solved.
    func testLegacyConstraintRemovalParity() {
        var exercised = 0
        for fixture in ParityFixtures.all {
            guard fixture.removal != nil else { continue }
            exercised += 1
            ParityHarness.assertRemovalParity(fixture)
        }
        XCTAssertGreaterThan(exercised, 0, "at least one fixture must exercise constraint removal")
    }

    /// The engine must match UIKit through an autoresizing-mask resize (spec §3.1 equations
    /// regenerated from the first-pass reference frame + superview size).
    func testLegacyMatchesUIKitAfterAutoresizingResize() {
        var exercised = 0
        for fixture in ParityFixtures.all {
            guard fixture.resize != nil else { continue }
            exercised += 1
            ParityHarness.assertResizeParity(fixture)
        }
        XCTAssertGreaterThanOrEqual(exercised, 5, "expected at least five autoresizing-resize fixtures")
    }

    /// The engine's two public entry points must agree: `solve()` (no write-back) and
    /// `layout()` (write-back) must produce the same frames for every fixture.
    func testLegacyEngineSolveMatchesLayout() {
        for fixture in ParityFixtures.all {
            ParityHarness.assertSolveMatchesLayout(fixture)
        }
    }

    /// All required constraints in these fixtures are satisfiable (optional ones may be broken),
    /// so Auto Layout / the engine must not report any broken constraint.
    func testLegacyEngineReportsNoBrokenRequiredConstraints() {
        for fixture in ParityFixtures.all {
            let run = LegacyFixtureRun(fixture: fixture)
            let solved = run.solve()
            XCTAssertTrue(solved.brokenConstraints.isEmpty,
                          "fixture '\(fixture.name)': engine reported broken constraints "
                            + solved.brokenConstraints.map { String(describing: $0) }.joined(separator: ", "))
        }
    }

    // MARK: - Direction handling (RTL leading/trailing)

    /// RTL is wired in two places: UIKit derives it from `semanticContentAttribute`, the legacy
    /// engine from `RRLayoutDirection`. The same constraints must therefore produce the mirrored
    /// frame in RTL and the "unmirrored" frame in LTR.
    func testRTLLeadingTrailingParity() {
        guard let rtlFixture = ParityFixtures.all.first(where: { $0.direction == .rightToLeft }) else {
            XCTFail("catalogue must contain a right-to-left fixture")
            return
        }

        // The same constraints/literals under LTR: leading = 10 from the left, trailing = 270.
        let ltrFixture = LayoutFixture(
            name: "\(rtlFixture.name).forcedLTR",
            containerSize: rtlFixture.containerSize,
            root: rtlFixture.root,
            constraints: rtlFixture.constraints,
            expectedFrames: [
                "container": CGRect(x: 0, y: 0, width: 320, height: 480),
                "a": CGRect(x: 10, y: 10, width: 290, height: 50)
            ],
            determinism: "Same constraints as the RTL fixture but LTR: leading is the left edge.",
            direction: .leftToRight)

        // Recorded UIKit literals: RTL = (20, 10, 290, 50), LTR = (10, 10, 290, 50).
        let uiKitRTL = UIKitFixtureRun(fixture: rtlFixture).layout()
        let uiKitLTR = UIKitFixtureRun(fixture: ltrFixture).layout()
        XCTAssertEqual(uiKitRTL["a"]?.origin.x ?? .nan, 20, accuracy: 0.5,
                       "UIKit RTL leading/trailing should inset 10 from the right (x = 20)")
        XCTAssertEqual(uiKitLTR["a"]?.origin.x ?? .nan, 10, accuracy: 0.5,
                       "UIKit LTR leading/trailing should inset 10 from the left (x = 10)")
        XCTAssertEqual(uiKitRTL["a"]?.size.width ?? .nan, 290, accuracy: 0.5)
        XCTAssertEqual(uiKitLTR["a"]?.size.width ?? .nan, 290, accuracy: 0.5)

        let legacyRTL = LegacyFixtureRun(fixture: rtlFixture).layout()
        let legacyLTR = LegacyFixtureRun(fixture: ltrFixture).layout()
        let rtlProblems = FrameCompare.mismatches(actual: legacyRTL, expected: uiKitRTL)
        let ltrProblems = FrameCompare.mismatches(actual: legacyLTR, expected: uiKitLTR)
        XCTAssertTrue(rtlProblems.isEmpty,
                      "Legacy RTL frames disagree with UIKit:\n" + rtlProblems.joined(separator: "\n"))
        XCTAssertTrue(ltrProblems.isEmpty,
                      "Legacy LTR frames disagree with UIKit:\n" + ltrProblems.joined(separator: "\n"))
    }

    // MARK: - Seeded randomized suite

    /// Seeded, deterministic set of pinned/centred/proportional layouts: UIKit and the legacy
    /// engine must produce identical frames for every one of them.
    func testLegacyMatchesUIKitRandomized() {
        let fixtures = ParityFixtures.randomized(count: 60, seed: 0x5EED_1234)
        XCTAssertEqual(fixtures.count, 60)

        var checked = 0
        for fixture in fixtures {
            let uiKitFrames = UIKitFixtureRun(fixture: fixture).layout()
            let legacyFrames = LegacyFixtureRun(fixture: fixture).layout()

            // UIKit must agree with the analytically computed frames.
            let uiKitProblems = FrameCompare.mismatches(actual: uiKitFrames, expected: fixture.expectedFrames)
            XCTAssertTrue(uiKitProblems.isEmpty,
                          "UIKit disagrees with computed frames for randomized fixture '\(fixture.name)':\n"
                            + uiKitProblems.joined(separator: "\n"))

            // Legacy must agree with UIKit.
            let parityProblems = FrameCompare.mismatches(actual: legacyFrames, expected: uiKitFrames)
            XCTAssertTrue(parityProblems.isEmpty,
                          "Legacy engine disagrees with UIKit for randomized fixture '\(fixture.name)':\n"
                            + parityProblems.joined(separator: "\n"))
            checked += 1
        }
        XCTAssertEqual(checked, 60)
    }

    /// Same seed => same fixtures (guards the randomized suite against nondeterminism).
    func testSeededRandomizedFixturesAreDeterministic() {
        let first = ParityFixtures.randomized(count: 25, seed: 0xC0FF_EE01)
        let second = ParityFixtures.randomized(count: 25, seed: 0xC0FF_EE01)
        XCTAssertEqual(first.count, second.count)
        for (left, right) in zip(first, second) {
            XCTAssertEqual(left.name, right.name)
            XCTAssertEqual(left.containerSize, right.containerSize)
            XCTAssertEqual(left.constraints.count, right.constraints.count)
            XCTAssertEqual(left.expectedFrames, right.expectedFrames)
        }
    }

    // MARK: - Constraint model / bridge conformance (independent checks)

    /// `RRLayoutAttribute`/`RRLayoutRelation`/`RRLayoutPriority` must mirror UIKit exactly
    /// (nib and archive compatibility depends on the raw values).
    func testConstraintModelRawValuesMatchUIKit() {
        let attributeProblems = ConstraintModelParity.attributeMismatches()
        XCTAssertTrue(attributeProblems.isEmpty, attributeProblems.joined(separator: "\n"))

        let relationProblems = ConstraintModelParity.relationMismatches()
        XCTAssertTrue(relationProblems.isEmpty, relationProblems.joined(separator: "\n"))

        let priorityProblems = ConstraintModelParity.priorityMismatches()
        XCTAssertTrue(priorityProblems.isEmpty, priorityProblems.joined(separator: "\n"))
    }

    // MARK: - Subtree-pass stability (legacy engine only)

    /// A layout pass rooted at an inner view ignores constraints owned by ancestors (that is the
    /// documented subtree rule), so those items become under-constrained. The engine's weak "stay"
    /// constraints must keep their current frames instead of collapsing them; otherwise laying out a
    /// subtree would destroy geometry established by the full pass.
    func testSubtreeLayoutPassKeepsAncestorDerivedFrames() {
        guard let fixture = ParityFixtures.all.first(where: { $0.name == "nestedViews" }) else {
            XCTFail("nestedViews fixture missing")
            return
        }

        let run = LegacyFixtureRun(fixture: fixture)
        let fullFrames = run.layout()
        guard let outerView = run.views["outer"] else {
            XCTFail("outer view missing")
            return
        }

        // A second pass rooted at `outer` must not move the subtree.
        let engine = LegacyLayoutEngine(direction: .leftToRight)
        engine.layout(outerView)
        let framesAfterSubtreePass = run.absoluteFramesFromViews()

        let subtreeIDs = ["outer", "inner", "g"]
        let expected = fullFrames.filter { subtreeIDs.contains($0.key) }
        let actual = framesAfterSubtreePass.filter { subtreeIDs.contains($0.key) }
        let problems = FrameCompare.mismatches(actual: actual, expected: expected)
        XCTAssertTrue(problems.isEmpty,
                      "subtree layout pass moved ancestor-derived frames:\n" + problems.joined(separator: "\n"))
    }

    /// The legacy parity relies on UIView's `LegacyLayoutItem` conformance reading the legacy
    /// storage (constraints, translatesAutoresizing bit, intrinsic size, hugging/compression).
    /// Verify that independently of the engine, so a bridge regression is reported as a bridge bug.
    func testUIViewLegacyLayoutItemConformance() {
        let problems = UIViewConformanceParity.mismatches()
        XCTAssertTrue(problems.isEmpty,
                      "UIView LegacyLayoutItem conformance is out of sync with the legacy storage:\n"
                        + problems.joined(separator: "\n"))
    }
}
