//
//  AutoLayoutParityHarness.swift
//  UIKitCompatKitTests
//
//  Legacy side of the parity harness: builds the *same* fixture hierarchy as
//  `UIKitFixtureRun` but drives it through `RRLayoutConstraint` + `LegacyLayoutEngine`
//  (UIKit-independent engine, UIView conformance supplied by the UIKit bridge).
//
//  It also contains the independent checks of the UIKit bridge conformance itself
//  (`LegacyLayoutItem` on UIView) and the attribute/relation raw-value parity check, so a
//  bridge that silently ignores `legacy*` properties cannot hide behind green engine tests.
//

import XCTest
import UIKit
import LegacyAutoLayout

// MARK: - Attribute / relation / direction mapping

/// Explicit (not raw-value based) mapping between UIKit's constraint model and the legacy port.
/// The raw-value parity test below verifies that the port's values really match UIKit's.
enum LegacyModelBridge {

    static func attribute(_ attribute: NSLayoutConstraint.Attribute) -> RRLayoutAttribute {
        switch attribute {
        case .notAnAttribute: return .notAnAttribute
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        case .width: return .width
        case .height: return .height
        case .centerX: return .centerX
        case .centerY: return .centerY
        case .lastBaseline: return .lastBaseline
        case .firstBaseline: return .firstBaseline
        case .leftMargin, .rightMargin, .topMargin, .bottomMargin,
             .leadingMargin, .trailingMargin, .centerXWithinMargins, .centerYWithinMargins:
            fatalError("Margin attributes are not part of the legacy (iOS 6) model; fixtures must not use them")
        @unknown default:
            fatalError("Unsupported NSLayoutConstraint.Attribute \(attribute.rawValue) in parity fixture")
        }
    }

    static func attribute(_ attribute: RRLayoutAttribute) -> NSLayoutConstraint.Attribute {
        switch attribute {
        case .notAnAttribute: return .notAnAttribute
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        case .width: return .width
        case .height: return .height
        case .centerX: return .centerX
        case .centerY: return .centerY
        case .lastBaseline: return .lastBaseline
        case .firstBaseline: return .firstBaseline
        }
    }

    static func relation(_ relation: FixtureRelation) -> RRLayoutRelation {
        switch relation {
        case .lessThanOrEqual: return .lessThanOrEqual
        case .equal: return .equal
        case .greaterThanOrEqual: return .greaterThanOrEqual
        }
    }

    static func direction(_ direction: FixtureDirection) -> RRLayoutDirection {
        switch direction {
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        }
    }
}

// MARK: - Legacy fixture runner

/// Builds a real `UIView` tree for a fixture, installs the constraints through the legacy
/// (RRAutoLayout) API and lays the tree out with `LegacyLayoutEngine`.
///
/// The views are real UIViews on purpose: this exercises the UIView `LegacyLayoutItem`
/// conformance (constraint storage, translatesAutoresizing bit, intrinsic-size storage,
/// hugging/compression priorities, frame write-back) rather than a fake tree, so the parity
/// test verifies the whole legacy path, not just the solver.
@MainActor
final class LegacyFixtureRun {
    let fixture: LayoutFixture
    let rootView: UIView
    let views: [String: UIView]
    let engine: LegacyLayoutEngine
    /// Constraints installed in phase 1, in fixture order (parallel to `fixture.activeConstraints`).
    private(set) var installedConstraints: [RRLayoutConstraint] = []

    init(fixture: LayoutFixture) {
        self.fixture = fixture
        self.engine = LegacyLayoutEngine(direction: LegacyModelBridge.direction(fixture.direction))

        var builtViews: [String: UIView] = [:]
        let rootView = LegacyFixtureRun.buildView(for: fixture.root, into: &builtViews)
        self.rootView = rootView
        self.views = builtViews

        rootView.frame = CGRect(origin: .zero, size: fixture.containerSize)
        rootView.legacyTranslatesAutoresizingMaskIntoConstraints = fixture.root.translatesAutoresizingMaskIntoConstraints

        for spec in fixture.activeConstraints {
            let constraint = LegacyFixtureRun.makeConstraint(spec, views: builtViews)
            installedConstraints.append(constraint)
            rootView.legacyAddConstraint(constraint)
        }
    }

    // MARK: Building

    private static func buildView(for spec: ItemSpec, into views: inout [String: UIView]) -> UIView {
        let view = FixtureIntrinsicView(frame: spec.initialFrame)
        view.fixtureIntrinsicContentSize = spec.intrinsicContentSize ?? CGSize(width: UIView.noIntrinsicMetric,
                                                                              height: UIView.noIntrinsicMetric)
        // Drive the legacy path exclusively through the legacy storage: the engine's UIView
        // conformance is documented to read these properties (docs/legacy-autolayout.md §6).
        view.autoresizingMask = spec.autoresizingMask
        view.legacyTranslatesAutoresizingMaskIntoConstraints = spec.translatesAutoresizingMaskIntoConstraints
        view.legacyIntrinsicContentSize = spec.intrinsicContentSize ?? CGSize(width: UIView.noIntrinsicMetric,
                                                                              height: UIView.noIntrinsicMetric)
        view.legacySetContentHuggingPriority(spec.horizontalHuggingPriority, for: .horizontal)
        view.legacySetContentCompressionResistancePriority(spec.horizontalCompressionResistancePriority, for: .horizontal)
        view.legacySetContentHuggingPriority(spec.verticalHuggingPriority, for: .vertical)
        view.legacySetContentCompressionResistancePriority(spec.verticalCompressionResistancePriority, for: .vertical)

        views[spec.id] = view
        for child in spec.children {
            let childView = buildView(for: child, into: &views)
            view.addSubview(childView)
        }
        return view
    }

    private static func makeConstraint(_ spec: ConstraintSpec, views: [String: UIView]) -> RRLayoutConstraint {
        let firstItem = views[spec.firstItemID]
        let secondItem = spec.secondItemID.flatMap { views[$0] }
        let constraint = RRLayoutConstraint(item: firstItem as Any,
                                            attribute: LegacyModelBridge.attribute(spec.firstAttribute),
                                            relatedBy: LegacyModelBridge.relation(spec.relation),
                                            toItem: secondItem,
                                            attribute: LegacyModelBridge.attribute(spec.secondAttribute),
                                            multiplier: spec.multiplier,
                                            constant: spec.constant)
        constraint.priority = spec.priority
        constraint.identifier = spec.identifier
        return constraint
    }

    // MARK: Running

    /// Runs `LegacyLayoutEngine.layout` and returns absolute frames in container coordinates.
    func layout() -> [String: CGRect] {
        engine.layout(rootView)
        return absoluteFramesFromViews()
    }

    /// Runs `LegacyLayoutEngine.solve` (no frame write-back) and returns absolute frames.
    func solve() -> (frames: [String: CGRect], brokenConstraints: [RRLayoutConstraint]) {
        let result = engine.solve(rootView)
        return (absoluteFrames(from: result.frames), result.brokenConstraints)
    }

    /// Deactivates the constraints listed by `fixture.removal` through the legacy API.
    func applyRemoval() {
        guard let removal = fixture.removal else { return }
        let identifiers = Set(removal.removeConstraintIdentifiers)
        var kept: [RRLayoutConstraint] = []
        for constraint in installedConstraints {
            if let identifier = constraint.identifier, identifiers.contains(identifier) {
                rootView.legacyRemoveConstraint(constraint)
            } else {
                kept.append(constraint)
            }
        }
        installedConstraints = kept
    }

    /// Resizes the container so the engine must regenerate the autoresizing-mask equations from the
    /// reference captured in the first pass (spec §3.1).
    func applyResize() {
        guard let resize = fixture.resize else { return }
        rootView.frame = CGRect(origin: .zero, size: resize.newContainerSize)
    }

    /// Real UIView frames in container coordinates (engine wrote them via `layoutSetFrame`).
    func absoluteFramesFromViews() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for (id, view) in views {
            result[id] = rootView.convert(view.bounds, from: view)
        }
        return result
    }

    /// Converts engine frames (superitem coordinates) to container coordinates.
    private func absoluteFrames(from engineFrames: [ObjectIdentifier: CGRect]) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        var rootFrame = engineFrames[ObjectIdentifier(rootView)] ?? rootView.frame
        // Engine contract: root frame is included unchanged; normalise to the container origin
        // so the comparison is in the same coordinate space as the UIKit side.
        rootFrame.origin = .zero
        result[fixture.root.id] = rootFrame
        for child in fixture.root.children {
            appendAbsoluteFrames(child, parentAbsoluteOrigin: .zero, engineFrames: engineFrames, into: &result)
        }
        return result
    }

    private func appendAbsoluteFrames(_ spec: ItemSpec,
                                      parentAbsoluteOrigin: CGPoint,
                                      engineFrames: [ObjectIdentifier: CGRect],
                                      into result: inout [String: CGRect]) {
        guard let view = views[spec.id] else { return }
        let frame = engineFrames[ObjectIdentifier(view)] ?? view.frame
        let absolute = CGRect(x: parentAbsoluteOrigin.x + frame.origin.x,
                              y: parentAbsoluteOrigin.y + frame.origin.y,
                              width: frame.size.width,
                              height: frame.size.height)
        result[spec.id] = absolute
        for child in spec.children {
            appendAbsoluteFrames(child,
                                 parentAbsoluteOrigin: absolute.origin,
                                 engineFrames: engineFrames,
                                 into: &result)
        }
    }
}

// MARK: - Parity assertion helpers

@MainActor
enum ParityHarness {

    static func uiKitFrames(_ fixture: LayoutFixture) -> [String: CGRect] {
        return UIKitFixtureRun(fixture: fixture).layout()
    }

    static func legacyFrames(_ fixture: LayoutFixture) -> [String: CGRect] {
        return LegacyFixtureRun(fixture: fixture).layout()
    }

    /// Asserts the legacy engine reproduces the recorded UIKit literals within 0.5 pt.
    static func assertLegacyMatchesRecordedUIKit(_ fixture: LayoutFixture,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        let actual = legacyFrames(fixture)
        let problems = FrameCompare.mismatches(actual: actual, expected: fixture.expectedFrames)
        XCTAssertTrue(problems.isEmpty,
                      "Legacy engine disagrees with recorded UIKit frames for fixture '\(fixture.name)':\n"
                        + problems.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// Asserts phase 2 (constraint removal + re-solve) parity.
    static func assertRemovalParity(_ fixture: LayoutFixture,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        guard let removal = fixture.removal else {
            XCTFail("fixture '\(fixture.name)' has no removal phase", file: file, line: line)
            return
        }

        // UIKit side.
        let uiKitRun = UIKitFixtureRun(fixture: fixture)
        _ = uiKitRun.layout()
        uiKitRun.applyRemoval()
        let uiKitFramesAfter = uiKitRun.layout()

        // Legacy side.
        let legacyRun = LegacyFixtureRun(fixture: fixture)
        _ = legacyRun.layout()
        legacyRun.applyRemoval()
        let legacyFramesAfter = legacyRun.layout()

        let expectedProblems = FrameCompare.mismatches(actual: uiKitFramesAfter, expected: removal.expectedFrames)
        XCTAssertTrue(expectedProblems.isEmpty,
                      "UIKit does not reproduce post-removal literals for fixture '\(fixture.name)':\n"
                        + expectedProblems.joined(separator: "\n"),
                      file: file, line: line)

        let parityProblems = FrameCompare.mismatches(actual: legacyFramesAfter, expected: removal.expectedFrames)
        XCTAssertTrue(parityProblems.isEmpty,
                      "Legacy engine disagrees with recorded UIKit frames after constraint removal for fixture '\(fixture.name)':\n"
                        + parityProblems.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// Asserts autoresizing-mask resize parity: after resizing the container, UIKit and the legacy
    /// engine must both regenerate the §3.1 equations from the first-pass reference and agree with
    /// the recorded literals.
    static func assertResizeParity(_ fixture: LayoutFixture,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        guard let resize = fixture.resize else {
            XCTFail("fixture '\(fixture.name)' has no resize phase", file: file, line: line)
            return
        }

        // UIKit side.
        let uiKitRun = UIKitFixtureRun(fixture: fixture)
        let uiKitBefore = uiKitRun.layout()
        let beforeProblems = FrameCompare.mismatches(actual: uiKitBefore, expected: fixture.expectedFrames)
        XCTAssertTrue(beforeProblems.isEmpty,
                      "UIKit does not reproduce pre-resize literals for fixture '\(fixture.name)':\n"
                        + beforeProblems.joined(separator: "\n"),
                      file: file, line: line)
        uiKitRun.applyResize()
        let uiKitAfter = uiKitRun.layout()

        // Legacy side.
        let legacyRun = LegacyFixtureRun(fixture: fixture)
        let legacyBefore = legacyRun.layout()
        let legacyBeforeProblems = FrameCompare.mismatches(actual: legacyBefore, expected: fixture.expectedFrames)
        XCTAssertTrue(legacyBeforeProblems.isEmpty,
                      "Legacy engine does not reproduce pre-resize literals for fixture '\(fixture.name)':\n"
                        + legacyBeforeProblems.joined(separator: "\n"),
                      file: file, line: line)
        legacyRun.applyResize()
        let legacyAfter = legacyRun.layout()

        let literalProblems = FrameCompare.mismatches(actual: uiKitAfter, expected: resize.expectedFrames)
        XCTAssertTrue(literalProblems.isEmpty,
                      "UIKit does not reproduce post-resize literals for fixture '\(fixture.name)':\n"
                        + literalProblems.joined(separator: "\n"),
                      file: file, line: line)

        let parityProblems = FrameCompare.mismatches(actual: legacyAfter, expected: uiKitAfter)
        XCTAssertTrue(parityProblems.isEmpty,
                      "Legacy engine disagrees with UIKit after autoresizing resize for fixture '\(fixture.name)':\n"
                        + parityProblems.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// Asserts `solve()` (no write-back) and `layout()` (write-back) produce the same frame set,
    /// i.e. the engine's two public entry points are consistent.
    static func assertSolveMatchesLayout(_ fixture: LayoutFixture,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let run = LegacyFixtureRun(fixture: fixture)
        let layoutFrames = run.layout()
        let solved = run.solve()
        let problems = FrameCompare.mismatches(actual: solved.frames, expected: layoutFrames)
        XCTAssertTrue(problems.isEmpty,
                      "Legacy engine solve()/layout() disagree for fixture '\(fixture.name)':\n"
                        + problems.joined(separator: "\n"),
                      file: file, line: line)
    }
}

// MARK: - Constraint-model raw value parity

/// The port must be nib/archive-compatible: raw values have to match UIKit exactly.
enum ConstraintModelParity {
    static func attributeMismatches() -> [String] {
        var lines: [String] = []
        let allUIKitAttributes: [NSLayoutConstraint.Attribute] = [
            .notAnAttribute, .left, .right, .top, .bottom, .leading, .trailing,
            .width, .height, .centerX, .centerY, .lastBaseline, .firstBaseline
        ]
        for attribute in allUIKitAttributes {
            let expected = LegacyModelBridge.attribute(attribute)
            if let rrAttribute = RRLayoutAttribute(rawValue: attribute.rawValue) {
                if rrAttribute != expected {
                    lines.append("RRLayoutAttribute(rawValue: \(attribute.rawValue)) is \(rrAttribute), expected \(expected) for UIKit attribute \(attribute.rawValue)")
                }
            } else {
                lines.append("RRLayoutAttribute has no case for UIKit attribute raw value \(attribute.rawValue)")
            }
        }
        if RRLayoutAttribute.allCases.count != allUIKitAttributes.count {
            lines.append("RRLayoutAttribute.allCases.count = \(RRLayoutAttribute.allCases.count), expected \(allUIKitAttributes.count)")
        }
        for attribute in RRLayoutAttribute.allCases {
            let uikitAttribute = LegacyModelBridge.attribute(attribute)
            if uikitAttribute.rawValue != attribute.rawValue {
                lines.append("RRLayoutAttribute.\(attribute) rawValue \(attribute.rawValue) != UIKit \(uikitAttribute.rawValue)")
            }
        }
        return lines
    }

    static func relationMismatches() -> [String] {
        var lines: [String] = []
        let pairs: [(FixtureRelation, NSLayoutConstraint.Relation)] = [
            (.lessThanOrEqual, .lessThanOrEqual),
            (.equal, .equal),
            (.greaterThanOrEqual, .greaterThanOrEqual)
        ]
        for (fixtureRelation, uiKitRelation) in pairs {
            let rrRelation = LegacyModelBridge.relation(fixtureRelation)
            if rrRelation.rawValue != uiKitRelation.rawValue {
                lines.append("RRLayoutRelation(\(rrRelation)) rawValue \(rrRelation.rawValue) != UIKit \(uiKitRelation.rawValue)")
            }
        }
        return lines
    }

    static func priorityMismatches() -> [String] {
        var lines: [String] = []
        if RRLayoutPriorityValue.required != 1000 { lines.append("required priority is \(RRLayoutPriorityValue.required), expected 1000") }
        if RRLayoutPriorityValue.defaultHigh != 750 { lines.append("defaultHigh priority is \(RRLayoutPriorityValue.defaultHigh), expected 750") }
        if RRLayoutPriorityValue.defaultLow != 250 { lines.append("defaultLow priority is \(RRLayoutPriorityValue.defaultLow), expected 250") }
        if RRLayoutPriorityValue.fittingSizeLevel != 50 { lines.append("fittingSizeLevel priority is \(RRLayoutPriorityValue.fittingSizeLevel), expected 50") }
        return lines
    }
}

// MARK: - UIView `LegacyLayoutItem` conformance check

/// Independent checks that the UIKit bridge's `LegacyLayoutItem` conformance reflects the legacy
/// storage (so the engine never reads stale UIKit state). This is intentionally separate from the
/// engine parity tests: it fails fast when the bridge drops a property the fixtures rely on.
@MainActor
enum UIViewConformanceParity {

    static func mismatches() -> [String] {
        var lines: [String] = []
        let view = FixtureIntrinsicView(frame: CGRect(x: 3, y: 4, width: 50, height: 60))
        let child = FixtureIntrinsicView(frame: CGRect(x: 1, y: 2, width: 10, height: 20))
        view.addSubview(child)

        let item: LegacyLayoutItem = view
        let childItem: LegacyLayoutItem = child
        if item.layoutFrame != view.frame {
            lines.append("UIView.layoutFrame \(item.layoutFrame) != UIView.frame \(view.frame)")
        }
        if childItem.layoutSuperitem !== view {
            lines.append("child.layoutSuperitem is not its superview")
        }
        if item.layoutSuperitem != nil {
            lines.append("root view.layoutSuperitem should be nil, got \(String(describing: item.layoutSuperitem))")
        }
        if item.layoutSubitems.count != 1 || item.layoutSubitems.first !== child {
            lines.append("UIView.layoutSubitems does not match subviews")
        }

        view.legacyTranslatesAutoresizingMaskIntoConstraints = false
        if item.layoutTranslatesAutoresizingMaskIntoConstraints != false {
            lines.append("layoutTranslatesAutoresizingMaskIntoConstraints does not reflect legacyTranslatesAutoresizingMaskIntoConstraints")
        }
        view.legacyTranslatesAutoresizingMaskIntoConstraints = true
        if item.layoutTranslatesAutoresizingMaskIntoConstraints != true {
            lines.append("layoutTranslatesAutoresizingMaskIntoConstraints does not reflect legacyTranslatesAutoresizingMaskIntoConstraints (true)")
        }

        let intrinsic = CGSize(width: 120, height: 40)
        view.legacyIntrinsicContentSize = intrinsic
        if item.layoutIntrinsicContentSize != intrinsic {
            lines.append("layoutIntrinsicContentSize \(item.layoutIntrinsicContentSize) != legacyIntrinsicContentSize \(intrinsic)")
        }

        view.legacySetContentHuggingPriority(333, for: .horizontal)
        if item.layoutContentHuggingPriority(for: .horizontal) != 333 {
            lines.append("horizontal hugging priority does not reflect legacySetContentHuggingPriority")
        }
        view.legacySetContentCompressionResistancePriority(777, for: .vertical)
        if item.layoutContentCompressionResistancePriority(for: .vertical) != 777 {
            lines.append("vertical compression priority does not reflect legacySetContentCompressionResistancePriority")
        }

        let constraint = RRLayoutConstraint(item: child,
                                            attribute: .width,
                                            relatedBy: .equal,
                                            toItem: nil,
                                            attribute: .notAnAttribute,
                                            multiplier: 1,
                                            constant: 10)
        view.legacyAddConstraint(constraint)
        if item.layoutConstraints.count != 1 || item.layoutConstraints.first !== constraint {
            lines.append("layoutConstraints does not expose constraints added with legacyAddConstraint")
        }
        view.legacyRemoveConstraint(constraint)
        if !item.layoutConstraints.isEmpty {
            lines.append("layoutConstraints still contains a constraint removed with legacyRemoveConstraint")
        }
        return lines
    }
}
