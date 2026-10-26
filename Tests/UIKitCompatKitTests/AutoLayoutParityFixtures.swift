//
//  AutoLayoutParityFixtures.swift
//  UIKitCompatKitTests
//
//  Declarative fixtures for the UIKit-vs-LegacyAutoLayout parity suite.
//
//  Each fixture describes a *fully determined* layout: a container (fixed size), a tree of
//  items (initial frames, `translatesAutoresizingMaskIntoConstraints`, intrinsic content size,
//  content hugging / compression resistance priorities) and a flat list of constraints.
//
//  The same fixture is executed twice:
//    1. with real UIKit (`UIView` + `NSLayoutConstraint` + `layoutIfNeeded`) — `UIKitFixtureRun`
//       in this file;
//    2. with `RRLayoutConstraint` + `LegacyLayoutEngine` (see `AutoLayoutParityHarness.swift`).
//
//  `expectedFrames` are literals recorded from real UIKit on iOS 27 (iPhone SE (3rd gen)
//  simulator), expressed in *container* coordinates (so nested views can be compared directly).
//  The parity test asserts that UIKit still reproduces these literals (guarding against simulator
//  / OS version drift) and that the legacy engine reproduces them within 0.5 pt.
//
//  Every fixture documents *why* its layout is fully determined: ambiguous (under-constrained)
//  systems can legitimately have multiple valid solutions, so they must never be parity cases.
//
//  Coverage (31 static fixtures + 60 seeded randomized cases):
//    pinned edges, fixed sizes, equal width/height between siblings, multiplier relationships
//    (width = 0.5 * container.width, +constant, width = 2 * height), centering, required
//    inequalities (slack + binding), priority conflicts (required cap vs @750), intrinsic content
//    hugging/compression (single label + 800-vs-750 compression split), autoresizing masks
//    (static frame + five mask shapes through a 320->400 / 480->600 resize), RTL leading/trailing
//    (flat, nested, mixed with centerX, and RTL inequalities), nested views, a constraint owned by
//    the common ancestor but referencing grandchildren in different branches, and constraint
//    removal + re-solve.
//
//  Deliberately NOT parity cases:
//    * baseline alignment: a plain UIView has no baseline provider (UIKit derives baselines from
//      content; /tmp/autolayout-semantics.md §2.5), so there is no deterministic UIKit baseline
//      to compare against without a custom content view; the engine's baseline support is
//      exercised by layout-core-dev's engine tests instead.
//    * required-vs-required conflicts: UIKit's choice among unsatisfiable required constraints is
//      unspecified ("usually the one with the smaller constant wins"), so it cannot be a parity
//      guarantee; only a required constraint vs an optional one is used above.
//

import UIKit

// MARK: - Relation

/// Mirror of `NSLayoutConstraint.Relation` with UIKit's raw values.
enum FixtureRelation: Int {
    case lessThanOrEqual = -1
    case equal = 0
    case greaterThanOrEqual = 1

    var uiKitRelation: NSLayoutConstraint.Relation {
        switch self {
        case .lessThanOrEqual: return .lessThanOrEqual
        case .equal: return .equal
        case .greaterThanOrEqual: return .greaterThanOrEqual
        }
    }
}

// MARK: - Constraint specification

/// One declarative constraint: `firstItem.firstAttribute <relation> multiplier * secondItem.secondAttribute + constant`.
///
/// `secondItemID == nil` means a constant constraint (`constant` is compared against the attribute
/// directly, e.g. `width == 100`).
struct ConstraintSpec {
    var firstItemID: String
    var firstAttribute: NSLayoutConstraint.Attribute
    var relation: FixtureRelation
    var secondItemID: String?
    var secondAttribute: NSLayoutConstraint.Attribute
    var multiplier: CGFloat
    var constant: CGFloat
    /// UIKit `NSLayoutPriority` value (1000 = required, 750 = default high, 250 = default low).
    var priority: Float
    var identifier: String?
    /// When false the constraint is never installed (used to describe the "after removal" state).
    var isActive: Bool

    init(firstItemID: String,
         firstAttribute: NSLayoutConstraint.Attribute,
         relation: FixtureRelation = .equal,
         secondItemID: String? = nil,
         secondAttribute: NSLayoutConstraint.Attribute = .notAnAttribute,
         multiplier: CGFloat = 1,
         constant: CGFloat = 0,
         priority: Float = 1000,
         identifier: String? = nil,
         isActive: Bool = true) {
        self.firstItemID = firstItemID
        self.firstAttribute = firstAttribute
        self.relation = relation
        self.secondItemID = secondItemID
        self.secondAttribute = secondAttribute
        self.multiplier = multiplier
        self.constant = constant
        self.priority = priority
        self.identifier = identifier
        self.isActive = isActive
    }

    // MARK: Convenience constructors (keep fixture declarations readable)

    static func equal(_ firstItemID: String,
                      _ firstAttribute: NSLayoutConstraint.Attribute,
                      _ secondItemID: String,
                      _ secondAttribute: NSLayoutConstraint.Attribute,
                      multiplier: CGFloat = 1,
                      constant: CGFloat = 0,
                      priority: Float = 1000,
                      identifier: String? = nil) -> ConstraintSpec {
        return ConstraintSpec(firstItemID: firstItemID,
                              firstAttribute: firstAttribute,
                              relation: .equal,
                              secondItemID: secondItemID,
                              secondAttribute: secondAttribute,
                              multiplier: multiplier,
                              constant: constant,
                              priority: priority,
                              identifier: identifier)
    }

    static func equal(_ firstItemID: String,
                      _ firstAttribute: NSLayoutConstraint.Attribute,
                      constant: CGFloat,
                      priority: Float = 1000,
                      identifier: String? = nil) -> ConstraintSpec {
        return ConstraintSpec(firstItemID: firstItemID,
                              firstAttribute: firstAttribute,
                              relation: .equal,
                              secondItemID: nil,
                              secondAttribute: .notAnAttribute,
                              multiplier: 1,
                              constant: constant,
                              priority: priority,
                              identifier: identifier)
    }

    static func lessThanOrEqual(_ firstItemID: String,
                                _ firstAttribute: NSLayoutConstraint.Attribute,
                                _ secondItemID: String,
                                _ secondAttribute: NSLayoutConstraint.Attribute,
                                multiplier: CGFloat = 1,
                                constant: CGFloat = 0,
                                priority: Float = 1000,
                                identifier: String? = nil) -> ConstraintSpec {
        return ConstraintSpec(firstItemID: firstItemID,
                              firstAttribute: firstAttribute,
                              relation: .lessThanOrEqual,
                              secondItemID: secondItemID,
                              secondAttribute: secondAttribute,
                              multiplier: multiplier,
                              constant: constant,
                              priority: priority,
                              identifier: identifier)
    }

    static func lessThanOrEqual(_ firstItemID: String,
                                _ firstAttribute: NSLayoutConstraint.Attribute,
                                constant: CGFloat,
                                priority: Float = 1000,
                                identifier: String? = nil) -> ConstraintSpec {
        return ConstraintSpec(firstItemID: firstItemID,
                              firstAttribute: firstAttribute,
                              relation: .lessThanOrEqual,
                              secondItemID: nil,
                              secondAttribute: .notAnAttribute,
                              multiplier: 1,
                              constant: constant,
                              priority: priority,
                              identifier: identifier)
    }

    static func greaterThanOrEqual(_ firstItemID: String,
                                   _ firstAttribute: NSLayoutConstraint.Attribute,
                                   _ secondItemID: String,
                                   _ secondAttribute: NSLayoutConstraint.Attribute,
                                   multiplier: CGFloat = 1,
                                   constant: CGFloat = 0,
                                   priority: Float = 1000,
                                   identifier: String? = nil) -> ConstraintSpec {
        return ConstraintSpec(firstItemID: firstItemID,
                              firstAttribute: firstAttribute,
                              relation: .greaterThanOrEqual,
                              secondItemID: secondItemID,
                              secondAttribute: secondAttribute,
                              multiplier: multiplier,
                              constant: constant,
                              priority: priority,
                              identifier: identifier)
    }

    static func greaterThanOrEqual(_ firstItemID: String,
                                   _ firstAttribute: NSLayoutConstraint.Attribute,
                                   constant: CGFloat,
                                   priority: Float = 1000,
                                   identifier: String? = nil) -> ConstraintSpec {
        return ConstraintSpec(firstItemID: firstItemID,
                              firstAttribute: firstAttribute,
                              relation: .greaterThanOrEqual,
                              secondItemID: nil,
                              secondAttribute: .notAnAttribute,
                              multiplier: 1,
                              constant: constant,
                              priority: priority,
                              identifier: identifier)
    }
}

// MARK: - Item specification

/// One item (view) in the fixture tree.
struct ItemSpec {
    var id: String
    var initialFrame: CGRect
    /// UIKit's view property (default true for UIView; fixtures set it explicitly).
    var translatesAutoresizingMaskIntoConstraints: Bool
    /// `nil` => no intrinsic content size (`UIViewNoIntrinsicMetric` on both axes).
    var intrinsicContentSize: CGSize?
    var horizontalHuggingPriority: Float
    var horizontalCompressionResistancePriority: Float
    var verticalHuggingPriority: Float
    var verticalCompressionResistancePriority: Float
    /// UIKit autoresizing mask of the view (used by the autoresizing-mask fixtures; ignored when the
    /// view is constrained).
    var autoresizingMask: UIView.AutoresizingMask
    var children: [ItemSpec]

    init(id: String,
         initialFrame: CGRect = .zero,
         translatesAutoresizingMaskIntoConstraints: Bool = false,
         intrinsicContentSize: CGSize? = nil,
         horizontalHuggingPriority: Float = 250,
         horizontalCompressionResistancePriority: Float = 750,
         verticalHuggingPriority: Float = 250,
         verticalCompressionResistancePriority: Float = 750,
         autoresizingMask: UIView.AutoresizingMask = [],
         children: [ItemSpec] = []) {
        self.id = id
        self.initialFrame = initialFrame
        self.translatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
        self.intrinsicContentSize = intrinsicContentSize
        self.horizontalHuggingPriority = horizontalHuggingPriority
        self.horizontalCompressionResistancePriority = horizontalCompressionResistancePriority
        self.verticalHuggingPriority = verticalHuggingPriority
        self.verticalCompressionResistancePriority = verticalCompressionResistancePriority
        self.autoresizingMask = autoresizingMask
        self.children = children
    }
}

// MARK: - Layout direction

enum FixtureDirection {
    case leftToRight
    case rightToLeft

    /// UIKit expresses RTL via `semanticContentAttribute`; the legacy engine takes
    /// `RRLayoutDirection` directly (`AutoLayoutParityHarness`).
    var semanticContentAttribute: UISemanticContentAttribute {
        switch self {
        case .leftToRight: return .forceLeftToRight
        case .rightToLeft: return .forceRightToLeft
        }
    }
}

// MARK: - Fixture

/// Second phase of a fixture that exercises constraint removal + re-solve.
struct RemovalPhase {
    /// Identifiers of the constraints to deactivate after phase 1.
    var removeConstraintIdentifiers: [String]
    /// Frames expected after the removal, again in container coordinates.
    var expectedFrames: [String: CGRect]
}

/// Second phase of an autoresizing-mask fixture: the container is resized and UIKit / the engine
/// must regenerate the same autoresizing-mask equations from the frame captured at the first pass.
struct ResizePhase {
    /// The container size after the resize (the origin stays at zero).
    var newContainerSize: CGSize
    /// Frames expected after the resize, in *container* coordinates.
    var expectedFrames: [String: CGRect]
}

/// One complete, fully determined parity fixture.
struct LayoutFixture {
    var name: String
    var containerSize: CGSize
    var root: ItemSpec
    var constraints: [ConstraintSpec]
    /// Frames recorded from real UIKit, in *container* coordinates, keyed by item id.
    var expectedFrames: [String: CGRect]
    /// Short justification of why the layout has a unique solution (never ambiguous).
    var determinism: String
    var direction: FixtureDirection
    var removal: RemovalPhase?
    var resize: ResizePhase?

    init(name: String,
         containerSize: CGSize,
         root: ItemSpec,
         constraints: [ConstraintSpec],
         expectedFrames: [String: CGRect],
         determinism: String,
         direction: FixtureDirection = .leftToRight,
         removal: RemovalPhase? = nil,
         resize: ResizePhase? = nil) {
        self.name = name
        self.containerSize = containerSize
        self.root = root
        self.constraints = constraints
        self.expectedFrames = expectedFrames
        self.determinism = determinism
        self.direction = direction
        self.removal = removal
        self.resize = resize
    }

    /// Active constraints only (what phase 1 installs).
    var activeConstraints: [ConstraintSpec] {
        return constraints.filter { $0.isActive }
    }
}

// MARK: - UIKit side of the harness

/// A plain `UIView` whose intrinsic content size is driven by the fixture.
/// (A UILabel would pull in font metrics; a deterministic subclass keeps the fixture stable.)
final class FixtureIntrinsicView: UIView {
    var fixtureIntrinsicContentSize: CGSize = CGSize(width: UIView.noIntrinsicMetric,
                                                     height: UIView.noIntrinsicMetric)

    override var intrinsicContentSize: CGSize {
        return fixtureIntrinsicContentSize
    }
}

/// Builds a real `UIView` hierarchy for a fixture and runs it through UIKit Auto Layout.
///
/// The container is deliberately *not* attached to a window: UIKit resolves constraints during
/// `layoutIfNeeded()` on the detached hierarchy too, which keeps the suite independent of screen
/// size, scene state and app lifecycle.
final class UIKitFixtureRun {
    let fixture: LayoutFixture
    let rootView: UIView
    /// All fixture items including the root, keyed by id.
    let views: [String: UIView]
    /// Constraints installed in phase 1, keyed by the spec's `identifier` when present.
    let installedConstraints: [NSLayoutConstraint]

    init(fixture: LayoutFixture) {
        self.fixture = fixture

        var builtViews: [String: UIView] = [:]
        let rootView = UIKitFixtureRun.buildView(for: fixture.root, into: &builtViews)
        self.rootView = rootView
        self.views = builtViews

        var constraints: [NSLayoutConstraint] = []
        for spec in fixture.activeConstraints {
            let constraint = UIKitFixtureRun.makeConstraint(spec, views: builtViews)
            constraints.append(constraint)
        }
        self.installedConstraints = constraints

        for constraint in constraints {
            rootView.addConstraint(constraint)
        }

        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.frame = CGRect(origin: .zero, size: fixture.containerSize)
        // UIKit resolves leading/trailing per constraint from the effective layout direction of the
        // constraint's closest common ancestor; a forced direction on the container does NOT
        // propagate to descendants in a detached hierarchy. The iOS 6 backport model has a single
        // process-wide direction, so force it on every view to model that faithfully.
        for view in builtViews.values {
            view.semanticContentAttribute = fixture.direction.semanticContentAttribute
        }
    }

    // MARK: Building

    private static func buildView(for spec: ItemSpec, into views: inout [String: UIView]) -> UIView {
        let view: FixtureIntrinsicView
        if let intrinsic = spec.intrinsicContentSize {
            view = FixtureIntrinsicView(frame: spec.initialFrame)
            view.fixtureIntrinsicContentSize = intrinsic
        } else {
            view = FixtureIntrinsicView(frame: spec.initialFrame)
            view.fixtureIntrinsicContentSize = CGSize(width: UIView.noIntrinsicMetric,
                                                      height: UIView.noIntrinsicMetric)
        }
        view.translatesAutoresizingMaskIntoConstraints = spec.translatesAutoresizingMaskIntoConstraints
        view.autoresizingMask = spec.autoresizingMask
        view.setContentHuggingPriority(UILayoutPriority(rawValue: spec.horizontalHuggingPriority),
                                       for: .horizontal)
        view.setContentCompressionResistancePriority(UILayoutPriority(rawValue: spec.horizontalCompressionResistancePriority),
                                                     for: .horizontal)
        view.setContentHuggingPriority(UILayoutPriority(rawValue: spec.verticalHuggingPriority),
                                       for: .vertical)
        view.setContentCompressionResistancePriority(UILayoutPriority(rawValue: spec.verticalCompressionResistancePriority),
                                                     for: .vertical)

        views[spec.id] = view
        for child in spec.children {
            let childView = buildView(for: child, into: &views)
            view.addSubview(childView)
        }
        return view
    }

    private static func makeConstraint(_ spec: ConstraintSpec, views: [String: UIView]) -> NSLayoutConstraint {
        let firstItem = views[spec.firstItemID]
        let secondItem = spec.secondItemID.flatMap { views[$0] }
        let constraint = NSLayoutConstraint(item: firstItem as Any,
                                            attribute: spec.firstAttribute,
                                            relatedBy: spec.relation.uiKitRelation,
                                            toItem: secondItem,
                                            attribute: spec.secondAttribute,
                                            multiplier: spec.multiplier,
                                            constant: spec.constant)
        constraint.priority = UILayoutPriority(rawValue: spec.priority)
        constraint.identifier = spec.identifier
        return constraint
    }

    // MARK: Running

    /// Runs UIKit Auto Layout and returns absolute frames in container coordinates.
    func layout() -> [String: CGRect] {
        rootView.layoutIfNeeded()
        return frames()
    }

    /// Removes the constraints listed by `fixture.removal` and forces a fresh layout pass.
    func applyRemoval() {
        guard let removal = fixture.removal else { return }
        let identifiers = Set(removal.removeConstraintIdentifiers)
        for constraint in installedConstraints {
            if let identifier = constraint.identifier, identifiers.contains(identifier) {
                rootView.removeConstraint(constraint)
            }
        }
        rootView.setNeedsLayout()
    }

    /// Resizes the container (larger width) so UIKit must regenerate the autoresizing-mask
    /// constraints of its subviews from the frame captured during the first pass.
    func applyResize() {
        guard let resize = fixture.resize else { return }
        rootView.frame = CGRect(origin: .zero, size: resize.newContainerSize)
        rootView.setNeedsLayout()
    }

    /// Snapshots every view's frame in container coordinates.
    func frames() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for (id, view) in views {
            result[id] = rootView.convert(view.bounds, from: view)
        }
        return result
    }
}

// MARK: - Frame comparison

/// Compares frames by item id with Auto Layout's practical tolerance.
enum FrameCompare {
    /// Half a point: the tolerance used by the parity suite (sub-pixel/rounding only).
    static let accuracy: CGFloat = 0.5

    /// Returns one human-readable line per mismatching edge/coordinate. Empty means a perfect match.
    /// Missing or unexpected ids are reported too — that catches engine bugs that silently drop items.
    static func mismatches(actual: [String: CGRect], expected: [String: CGRect]) -> [String] {
        var lines: [String] = []
        let actualIDs = Set(actual.keys)
        let expectedIDs = Set(expected.keys)
        for id in expectedIDs.subtracting(actualIDs).sorted() {
            lines.append("missing item '\(id)': expected \(describe(expected[id]!)) but no actual frame")
        }
        for id in actualIDs.subtracting(expectedIDs).sorted() {
            lines.append("unexpected item '\(id)': actual \(describe(actual[id]!))")
        }
        for id in expectedIDs.intersection(actualIDs).sorted() {
            guard let actualFrame = actual[id], let expectedFrame = expected[id] else { continue }
            let deltas: [(String, CGFloat, CGFloat)] = [
                ("x", actualFrame.origin.x, expectedFrame.origin.x),
                ("y", actualFrame.origin.y, expectedFrame.origin.y),
                ("width", actualFrame.size.width, expectedFrame.size.width),
                ("height", actualFrame.size.height, expectedFrame.size.height)
            ]
            for (label, actualValue, expectedValue) in deltas {
                if abs(actualValue - expectedValue) > accuracy {
                    lines.append("'\(id).\(label)': expected \(format(expectedValue)) actual \(format(actualValue)) (delta \(format(actualValue - expectedValue)))")
                }
            }
        }
        return lines
    }

    static func describe(_ rect: CGRect) -> String {
        return "(" + [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
            .map(format)
            .joined(separator: ", ") + ")"
    }

    static func format(_ value: CGFloat) -> String {
        return String(format: "%.3f", Double(value))
    }
}

// MARK: - Fixture catalogue

/// All static parity fixtures. Every case is fully determined; the `determinism` note explains why.
enum ParityFixtures {

    static let containerSize = CGSize(width: 320, height: 480)

    /// Helper: root container item.
    static func container(children: [ItemSpec]) -> ItemSpec {
        return ItemSpec(id: "container",
                        initialFrame: CGRect(origin: .zero, size: containerSize),
                        translatesAutoresizingMaskIntoConstraints: true,
                        children: children)
    }

    /// Helper: an item pinned by constraints (frame is irrelevant, defaults to zero).
    static func item(_ id: String,
                     intrinsic: CGSize? = nil,
                     hugH: Float = 250,
                     compH: Float = 750,
                     hugV: Float = 250,
                     compV: Float = 750,
                     children: [ItemSpec] = []) -> ItemSpec {
        return ItemSpec(id: id,
                        initialFrame: .zero,
                        translatesAutoresizingMaskIntoConstraints: false,
                        intrinsicContentSize: intrinsic,
                        horizontalHuggingPriority: hugH,
                        horizontalCompressionResistancePriority: compH,
                        verticalHuggingPriority: hugV,
                        verticalCompressionResistancePriority: compV,
                        children: children)
    }

    static let all: [LayoutFixture] = [
        pinnedEdges,
        fixedSizeCentered,
        equalWidthsSiblings,
        equalHeightsSiblings,
        halfContainerWidth,
        proportionalWidthWithConstant,
        aspectRatioSelf,
        centeredWithOffsets,
        inequalitySlack,
        inequalityBound,
        priorityConflictWidth,
        priorityConflictHeight,
        huggingIntrinsic,
        huggingWithTrailingMaximum,
        compressionRequiredEdgesWin,
        compressionPrioritySplit,
        autoresizingMaskView,
        rtlLeadingTrailing,
        nestedViews,
        rtlNestedEqualities,
        rtlNestedMixedPairing,
        ancestorOwnedGrandchildConstraint,
        rtlInequality,
        rtlAbsoluteLeftRight,
        autoresizingResizeNone,
        autoresizingResizeFlexibleWidth,
        autoresizingResizeFlexibleRightMargin,
        autoresizingResizeFlexibleLeftMargin,
        autoresizingResizeBothMargins,
        autoresizingResizeFlexibleHeight,
        constraintRemoval
    ]

    // 1. All four edges pinned with equal insets.
    //    Determinism: four required equalities fix x, y, width, height exactly.
    static let pinnedEdges = LayoutFixture(
        name: "pinnedEdges",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .trailing, "container", .trailing, constant: -10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .bottom, "container", .bottom, constant: -10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 300, height: 460)
        ],
        determinism: "Leading/trailing/top/bottom are four required equalities, so the frame is unique.")

    // 2. Fixed width/height, centered in both axes.
    //    Determinism: width + height + centerX + centerY required equalities.
    static let fixedSizeCentered = LayoutFixture(
        name: "fixedSizeCentered",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .width, constant: 120),
            .equal("a", .height, constant: 80),
            .equal("a", .centerX, "container", .centerX),
            .equal("a", .centerY, "container", .centerY)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 100, y: 200, width: 120, height: 80)
        ],
        determinism: "Width/height/centerX/centerY equalities fix all four degrees of freedom.")

    // 3. Two siblings with equal widths; first is half the container width.
    //    Determinism: a's leading/top/height/width are fixed; b copies a's width and height,
    //    and its trailing is pinned, so b's x follows.
    static let equalWidthsSiblings = LayoutFixture(
        name: "equalWidthsSiblings",
        containerSize: containerSize,
        root: container(children: [item("a"), item("b")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 60),
            .equal("a", .width, "container", .width, multiplier: 0.5),
            .equal("b", .width, "a", .width),
            .equal("b", .height, "a", .height),
            .equal("b", .top, "a", .top),
            .equal("b", .trailing, "container", .trailing, constant: -10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 160, height: 60),
            "b": CGRect(x: 150, y: 10, width: 160, height: 60)
        ],
        determinism: "a is fixed by 4 equalities; b's width/height copy a and its trailing is pinned, so b's x is fixed too.")

    // 4. Two siblings with equal heights (side by side).
    //    Determinism: a fixed by 4 equalities, b copies width/height and is pinned leading/top.
    static let equalHeightsSiblings = LayoutFixture(
        name: "equalHeightsSiblings",
        containerSize: containerSize,
        root: container(children: [item("a"), item("b")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 50),
            .equal("b", .leading, "a", .trailing, constant: 10),
            .equal("b", .top, "a", .top),
            .equal("b", .width, "a", .width),
            .equal("b", .height, "a", .height)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 100, height: 50),
            "b": CGRect(x: 120, y: 10, width: 100, height: 50)
        ],
        determinism: "a fixed by width/height/leading/top; b's width/height copy a and leading/top are pinned.")

    // 5. Width is a multiplier of the container width (position attribute x size attribute rule).
    //    Determinism: width = 0.5 * 320 = 160; leading/top/height pinned.
    static let halfContainerWidth = LayoutFixture(
        name: "halfContainerWidth",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 20),
            .equal("a", .top, "container", .top, constant: 20),
            .equal("a", .height, constant: 100),
            .equal("a", .width, "container", .width, multiplier: 0.5)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 20, y: 20, width: 160, height: 100)
        ],
        determinism: "width = 0.5 * container.width = 160; leading/top/height pinned by required equalities.")

    // 6. Multiplier with a constant: width = 0.5 * container.width + 20.
    //    Determinism: width = 180; leading/top/height pinned.
    static let proportionalWidthWithConstant = LayoutFixture(
        name: "proportionalWidthWithConstant",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 50),
            .equal("a", .width, "container", .width, multiplier: 0.5, constant: 20)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 180, height: 50)
        ],
        determinism: "width = 0.5 * 320 + 20 = 180; leading/top/height pinned by required equalities.")

    // 7. Self-referencing multiplier (aspect ratio): width = 2 * height, height = 50.
    //    Determinism: height equality + ratio + leading/top pin.
    static let aspectRatioSelf = LayoutFixture(
        name: "aspectRatioSelf",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 50),
            .equal("a", .width, "a", .height, multiplier: 2)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 100, height: 50)
        ],
        determinism: "height = 50 (required) and width = 2 * height; leading/top pinned. Self-referencing ratio has a unique solution.")

    // 8. Centering with offsets on both axes.
    //    Determinism: fixed size + centerX/centerY equalities with constants.
    static let centeredWithOffsets = LayoutFixture(
        name: "centeredWithOffsets",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 40),
            .equal("a", .centerX, "container", .centerX, constant: 5),
            .equal("a", .centerY, "container", .centerY, constant: -10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 115, y: 210, width: 100, height: 40)
        ],
        determinism: "size and both centers are required equalities, so the frame is unique.")

    // 9. Required inequalities that have slack; equalities alone determine the frame.
    //    Determinism: centerX/top/width/height equalities fully determine the frame; the
    //    required legal inequalities (leading >= 10, trailing <= 310) are satisfied strictly,
    //    so they do not add a second solution.
    static let inequalitySlack = LayoutFixture(
        name: "inequalitySlack",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .width, constant: 150),
            .equal("a", .height, constant: 50),
            .equal("a", .centerX, "container", .centerX),
            .equal("a", .top, "container", .top, constant: 20),
            .greaterThanOrEqual("a", .leading, "container", .leading, constant: 10),
            .lessThanOrEqual("a", .trailing, "container", .trailing, constant: -10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 85, y: 20, width: 150, height: 50)
        ],
        determinism: "Equalities fix all four degrees of freedom; the required inequalities are satisfied with slack (85 >= 10, 235 <= 310).")

    // 10. A required inequality that actually binds: leading >= 40 beats leading == 0 @750.
    //     Determinism: width/top/height required; the unique minimiser is leading = 40 because
    //     the required lower bound excludes the optional equality's preferred value (0).
    static let inequalityBound = LayoutFixture(
        name: "inequalityBound",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 50),
            .equal("a", .top, "container", .top, constant: 10),
            .greaterThanOrEqual("a", .leading, "container", .leading, constant: 40),
            .equal("a", .leading, "container", .leading, constant: 0, priority: 750)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 40, y: 10, width: 100, height: 50)
        ],
        determinism: "Required leading >= 40 bounds the optional leading == 0 @750; the objective is minimised uniquely at leading = 40.")

    // 11. Priority conflict on width: required cap (width <= 100) beats width == 200 @750.
    //     Determinism: required cap fixes width = 100; optional equality is broken.
    static let priorityConflictWidth = LayoutFixture(
        name: "priorityConflictWidth",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 40),
            .equal("a", .width, constant: 200, priority: 750),
            .lessThanOrEqual("a", .width, constant: 100, priority: 1000)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 100, height: 40)
        ],
        determinism: "Required width <= 100 caps the optional width == 200 @750; unique solution width = 100.")

    // 12. Vertical analogue of the priority conflict.
    static let priorityConflictHeight = LayoutFixture(
        name: "priorityConflictHeight",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 200, priority: 750),
            .lessThanOrEqual("a", .height, constant: 100, priority: 1000)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 100, height: 100)
        ],
        determinism: "Required height <= 100 caps the optional height == 200 @750; unique solution height = 100.")

    // 13. Intrinsic content size with only leading/top pinned: hugging and compression sandwich
    //     each free axis to the intrinsic value.
    //     Determinism: width/height are bounded above by hugging (@250) and below by compression
    //     resistance (@750); both are satisfied only at the intrinsic size, so it is unique.
    static let huggingIntrinsic = LayoutFixture(
        name: "huggingIntrinsic",
        containerSize: containerSize,
        root: container(children: [item("label", intrinsic: CGSize(width: 120, height: 40))]),
        constraints: [
            .equal("label", .leading, "container", .leading, constant: 10),
            .equal("label", .top, "container", .top, constant: 10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "label": CGRect(x: 10, y: 10, width: 120, height: 40)
        ],
        determinism: "Both free axes are sandwiched by intrinsic hugging (<=) and compression resistance (>=), whose only common value is the intrinsic size (120x40).")

    // 14. Intrinsic hugging with a required maximum width larger than the intrinsic width.
    //     Determinism: width wants 120 (hugging/compression); the required trailing bound (<= 300)
    //     has slack, so the intrinsic width wins uniquely.
    static let huggingWithTrailingMaximum = LayoutFixture(
        name: "huggingWithTrailingMaximum",
        containerSize: containerSize,
        root: container(children: [item("label", intrinsic: CGSize(width: 120, height: 40))]),
        constraints: [
            .equal("label", .leading, "container", .leading, constant: 10),
            .equal("label", .top, "container", .top, constant: 10),
            .lessThanOrEqual("label", .trailing, "container", .trailing, constant: -10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "label": CGRect(x: 10, y: 10, width: 120, height: 40)
        ],
        determinism: "Width is sandwiched at 120 by intrinsic hugging/compression; the required trailing bound (110 <= 310) is slack.")

    // 15. Compression resistance must lose to required edges: intrinsic width 400 compressed to 300.
    //     Determinism: leading + trailing are required equalities (width = 300); compression is optional.
    static let compressionRequiredEdgesWin = LayoutFixture(
        name: "compressionRequiredEdgesWin",
        containerSize: containerSize,
        root: container(children: [item("label", intrinsic: CGSize(width: 400, height: 40))]),
        constraints: [
            .equal("label", .leading, "container", .leading, constant: 10),
            .equal("label", .trailing, "container", .trailing, constant: -10),
            .equal("label", .top, "container", .top, constant: 10)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "label": CGRect(x: 10, y: 10, width: 300, height: 40)
        ],
        determinism: "Required leading/trailing fix width = 300 (compression resistance 750 is necessarily broken). Height is sandwiched at intrinsic 40 by hugging/compression; leading/top pinned.")

    // 16. Compression priority split: two intrinsic-200 labels in a pinned row; the row is 10pt too
    //     narrow, so the lower-resistance label shrinks. (width_a + width_b = 290, gap 10, insets 10.)
    //     Determinism: required edge equations reduce the row to a single shared deficit
    //     (400 - 290 = 110). a resists at 800, b at 750, so the unique optimum puts the whole
    //     deficit on b: a = 200, b = 90.
    static let compressionPrioritySplit = LayoutFixture(
        name: "compressionPrioritySplit",
        containerSize: containerSize,
        root: container(children: [
            item("a", intrinsic: CGSize(width: 200, height: 30), compH: 800),
            item("b", intrinsic: CGSize(width: 200, height: 30), compH: 750)
        ]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .trailing, "b", .leading, constant: -10),
            .equal("b", .trailing, "container", .trailing, constant: -10),
            .equal("b", .top, "a", .top),
            .equal("b", .height, "a", .height)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 200, height: 30),
            "b": CGRect(x: 220, y: 10, width: 90, height: 30)
        ],
        determinism: "Required edges leave width_a + width_b = 290. Compression resistance 800 (a) > 750 (b) with a total deficit of 110 => unique optimum a = 200, b = 90.")

    // 17. Autoresizing-mask-only view: translatesAutoresizingMaskIntoConstraints = true with a fixed frame.
    //     Determinism: the view has no constraints; its mask pins its frame exactly. A pinned sibling
    //     makes sure the layout pass really runs.
    static let autoresizingMaskView = LayoutFixture(
        name: "autoresizingMaskView",
        containerSize: containerSize,
        root: container(children: [
            ItemSpec(id: "fixed",
                     initialFrame: CGRect(x: 20, y: 30, width: 100, height: 50),
                     translatesAutoresizingMaskIntoConstraints: true),
            item("a")
        ]),
        constraints: [
            .equal("a", .leading, "container", .leading),
            .equal("a", .trailing, "container", .trailing),
            .equal("a", .top, "container", .top),
            .equal("a", .bottom, "container", .bottom)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "fixed": CGRect(x: 20, y: 30, width: 100, height: 50),
            "a": CGRect(x: 0, y: 0, width: 320, height: 480)
        ],
        determinism: "The autoresizing-mask view is pinned to its own frame by its generated constraints; the sibling is fixed by four required equalities.")

    // 18. RTL leading/trailing with asymmetric insets (10 from leading = right, 20 from trailing = left).
    //     Determinism: width = 320 - 10 - 20 = 290 and the horizontal position is fixed by the
    //     leading/trailing equations; the frame is unique whatever the direction convention.
    static let rtlLeadingTrailing = LayoutFixture(
        name: "rtlLeadingTrailing",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .trailing, "container", .trailing, constant: -20),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 50)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 20, y: 10, width: 290, height: 50)
        ],
        determinism: "Leading/trailing/top/height required equalities fix all four degrees of freedom; only the direction mapping differs from the LTR cases.",
        direction: .rightToLeft)

    // 19. Nested views: outer pinned to the container, inner pinned inside outer, grandchild centered.
    //     Determinism: every level is fixed by required equalities.
    static let nestedViews = LayoutFixture(
        name: "nestedViews",
        containerSize: containerSize,
        root: container(children: [
            item("outer", children: [
                item("inner", children: [item("g")])
            ])
        ]),
        constraints: [
            .equal("outer", .leading, "container", .leading, constant: 10),
            .equal("outer", .top, "container", .top, constant: 20),
            .equal("outer", .trailing, "container", .trailing, constant: -10),
            .equal("outer", .bottom, "container", .bottom, constant: -20),
            .equal("inner", .leading, "outer", .leading, constant: 5),
            .equal("inner", .top, "outer", .top, constant: 5),
            .equal("inner", .trailing, "outer", .trailing, constant: -5),
            .equal("inner", .bottom, "outer", .bottom, constant: -5),
            .equal("g", .width, constant: 50),
            .equal("g", .height, constant: 30),
            .equal("g", .centerX, "inner", .centerX),
            .equal("g", .centerY, "inner", .centerY)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "outer": CGRect(x: 10, y: 20, width: 300, height: 440),
            "inner": CGRect(x: 15, y: 25, width: 290, height: 430),
            "g": CGRect(x: 135, y: 225, width: 50, height: 30)
        ],
        determinism: "Each level is fixed by required equalities; g has fixed size and both centers pinned to inner.")

    // 21. RTL required inequality + optional equality: the required lower bound on the leading
    //     (right) edge must win, and the RTL constant sign must be mirrored for the inequality too.
    //     Determinism: width/height/top fixed; the only horizontal freedom is the leading edge,
    //     bounded below (logically) by 40 and pulled to 0 by the optional equality => leading = 40
    //     logically, i.e. right edge 40pt in from the container's leading (right) edge: x = 180.
    static let rtlInequality = LayoutFixture(
        name: "rtlInequality",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 50),
            .equal("a", .top, "container", .top, constant: 10),
            .greaterThanOrEqual("a", .leading, "container", .leading, constant: 40),
            .equal("a", .leading, "container", .leading, constant: 0, priority: 750)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 180, y: 10, width: 100, height: 50)
        ],
        determinism: "Required leading >= 40 (logical, mirrored in RTL) bounds the optional leading == 0 @750; the unique minimiser is leading = 40 logical => x = 180 in RTL.",
        direction: .rightToLeft)

    // 22. RTL left/right are absolute and must NOT be mirrored: an asymmetric left/right pin
    //     produces the same frame as in LTR.
    //     Determinism: left/right/top/height required equalities fix the frame in both directions.
    static let rtlAbsoluteLeftRight = LayoutFixture(
        name: "rtlAbsoluteLeftRight",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .left, "container", .left, constant: 10),
            .equal("a", .right, "container", .right, constant: -20),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 50)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 290, height: 50)
        ],
        determinism: "left/right are absolute attributes (not direction dependent): four required equalities fix the frame and RTL must not change it.",
        direction: .rightToLeft)

    // 23. Nested RTL: the same constraints as nestedViews but with leading/trailing inside a nested
    //     container, which requires the direction to be applied in the constraint's common-ancestor
    //     coordinate space (the engine uses one process-wide direction, so all views are forced RTL).
    //     Determinism: outer is fixed by four physical equalities; c and a are each fixed by
    //     width/height/top plus one directional leading equality.
    static let rtlNestedEqualities = LayoutFixture(
        name: "rtlNestedEqualities",
        containerSize: containerSize,
        root: container(children: [
            item("a"),
            item("outer", children: [item("c")])
        ]),
        constraints: [
            .equal("outer", .left, "container", .left, constant: 40),
            .equal("outer", .top, "container", .top, constant: 100),
            .equal("outer", .width, constant: 200),
            .equal("outer", .height, constant: 100),
            .equal("c", .leading, "outer", .leading, constant: 20),
            .equal("c", .top, "outer", .top, constant: 10),
            .equal("c", .width, constant: 100),
            .equal("c", .height, constant: 40),
            .equal("a", .leading, "c", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 40)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "outer": CGRect(x: 40, y: 100, width: 200, height: 100),
            "c": CGRect(x: 120, y: 110, width: 100, height: 40),
            "a": CGRect(x: 110, y: 10, width: 100, height: 40)
        ],
        determinism: "All frames fixed: outer physically; c by width/height/top + leading against its superview; a by width/height/top + a cross-superview leading equation whose root-space value is c.right - 10 in RTL.",
        direction: .rightToLeft)

    // 24. Nested RTL with a mixed pairing: leading compared with a physical centerX of a nested
    //     item. The physical centerX must not be mirrored; only the leading/constant side is.
    //     Determinism: c's centerX is fixed relative to outer; a's width/height/top plus its leading
    //     equation fix its frame.
    static let rtlNestedMixedPairing = LayoutFixture(
        name: "rtlNestedMixedPairing",
        containerSize: containerSize,
        root: container(children: [
            item("a"),
            item("outer", children: [item("c")])
        ]),
        constraints: [
            .equal("outer", .left, "container", .left, constant: 40),
            .equal("outer", .top, "container", .top, constant: 100),
            .equal("outer", .width, constant: 200),
            .equal("outer", .height, constant: 100),
            .equal("c", .centerX, "outer", .centerX, constant: 30),
            .equal("c", .top, "outer", .top, constant: 10),
            .equal("c", .width, constant: 100),
            .equal("c", .height, constant: 40),
            .equal("a", .leading, "c", .centerX, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .width, constant: 100),
            .equal("a", .height, constant: 40)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "outer": CGRect(x: 40, y: 100, width: 200, height: 100),
            "c": CGRect(x: 120, y: 110, width: 100, height: 40),
            "a": CGRect(x: 60, y: 10, width: 100, height: 40)
        ],
        determinism: "c's absolute centerX is 40 + 100 + 30 = 170; a's leading (RTL: right edge) is 170 - 10 = 160 with fixed width/height/top, so both frames are unique.",
        direction: .rightToLeft)

    // 25. Constraint owned by the common ancestor but referencing grandchildren in different
    //     sub-branches: the engine must collect it from the owner and apply it across branches.
    //     Determinism: outer1/outer2 are physically fixed; c1 is fixed by edge pinning inside
    //     outer1; c2's width copies c1's width and its leading/height/top are pinned.
    static let ancestorOwnedGrandchildConstraint = LayoutFixture(
        name: "ancestorOwnedGrandchildConstraint",
        containerSize: containerSize,
        root: container(children: [
            item("outer1", children: [item("c1")]),
            item("outer2", children: [item("c2")])
        ]),
        constraints: [
            .equal("outer1", .left, "container", .left, constant: 10),
            .equal("outer1", .top, "container", .top, constant: 10),
            .equal("outer1", .width, constant: 140),
            .equal("outer1", .height, constant: 100),
            .equal("outer2", .left, "container", .left, constant: 170),
            .equal("outer2", .top, "container", .top, constant: 10),
            .equal("outer2", .width, constant: 140),
            .equal("outer2", .height, constant: 100),
            .equal("c1", .leading, "outer1", .leading, constant: 10),
            .equal("c1", .trailing, "outer1", .trailing, constant: -10),
            .equal("c1", .top, "outer1", .top, constant: 10),
            .equal("c1", .height, constant: 40),
            .equal("c2", .leading, "outer2", .leading, constant: 10),
            .equal("c2", .top, "outer2", .top, constant: 10),
            .equal("c2", .height, constant: 40),
            .equal("c2", .width, "c1", .width)
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "outer1": CGRect(x: 10, y: 10, width: 140, height: 100),
            "outer2": CGRect(x: 170, y: 10, width: 140, height: 100),
            "c1": CGRect(x: 20, y: 20, width: 120, height: 40),
            "c2": CGRect(x: 180, y: 20, width: 120, height: 40)
        ],
        determinism: "outer1/outer2 physical; c1 fixed by two edges + top/height; c2 copies c1's required width and has leading/top/height pinned.")

    // MARK: - Autoresizing-mask resize fixtures (static container resized 320 -> 400)

    /// Builds an autoresizing-mask fixture: a single fixed-frame child (10, 20, 100, 50) in a
    /// 320x480 container, resized to `newSize`; the mask determines the equations UIKit/the engine
    /// regenerate (see /tmp/autolayout-semantics.md §3.1).
    private static func autoresizingResizeFixture(name: String,
                                                  mask: UIView.AutoresizingMask,
                                                  newSize: CGSize,
                                                  expectedAfterResize: CGRect) -> LayoutFixture {
        return LayoutFixture(
            name: name,
            containerSize: containerSize,
            root: container(children: [
                ItemSpec(id: "child",
                         initialFrame: CGRect(x: 10, y: 20, width: 100, height: 50),
                         translatesAutoresizingMaskIntoConstraints: true,
                         autoresizingMask: mask)
            ]),
            constraints: [],
            expectedFrames: [
                "container": CGRect(x: 0, y: 0, width: 320, height: 480),
                "child": CGRect(x: 10, y: 20, width: 100, height: 50)
            ],
            determinism: "Only autoresizing-mask constraints apply; UIKit regenerates them from the frame captured in the 320x480 pass, so the post-resize frame is uniquely determined by the mask equations (semantics §3.1).",
            resize: ResizePhase(newContainerSize: newSize,
                                expectedFrames: [
                                    "container": CGRect(origin: .zero, size: newSize),
                                    "child": expectedAfterResize
                                ]))
    }

    // 26-31. Autoresizing masks: the six §3.1 shapes, resized 320 -> 400 (width) and 480 -> 600 (height).
    static let autoresizingResizeNone = autoresizingResizeFixture(
        name: "autoresizingResizeNone",
        mask: [],
        newSize: CGSize(width: 400, height: 480),
        expectedAfterResize: CGRect(x: 10, y: 20, width: 100, height: 50))

    static let autoresizingResizeFlexibleWidth = autoresizingResizeFixture(
        name: "autoresizingResizeFlexibleWidth",
        mask: [.flexibleWidth],
        newSize: CGSize(width: 400, height: 480),
        expectedAfterResize: CGRect(x: 10, y: 20, width: 180, height: 50))

    static let autoresizingResizeFlexibleRightMargin = autoresizingResizeFixture(
        name: "autoresizingResizeFlexibleRightMargin",
        mask: [.flexibleRightMargin],
        newSize: CGSize(width: 400, height: 480),
        expectedAfterResize: CGRect(x: 10, y: 20, width: 100, height: 50))

    static let autoresizingResizeFlexibleLeftMargin = autoresizingResizeFixture(
        name: "autoresizingResizeFlexibleLeftMargin",
        mask: [.flexibleLeftMargin],
        newSize: CGSize(width: 400, height: 480),
        expectedAfterResize: CGRect(x: 90, y: 20, width: 100, height: 50))

    // Proportional both-margins case: x = r * (W - w), r = x0 / (W0 - w0) = 10 / 220.
    // Documented as low-confidence in the semantics research; the literal is recorded from UIKit.
    static let autoresizingResizeBothMargins = autoresizingResizeFixture(
        name: "autoresizingResizeBothMargins",
        mask: [.flexibleLeftMargin, .flexibleRightMargin],
        newSize: CGSize(width: 400, height: 480),
        expectedAfterResize: CGRect(x: 300.0 * 10.0 / 220.0, y: 20, width: 100, height: 50))

    // flexibleHeight: top margin 20 and bottom margin 480 - 70 = 410 stay fixed, so the height
    // absorbs the resize: 600 - 20 - 410 = 170. (Note: the semantics doc's example row for
    // flexibleHeight says "maxY + 430", which is an arithmetic slip for this 480-tall container -
    // UIKit on iOS 27 produces 170, measured here.)
    static let autoresizingResizeFlexibleHeight = autoresizingResizeFixture(
        name: "autoresizingResizeFlexibleHeight",
        mask: [.flexibleHeight],
        newSize: CGSize(width: 320, height: 600),
        expectedAfterResize: CGRect(x: 10, y: 20, width: 100, height: 170))

    // 20. Constraint removal + re-solve: a required width == 200 is removed, revealing width == 100 @750.
    //     Determinism: phase 1 has exactly one equality per degree of freedom (200 wins over @750);
    //     phase 2 has exactly one equality per degree of freedom (100).
    static let constraintRemoval = LayoutFixture(
        name: "constraintRemoval",
        containerSize: containerSize,
        root: container(children: [item("a")]),
        constraints: [
            .equal("a", .leading, "container", .leading, constant: 10),
            .equal("a", .top, "container", .top, constant: 10),
            .equal("a", .height, constant: 40),
            .equal("a", .width, constant: 200, identifier: "width-200"),
            .equal("a", .width, constant: 100, priority: 750, identifier: "width-100")
        ],
        expectedFrames: [
            "container": CGRect(x: 0, y: 0, width: 320, height: 480),
            "a": CGRect(x: 10, y: 10, width: 200, height: 40)
        ],
        determinism: "Phase 1: required width == 200 fixes the width (optional @750 is broken). After removal, width == 100 @750 is the only width constraint, so it fixes the width.",
        removal: RemovalPhase(removeConstraintIdentifiers: ["width-200"],
                              expectedFrames: [
                                "container": CGRect(x: 0, y: 0, width: 320, height: 480),
                                "a": CGRect(x: 10, y: 10, width: 100, height: 40)
                              ]))

    // MARK: - Seeded randomized fixtures

    /// Deterministic 32-bit LCG (no Foundation randomness, identical on every run/platform).
    struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed &* 2862933555777941757 &+ 3037000493
        }

        mutating func nextUInt32() -> UInt32 {
            // Numerical Recipes LCG.
            state = state &* 1664525 &+ 1013904223
            return UInt32(truncatingIfNeeded: state >> 32)
        }

        /// Uniform integer in 0...upperBound (inclusive).
        mutating func nextInt(upperBound: Int) -> Int {
            if upperBound <= 0 { return 0 }
            return Int(nextUInt32() % UInt32(upperBound + 1))
        }
    }

    /// Seeded, fully determined pinned layouts used by the randomized parity test.
    /// Every generated case is fixed by required equalities, so legacy and UIKit must agree.
    static func randomized(count: Int, seed: UInt64) -> [LayoutFixture] {
        var generator = SeededGenerator(seed: seed)
        var fixtures: [LayoutFixture] = []
        let width = containerSize.width
        let height = containerSize.height

        for index in 0..<count {
            let style = index % 4
            switch style {
            case 0:
                // Pinned on all four edges with random insets in multiples of 5.
                let left = CGFloat(generator.nextInt(upperBound: 8) * 5)      // 0...40
                let right = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let top = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let bottom = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let itemWidth = width - left - right
                let itemHeight = height - top - bottom
                fixtures.append(LayoutFixture(
                    name: "random.pinned.#\(index)",
                    containerSize: containerSize,
                    root: container(children: [item("a")]),
                    constraints: [
                        .equal("a", .leading, "container", .leading, constant: left),
                        .equal("a", .trailing, "container", .trailing, constant: -right),
                        .equal("a", .top, "container", .top, constant: top),
                        .equal("a", .bottom, "container", .bottom, constant: -bottom)
                    ],
                    expectedFrames: [
                        "container": CGRect(x: 0, y: 0, width: width, height: height),
                        "a": CGRect(x: left, y: top, width: itemWidth, height: itemHeight)
                    ],
                    determinism: "Four required edge equalities fix the frame uniquely (random insets)."))
            case 1:
                // Leading/top pinned + fixed width/height.
                let left = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let top = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let itemWidth = CGFloat(40 + generator.nextInt(upperBound: 24) * 5)   // 40...160
                let itemHeight = CGFloat(30 + generator.nextInt(upperBound: 24) * 5)  // 30...150
                fixtures.append(LayoutFixture(
                    name: "random.fixedSize.#\(index)",
                    containerSize: containerSize,
                    root: container(children: [item("a")]),
                    constraints: [
                        .equal("a", .leading, "container", .leading, constant: left),
                        .equal("a", .top, "container", .top, constant: top),
                        .equal("a", .width, constant: itemWidth),
                        .equal("a", .height, constant: itemHeight)
                    ],
                    expectedFrames: [
                        "container": CGRect(x: 0, y: 0, width: width, height: height),
                        "a": CGRect(x: left, y: top, width: itemWidth, height: itemHeight)
                    ],
                    determinism: "Leading/top/width/height required equalities fix the frame uniquely."))
            case 2:
                // Centered with fixed size and offsets in multiples of 5.
                let itemWidth = CGFloat(50 + generator.nextInt(upperBound: 20) * 5)   // 50...150
                let itemHeight = CGFloat(20 + generator.nextInt(upperBound: 20) * 5)  // 20...120
                let offsetX = CGFloat((generator.nextInt(upperBound: 10) - 5) * 5)    // -25...25
                let offsetY = CGFloat((generator.nextInt(upperBound: 10) - 5) * 5)
                fixtures.append(LayoutFixture(
                    name: "random.centered.#\(index)",
                    containerSize: containerSize,
                    root: container(children: [item("a")]),
                    constraints: [
                        .equal("a", .width, constant: itemWidth),
                        .equal("a", .height, constant: itemHeight),
                        .equal("a", .centerX, "container", .centerX, constant: offsetX),
                        .equal("a", .centerY, "container", .centerY, constant: offsetY)
                    ],
                    expectedFrames: [
                        "container": CGRect(x: 0, y: 0, width: width, height: height),
                        "a": CGRect(x: (width - itemWidth) / 2 + offsetX,
                                    y: (height - itemHeight) / 2 + offsetY,
                                    width: itemWidth,
                                    height: itemHeight)
                    ],
                    determinism: "Size and both center equalities fix the frame uniquely."))
            default:
                // Proportional width (0.25/0.5/0.75 of container) + fixed height, pinned leading/top.
                let factors: [CGFloat] = [0.25, 0.5, 0.75]
                let factor = factors[generator.nextInt(upperBound: factors.count - 1)]
                let left = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let top = CGFloat(generator.nextInt(upperBound: 8) * 5)
                let itemHeight = CGFloat(40 + generator.nextInt(upperBound: 20) * 5)  // 40...140
                fixtures.append(LayoutFixture(
                    name: "random.proportional.#\(index)",
                    containerSize: containerSize,
                    root: container(children: [item("a")]),
                    constraints: [
                        .equal("a", .leading, "container", .leading, constant: left),
                        .equal("a", .top, "container", .top, constant: top),
                        .equal("a", .height, constant: itemHeight),
                        .equal("a", .width, "container", .width, multiplier: factor)
                    ],
                    expectedFrames: [
                        "container": CGRect(x: 0, y: 0, width: width, height: height),
                        "a": CGRect(x: left, y: top, width: width * factor, height: itemHeight)
                    ],
                    determinism: "width = factor * container.width plus leading/top/height equalities fix the frame uniquely."))
            }
        }
        return fixtures
    }
}
