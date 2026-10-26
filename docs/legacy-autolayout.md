# Legacy Auto Layout (Cassowary) — design & interface contract

Status: implementation contract for the `Cassowary` and `LegacyAutoLayout` targets.
Owner: Lead. Writers: `cassowary-dev`, `layout-core-dev`, `uikit-bridge-dev`, `parity-verifier`.
Upstream reference: [RRAutoLayout](https://github.com/RolandasRazma/RRAutoLayout) (MIT, © 2012 Rolandas Razma),
which backported iOS 6 Auto Layout to iOS 5 using the Objective-C runtime and explicitly left the
constraint solver as an exercise ("Wonder how hard would it be to add [Cassowary] to have complete port").

## 1. Goal

1. Port RRAutoLayout's constraint model to Swift.
2. Replace RRAutoLayout's ad-hoc `CGRectAddAttribute` rectangle math with a real **Cassowary** solver,
   so the resulting layout is behaviourally identical to UIKit's constraint-based Auto Layout.
3. Make the whole thing a fallback that is only *used* when the target has no system Auto Layout,
   i.e. iOS < 6. On iOS 6+ the system `NSLayoutConstraint` machinery is authoritative and this
   module is inert (nothing is swizzled, nothing is installed).

### Gating semantics (important)

* Runtime gate: `LegacyAutoLayout.isRequired` is `true` only when `#available(iOS 6.0, *)` is false.
  `LegacyAutoLayout.installIfNeeded()` installs the ObjC-runtime bridge **only** in that case; on
  iOS 6+ it is a no-op that returns `false`.
* The engine itself (`LegacyLayoutEngine`) may be invoked directly on any OS. That is how it is
  tested and how `UIKitCompatKit`'s older shims can opt in explicitly. It never swizzles UIKit.
* Compile-time note: Swift cannot switch on `__IPHONE_OS_VERSION_MAX_ALLOWED`, so whether the *engine*
  runs is decided at runtime. Whether UIKit names such as `NSLayoutConstraint` *resolve to this module's
  types* is a separate compile-time decision, made possible by availability-gated name shadowing
  against the deployment target (§6.1). A Swift binary on iOS 5 needs a back-deployed Swift runtime,
  which is outside this package's scope.
* `MODERN_BUILD` (defined for the 5.7 manifest) is for the existing UIKit shims; the legacy
  Auto Layout module builds in every configuration so it stays testable.

## 2. Targets and file ownership

```
Sources/Cassowary/                     (pure Swift; no UIKit, no Foundation-only restriction)
    Variable.swift, Term.swift, Row.swift, Expression.swift,
    Strength.swift, Constraint.swift, Solver.swift, SolverError.swift

Sources/LegacyAutoLayout/              (Swift; UIKit bridge only in the UIView* files)
    Ownership: layout-core-dev
      RRLayoutAttribute.swift
      RRLayoutRelation.swift
      RRLayoutPriority.swift
      RRLayoutConstraint.swift
      LegacyLayoutItem.swift
      LegacyLayoutEngine.swift
      LegacyLayoutSolver.swift        (constraint graph -> Cassowary system + result extraction)
    Ownership: uikit-bridge-dev
      LegacyAutoLayout.swift          (gate, install, public entry points)
      UIView+LegacyAutoLayout.swift   (constraint storage, translatesAutoresizing shim, intrinsic shim, LegacyLayoutItem conformance)
      LegacyAutoLayoutSwizzling.swift (ObjC runtime install: layoutSubviews/layoutSublayers/initWithCoder/setBounds/setCenter)
      LegacyAutoLayoutNibDecoding.swift (RRLayoutConstraint NSCoder decoding + UIViewAutolayoutConstraints support)
      LegacyAutoLayoutAutoresizing.swift (autoresizing-mask -> constraints translation)

Sources/UIKitCompatKit/
    LegacyAutoLayoutCompat.swift      (Lead: `@_exported import LegacyAutoLayout`)
```

Do not edit files owned by another role. The Lead owns `Package.swift`, `Package@swift-5.7.swift`,
`README.md`, `docs/**`, and `Sources/UIKitCompatKit/LegacyAutoLayoutCompat.swift`.

Tests: one single test target `UIKitCompatKitTests`; add files there (disjoint per role):
* `CassowarySolverTests.swift` — cassowary-dev
* `LegacyLayoutEngineTests.swift`, `RRLayoutConstraintTests.swift` — layout-core-dev
* `LegacyAutoLayoutIntegrationTests.swift` — uikit-bridge-dev
* `AutoLayoutParityFixtures.swift`, `AutoLayoutParityTests.swift` — parity-verifier

Test target dependencies will include `Cassowary`, `LegacyAutoLayout`, `UIKitCompatKit`.

## 3. Module `Cassowary` — API contract (kiwi-compatible)

A faithful implementation of the Cassowary v2 incremental simplex (as used by Auto Layout),
modelled on the published algorithm and the reference `kiwi` implementation. This is the *only*
solver: no ad-hoc layout math.

```swift
public final class Variable: Hashable, CustomStringConvertible {
    public init(_ name: String = "")
    public let name: String
    public var description: String
    // Identity is by object identity; hashValue uses a private unique id.
}

public final class Term {
    public let variable: Variable
    public let coefficient: Double
    public init(_ variable: Variable, _ coefficient: Double = 1.0)
}

public final class Expression {
    public init(constant: Double = 0.0)
    public init(_ term: Term)
    public init(_ variable: Variable, _ coefficient: Double = 1.0)
    public var constant: Double { get set }
    public var terms: [Term] { get }
    public var isConstant: Bool { get }
    public func plus(_ other: Expression) -> Expression
    public func minus(_ other: Expression) -> Expression
    public func times(_ coefficient: Double) -> Expression
    public func divide(by coefficient: Double) -> Expression
    public static func + (Expression, Expression) -> Expression
    public static func - (Expression, Expression) -> Expression
    public static func * (Expression, Double) -> Expression
    public static func / (Expression, Double) -> Expression
    public static prefix func - (Expression) -> Expression
}

public struct Strength: Hashable, Comparable, CustomStringConvertible {
    public static let required: Strength   // create(1000, 1000, 1000)
    public static let strong: Strength     // create(1, 0, 0)
    public static let medium: Strength     // create(0, 1, 0)
    public static let weak: Strength       // create(0, 0, 1)
    public static func create(_ a: Double, _ b: Double, _ c: Double, _ weight: Double = 1.0) -> Strength
    public static func clip(_ value: Double) -> Strength
    public var value: Double
}

public enum RelationalOperator: String, Hashable {
    case lessThanOrEqual = "<="
    case equal = "=="
    case greaterThanOrEqual = ">="
}

public final class Constraint: CustomStringConvertible {
    public init(_ expression: Expression, _ op: RelationalOperator, strength: Strength = .required, name: String? = nil)
    public var expression: Expression { get }
    public var op: RelationalOperator { get }
    public var strength: Strength
    public var name: String?
    public var isRequired: Bool
    public var isInequality: Bool
    public func or(_ strength: Strength) -> Constraint      // copy with different strength
    public func or(_ op: RelationalOperator, _ strength: Strength) -> Constraint
}

public enum SolverError: Error, Equatable, CustomStringConvertible {
    case duplicateConstraint
    case unknownConstraint
    case duplicateEditVariable
    case unknownEditVariable
    case unsatisfiableConstraint
    case internalInconsistency(String)
}

public final class Solver {
    public init()
    public private(set) var constraints: [Constraint]
    public var variableCount: Int { get }
    public var constraintCount: Int { get }

    public func addConstraint(_ constraint: Constraint) throws
    public func addConstraints(_ constraints: [Constraint]) throws
    public func removeConstraint(_ constraint: Constraint) throws
    public func hasConstraint(_ constraint: Constraint) -> Bool

    public func addEditVariable(_ variable: Variable, strength: Strength = .strong) throws
    public func removeEditVariable(_ variable: Variable) throws
    public func hasEditVariable(_ variable: Variable) -> Bool
    public func suggestValue(_ variable: Variable, _ value: Double) throws

    public func updateVariables()
    public func resolve()
    /// Current value of the variable in the last solution (0 if it never appeared / was never updated).
    public func value(of variable: Variable) -> Double
    /// Variables whose external values changed since the previous call (for selective write-back).
    public func fetchChanges() -> [(Variable, Double)]
    public func reset()
}
```

Requirements:
* Required-strength constraints use the artificial-variable two-phase path; optional constraints use the
  weighted objective row. Removing constraints uses dual optimization. Edit variables support
  `suggestValue` + `resolve` for cheap repeated re-solves (window resizing in the layout pass).
* `addConstraint` on an unsatisfiable **required** constraint throws `.unsatisfiableConstraint` and must
  leave the solver in its previous consistent state (Auto Layout catches this and records a broken constraint).
* No UIKit/Foundation platform dependencies beyond `Foundation` (must compile for macOS too, where tests
  run the solver through a scratch package).
* Determinism: identical input order → identical output. Never expose hash-table iteration order in solving.

Test coverage (cassowary-dev): port the reference Cassowary/kiwi solver tests — simple equalities,
inequalities, priorities/strengths, edit variables, add/remove constraint churn, inconsistent systems,
`fetchChanges`, `reset`, plus the classic parabola/`testInconsistent` cases. Tests must be written as
XCTest methods in `Tests/UIKitCompatKitTests/CassowarySolverTests.swift`. Because the package's main
target imports UIKit, run them on the simulator (see §7), and additionally verify the pure module with
a scratch macOS package under `/tmp` (copy `Sources/Cassowary` + a `Package.swift`) so solver logic can be
iterated quickly.

## 4. Module `LegacyAutoLayout` — constraint model API contract

Mirror of `NSLayoutConstraint` / `NSLayoutAttribute` / `NSLayoutPriority` with identical raw values and
attribute semantics.

```swift
public enum RRLayoutAttribute: Int, Hashable, CaseIterable {
    case notAnAttribute = 0
    case left = 1, right = 2, top = 3, bottom = 4
    case leading = 5, trailing = 6
    case width = 7, height = 8
    case centerX = 9, centerY = 10
    case lastBaseline = 11, firstBaseline = 12
}

public enum RRLayoutRelation: Int, Hashable {
    case lessThanOrEqual = -1, equal = 0, greaterThanOrEqual = 1
}

public typealias RRLayoutPriority = Float
public enum RRLayoutPriorityValue {
    public static let required: RRLayoutPriority = 1000
    public static let defaultHigh: RRLayoutPriority = 750
    public static let defaultLow: RRLayoutPriority = 250
    public static let fittingSizeLevel: RRLayoutPriority = 50
}

public final class RRLayoutConstraint: NSObject {
    public init(item firstItem: Any?, attribute firstAttribute: RRLayoutAttribute,
                relatedBy relation: RRLayoutRelation,
                toItem secondItem: Any?, attribute secondAttribute: RRLayoutAttribute,
                multiplier: CGFloat, constant: CGFloat)
    public class func constraint(item: Any?, attribute: RRLayoutAttribute, relatedBy: RRLayoutRelation,
                                 toItem: Any?, attribute: RRLayoutAttribute,
                                 multiplier: CGFloat, constant: CGFloat) -> RRLayoutConstraint

    public var priority: RRLayoutPriority             // default .required
    public var constant: CGFloat                       // settable (Apple's constant is settable too)
    public private(set) var firstItem: Any?
    public private(set) var firstAttribute: RRLayoutAttribute
    public private(set) var relation: RRLayoutRelation
    public private(set) var secondItem: Any?
    public private(set) var secondAttribute: RRLayoutAttribute
    public private(set) var multiplier: CGFloat
    public var identifier: String?
    public var isActive: Bool { get set }              // activation support, ASCII `NSLayoutConstraint.activate` backport
    public class func activate(_ constraints: [RRLayoutConstraint])
    public class func deactivate(_ constraints: [RRLayoutConstraint])
}
```

Rules:
* Attribute raw values and relation raw values must match UIKit exactly (NIB compatibility).
* `RRLayoutConstraint` must be `NSObject`/`NSCoding`-compatible enough to decode the iOS 6
  `NSLayoutConstraint` archive keys (`NSFirstItem`, `NSFirstAttribute`, `NSSecondItem`,
  `NSSecondAttribute`, `NSPriority`, `NSConstant`, `NSRelation`, `NSMultiplier`, `NSLayoutIdentifier`).
  Decoding should prefer the modern `…V2` keys when present (see §6).
  Decoding itself lives in `LegacyAutoLayoutNibDecoding.swift` (uikit-bridge-dev).
* Priority mapping to Cassowary strength is in `RRLayoutPriority.swift` (layout-core-dev):
  required → `.required`; 0 < p < 1000 → `Strength.create(p/1000, 0, 0)` (monotonic, 1000× spacing, matching
  Auto Layout's priority ordering); p == 0 → a new `.weak`-level strength (`Strength.create(0,0,1)`), never 0.
  Document the formula and cite sources in the file header.

## 5. Module `LegacyAutoLayout` — engine API contract

The engine is the UIKit-decoupled layout pass. UIKit integration supplies `LegacyLayoutItem`
conformances and calls it; tests supply fake trees or real views.

```swift
public enum RRLayoutAxis { case horizontal, vertical }
public enum RRLayoutDirection { case leftToRight, rightToLeft }

public struct LegacyAutoresizingReference {
    public let frame: CGRect          // item frame when the reference was captured
    public let superviewSize: CGSize  // superview size when the reference was captured
}

public protocol LegacyLayoutItem: AnyObject {
    var layoutSuperitem: LegacyLayoutItem? { get }
    var layoutSubitems: [LegacyLayoutItem] { get }
    var layoutFrame: CGRect { get }
    func layoutSetFrame(_ frame: CGRect)              // in superitem coordinates

    /// Constraints owned by this item (the equivalent of `-[UIView constraints]`).
    var layoutConstraints: [RRLayoutConstraint] { get }
    /// Constraints owned by a descendant reachable only via this item are collected by the engine,
    /// not by this property.

    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool { get }
    var layoutIntrinsicContentSize: CGSize { get }   // UIViewNoIntrinsicMetric (-1) means "none"
    func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority
    func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority

    var layoutFirstBaselineOffsetFromTop: CGFloat? { get }
    var layoutLastBaselineOffsetFromBottom: CGFloat? { get }

    /// Geometry captured for the autoresizing-mask equations (see §5.3 below). Optional:
    /// implementations may return nil and the engine captures from the current geometry.
    var layoutAutoresizingReference: LegacyAutoresizingReference? { get }
    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference)
}

public extension LegacyLayoutItem {   // defaults: 250 hugging, 750 compression, no intrinsic size,
                                      // horizontal->750/vertical->750 compression, nil baselines
}

public struct LegacyLayoutResult {
    /// Final frames keyed by ObjectIdentifier(item). Root frame is included unchanged.
    public var frames: [ObjectIdentifier: CGRect]
    /// Constraints Auto Layout would log as broken (unsatisfiable at their strength/priority).
    public var brokenConstraints: [RRLayoutConstraint]
    /// Last solved value per item, for debugging/tests.
    public var resolvedAttributes: [ObjectIdentifier: LegacyResolvedFrame]
}

public struct LegacyResolvedFrame {
    public var leading, trailing, top, bottom, width, height, centerX, centerY: CGFloat
    public var firstBaseline, lastBaseline: CGFloat
}

public final class LegacyLayoutEngine {
    public var direction: RRLayoutDirection { get set }       // default .leftToRight
    public init(direction: RRLayoutDirection = .leftToRight)

    /// Build + solve the constraint system for the whole subtree rooted at `root`, then write frames.
    /// The root's current frame is fixed (it is the container; Auto Layout does not resize it here).
    @discardableResult
    public func layout(_ root: LegacyLayoutItem) -> LegacyLayoutResult

    /// Same solve, without writing frames back (used by parity tests).
    public func solve(_ root: LegacyLayoutItem) -> LegacyLayoutResult
}
```

### Engine algorithm (required behaviour, matching UIKit's documented process)

For the subtree rooted at `root`:

1. **Collect** every item in the subtree (pre-order). Collect constraints from `layoutConstraints` of
   every item in the subtree; additionally, for each item, constraints owned by ancestors that reference
   items inside the subtree must be collected when the ancestor is the layout root. De-duplicate by
   object identity. Ignore constraints whose items are outside the subtree being solved (that is the
   parent's pass, exactly as UIKit attaches constraints to the closest common ancestor).
2. **Variables**: for each item except the root, create Cassowary variables for
   `minX (leading/left)`, `maxX (trailing/right)`, `minY (top)`, `maxY (bottom)`, `width`, `height`,
   `centerX`, `centerY`, `firstBaseline`, `lastBaseline`. Root gets fixed variables pinned to its frame.
   Add required "implicit" equations binding the attribute expressions:
   `maxX == minX + width`, `maxY == minY + height`, `centerX == minX + width/2`,
   `centerY == minY + height/2`, `firstBaseline`/`lastBaseline` per §research (baseline offsets, or
   bottom/top fallback when unsupported). `leading`/`trailing` map to `minX`/`maxX` for LTR. In RTL
   they swap (`leading → maxX`, `trailing → minX`), the constant is negated when either side uses a
   directional attribute, and for inequalities the relation is reversed (`<= ↔ >=`) — all three are
   required by UIKit's directional semantics and were verified against the simulator for pure and
   mixed directional pairs (direction from `engine.direction`; the bridge passes
   `UIApplication.userInterfaceLayoutDirection`). `left`/`right`/`centerX`/`centerY` stay physical.
   Note that Apple's documentation's "no nonidentity multiplier with location attributes" rule is
   *not* enforced by `NSLayoutConstraint` (verified), so this port does not reject it either.
3. **Implicit UIKit constraints**:
   * `width >= 0`, `height >= 0` at required strength for every non-root item (UIKit enforces this
     at the engine level; it is not a visible constraint).
   * `translatesAutoresizingMaskIntoConstraints == true`: **not** a naive four-attribute frame pin.
     UIKit generates `NSAutoresizingMaskLayoutConstraint`-style required equations derived from the
     *reference* geometry (the frame and superview size at capture time), and regenerates them from
     the old geometry whenever the superview is resized. The exact equations per mask are in
     `/tmp/autolayout-semantics.md` §3.1 and are reproduced in `LegacyLayoutSolver.swift`:
     flexible width/height pin the leading edge and the trailing/leading gap; two flexible margins
     pin the size and position the item proportionally (`r = x₀ / (W₀ − w₀)`); a single flexible
     margin pins the size and the opposite edge; no flexible margin pins frame and size. All at
     required strength, added **before** user required constraints, so that in a required conflict
     the autoresizing constraint wins (matches UIKit: autoresizing `width == 200` beats an explicit
     required `width == 300`). After solving, refresh the reference to
     `(solved frame, current superview size)`.
   * intrinsic size (when `layoutIntrinsicContentSize` != `UIViewNoIntrinsicMetric` for the axis):
     `width >= intrinsicWidth` at compression-resistance priority and
     `width <= intrinsicWidth` at hugging priority (same for height). Measured defaults are
     hugging 250 and compression resistance 750 for `UIView`/`UILabel`/`UIButton`; only IB's label
     convention uses 251. There is no implicit `size == 0` for views without an intrinsic size.
   * Constraint equations: translate each `RRLayoutConstraint` into a Cassowary `Constraint` by
     expanding both attributes into linear expressions over the items' `minX/minY/width/height`:
     `firstExpr relation multiplier * secondExpr + constant`; required priority → `.required`,
     optional → mapped strength. **Do not special-case attribute pairings**: half-own-size terms
     arise from the attribute definitions (`centerX ≡ minX + width/2`, and a second item's
     `centerX` contributes `multiplier × w₂/2`). UIKit has no "position × size centering" rule —
     such pairings are illegal and must be rejected by validation (below).
   * **Attribute pairing validation** (mirrors UIKit, which raises
     `NSInvalidArgumentException` at constraint creation): legal pairings are
     `centerX ↔ {centerX, leading, trailing, left, right}`,
     `centerY ↔ {centerY, top, bottom, baseline}`,
     `leading/trailing ↔ {leading, trailing, centerX}` (not left/right),
     `left/right ↔ {left, right, centerX}` (not leading/trailing),
     size ↔ size (`width`/`height` in any combination — aspect-ratio constraints such as
     `width == 2 × height` are legal), and `baseline ↔ {baseline, top, bottom, centerY}`.
     Vertical attributes may not pair with horizontal ones, and size attributes may not pair with
     location attributes. With `secondItem == nil`, only `width`/`height` are legal and the multiplier
     is ignored (constant constraint); a location attribute equal to a constant is illegal.
4. **Solve**: constraints are added required-first, then optional; a required constraint that cannot
   be satisfied is recorded in `brokenConstraints` and re-added at an internal strength just below
   required (`Strength.clip(Strength.required.value - 1)`), matching Apple's documented treatment of
   broken constraints ("not required, but higher priority than anything externally specifiable").
   Optional conflicts are resolved by strength. Never crash on conflicting input.
5. **Write back**: for each item, `leading = value(minX)`, `width`, `top = value(minY)`, `height`;
   frame = `CGRect(x: leading, y: top, width: width, height: height)` (in superitem coordinates) and call
   `layoutSetFrame`. Be robust to negative widths/heights (clamp to >= 0) and to NaN (skip/keep old frame).
6. Also expose a `resolveAttributes` result for tests and debug output; frame results must agree with it.

The engine does **not** recurse into `layoutSubviews` of items; the UIKit bridge drives the pass.
Future-proof: keep the engine's internal API `internal` where possible; only the types above are public.

## 6. UIKit bridge API contract (uikit-bridge-dev)

```swift
public enum LegacyAutoLayout {
    /// True only when running on an OS without the constraint-based layout system (iOS < 6).
    public static var isRequired: Bool { get }
    /// True only when the legacy ObjC bridge has actually been installed. Always false on iOS 6+.
    public static var isActive: Bool { get }
    /// Installs the UIView bridge if and only if `isRequired`. Returns true if the bridge is active.
    @discardableResult public static func installIfNeeded() -> Bool
}

public extension UIView {   // @available(iOS, introduced: 5.0)
    /// Constraint storage equivalent to `-[UIView constraints]` for the legacy path.
    var legacyConstraints: [RRLayoutConstraint] { get }
    func legacyAddConstraint(_ constraint: RRLayoutConstraint)
    func legacyAddConstraints(_ constraints: [RRLayoutConstraint])
    func legacyRemoveConstraint(_ constraint: RRLayoutConstraint)
    func legacyRemoveConstraints(_ constraints: [RRLayoutConstraint])
    /// Backport of `translatesAutoresizingMaskIntoConstraints` (associated storage, default true).
    var legacyTranslatesAutoresizingMaskIntoConstraints: Bool { get set }
    /// Content hugging / compression resistance backport.
    func legacySetContentHuggingPriority(_ priority: RRLayoutPriority, for axis: RRLayoutAxis)
    func legacyContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority
    func legacySetContentCompressionResistancePriority(_ priority: RRLayoutPriority, for axis: RRLayoutAxis)
    func legacyContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority
    /// Intrinsic size backport (associated storage; default UIViewNoIntrinsicMetric).
    var legacyIntrinsicContentSize: CGSize { get set }
    /// Runs the legacy layout pass over this view's subtree.
    ///
    /// This is the explicit opt-in path: it runs the engine even when the ObjC bridge is not
    /// installed (i.e. on iOS 6+, for tests and for library shims that need deterministic layout).
    /// When the bridge *is* installed (iOS < 6), the swizzled `layoutSubviews` pass calls this
    /// same code path. It does not consult `isActive`.
    func legacyLayoutIfNeeded()
    func legacySetNeedsLayout()
    func legacySetNeedsUpdateConstraints()
    func legacyUpdateConstraintsIfNeeded()
}
```

* `installIfNeeded()` uses `class_addMethod` / `method_exchangeImplementations` only when
  `!isRequired` is false, mirroring RRAutoLayout: swizzle `layoutSubviews`, `layoutSublayers(of:)`,
  `init(coder:)`, `setBounds`, `setCenter`, `setTransform`; add `constraints`, `addConstraint:`,
  `addConstraints:`, `updateConstraints`, `updateConstraintsIfNeeded`, `setNeedsUpdateConstraints`.
  On modern OS nothing is installed; the direct `legacy*` API remains usable.
* `UIView: LegacyLayoutItem` conformance maps to the properties above; `layoutSetFrame` must avoid
  layout invalidation loops exactly like RRAutoLayout did (`setBounds:` + `setCenter:`, not `setFrame:`).
* NIB decoding: decode `UIViewAutolayoutConstraints` in `initWithCoder:` when the bridge is installed,
  and decode `RRLayoutConstraint` from the Apple archive keys. Verified key set (see
  `/tmp/autolayout-semantics.md` §5): `NSFirstItem`, `NSFirstAttribute`, `NSSecondItem`,
  `NSSecondAttribute`, `NSRelation`, `NSMultiplier`, `NSConstant`, `NSPriority` (integer),
  `NSLayoutIdentifier`, `NSShouldBeArchived`, plus the `…V2` variants written by modern archives
  (prefer V2 when present). View archives also carry
  `UIViewDoesNotTranslateAutoresizingMaskIntoConstraints` and `UIAutoresizingMask`, which the bridge
  decodes so archived views keep their autoresizing behaviour. Upstream RRAutoLayout's decoder missed
  `NSMultiplier` entirely (a real bug — nib constraints were forced to multiplier 1); this port decodes
  it. Unsupported keys are tolerated.
* Autoresizing translation: when `legacyTranslatesAutoresizingMaskIntoConstraints` is true, the engine
  generates the real `NSAutoresizingMaskLayoutConstraint` equations from a captured reference geometry
  (see §5.3), including proportional left/right margins and regeneration on superview resize. The
  bridge stores the reference (associated object) via the `LegacyLayoutItem` hooks. No `.xib` parsing
  required — the mask translation is what old apps rely on.
* Baseline offsets: iOS 6 has only `.baseline` (== `lastBaseline`); `firstBaseline` is iOS 8+. The
  bridge leaves baseline offsets `nil` unless explicitly set, so no equations are invented for views
  without real text metrics.
* Threading: the bridge and all UIKit entry points are `@MainActor`.

### 6.1 iOS 5 drop-in names (`LegacyAutoLayoutIOS5.swift`)

Goal: when the app is compiled for iOS 5, ordinary source using UIKit's constraint API
(`NSLayoutConstraint(...)`, `view.addConstraint(...)`, `view.leadingAnchor...`,
`NSLayoutConstraint.activate(...)`, `.defaultHigh`, …) must resolve to this backport with no `#if`
in app code — and the same source compiled for iOS 6+ must keep resolving to UIKit.

Mechanism: **availability-gated name shadowing**. Swift filters declarations that are unavailable at
the deployment target during name lookup. UIKit annotates the constraint API `API_AVAILABLE(ios(6.0))`,
so at deployment target < 6 those declarations are dropped and a same-named declaration in this module
wins; at deployment target >= 6 this module's declarations are obsoleted and UIKit wins:

```swift
@available(iOS, introduced: 5.0, obsoleted: 6.0)
public typealias NSLayoutConstraint = RRLayoutConstraint

@available(iOS, introduced: 5.0, obsoleted: 6.0)
public extension RRLayoutConstraint {
    typealias Attribute = RRLayoutAttribute
    typealias Relation  = RRLayoutRelation
    typealias Axis      = RRLayoutAxis
}

@available(iOS, introduced: 5.0, obsoleted: 6.0)
public extension UIView {
    var translatesAutoresizingMaskIntoConstraints: Bool { get set }   // -> legacy*
    var constraints: [RRLayoutConstraint] { get }
    func addConstraint(_: RRLayoutConstraint)
    func addConstraints(_: [RRLayoutConstraint])
    func removeConstraint(_: RRLayoutConstraint)
    func removeConstraints(_: [RRLayoutConstraint])
    func setNeedsUpdateConstraints()
    func updateConstraintsIfNeeded()
    func updateConstraints()
    var needsUpdateConstraints: Bool { get }
    var intrinsicContentSize: CGSize { get }
    func invalidateIntrinsicContentSize()
    func contentHuggingPriority(for: RRLayoutAxis) -> UILayoutPriority
    func setContentHuggingPriority(_: UILayoutPriority, for: RRLayoutAxis)
    func contentCompressionResistancePriority(for: RRLayoutAxis) -> UILayoutPriority
    func setContentCompressionResistancePriority(_: UILayoutPriority, for: RRLayoutAxis)
}
```

plus the `UILayoutPriority`/`Float` priority constants (`.required`, `.defaultHigh`, `.defaultLow`,
`.fittingSizeLevel`).

**No duplicated backport API.** The `Anchor` class and the `isActive`/`activate(_:)`/`deactivate(_:)`
implementation are *not* reimplemented here. `Sources/UIKitCompatKit/NSLayoutConstraint.swift` (the
existing backport) keeps its existing legacy-build gating (`#if !macCatalyst && compiler(<6.0) &&
!MODERN_BUILD`) — that is exactly the configuration used for the iOS 5 build — and its availability
range spans `iOS 5.0...<9.0`; at deployment target < 6 it operates on `RRLayoutConstraint` (via the
alias above) and at iOS 6–8 on UIKit's `NSLayoutConstraint`. One implementation, two backends. The engine-facing
activation API is `RRLayoutConstraint.legacyIsActive` / `legacyActivate(_:)` / `legacyDeactivate(_:)`
(used by tests and the explicit legacy API); frontend code keeps using `isActive` / `activate` /
`deactivate`, which resolve to the single backport implementation.

**Requirements and mechanics**

* The shim only wins when the **deployment target is below iOS 6**. Swift's filtering compares
  against the deployment target (not the runtime OS). If a toolchain keeps the deployment target at
  ≥ 6 while the binary runs on iOS 5, the availability mechanism cannot select these declarations;
  fall back to the explicit `RRLayoutConstraint`/`legacy*` API, or shadow the names from the app
  module itself (a module-local `typealias`/extension wins over UIKit's imported declarations —
  tested; this forces the engine for that build configuration, so use it only for an iOS-5-only build).
* `NSLayoutConstraint`/`.Attribute`/`.Relation`/`.Axis` are the names that carry the iOS 6 availability
  annotation; they shadow correctly. C typedefs without availability annotations
  (`NSLayoutAttribute`, `NSLayoutRelation`, `UILayoutPriority` itself) cannot be shadowed — modern
  Swift spells those as nested types, which are covered above; the priority *constants* are provided
  as extensions.
* Runtime: name resolution is compile-time only. Swift has no `+load`, so the bridge installs
  **lazily on first legacy constraint use**: `RRLayoutConstraint.activate(_:)` / `isActive = true`
  (via `LegacyAutoLayout.ensureInstalled()`), `addConstraint(s)`, `setNeedsUpdateConstraints`,
  `updateConstraintsIfNeeded`, `legacyLayoutIfNeeded` and the other `legacy*` entry points all trigger
  it. `LegacyAutoLayout.installIfNeeded()` remains public for deterministic startup and is a strict
  no-op on iOS 6+. `ensureInstalled()` is `nonisolated` and hops to the main queue if a background
  thread activates a constraint, so the runtime installation always happens on main.
* **Forced install for iOS 5-name builds:** because name binding is a compile-time decision, a binary
  built with a deployment target below iOS 6 must run the backport engine on *every* OS it runs on
  (including iOS 6+ devices). The iOS 5 name shims therefore call the internal
  `installForLegacyNames()`, which bypasses the runtime/system-Auto-Layout guards and installs the
  bridge. `installIfNeeded()` (the public path) keeps its runtime gate, so explicit legacy API use on
  a modern build never swizzles UIKit.
* Constraints activated via `NSLayoutConstraint.activate(...)` / `isActive = true` are tracked in the
  legacy active-constraint registry and solved by the engine, but — like Apple's `isActive` semantics
  for constraints not yet added to a hierarchy — they do not appear in any view's `constraints` array.
  Use `addConstraint` when you need ownership/`constraints` semantics.
* Limits: extension members cannot be overridden by subclasses (no `override func updateConstraints()`
  or `override var intrinsicContentSize` in iOS 5 code — set `legacyIntrinsicContentSize` or use the
  legacy update hooks); VFL, `UILayoutGuide`/margins/safe-area/first-baseline anchors are separate
  backports and not part of the iOS 5 name layer; nib constraints still need an Objective-C trampoline
  that registers a class literally named `NSLayoutConstraint` (Swift cannot impersonate it).
* Both manifests declare `.iOS("5.0")` as the package platform so an iOS 5 app can depend on the
  package. Stock Swift toolchains clamp that to their minimum deployment target at build time; the
  shims are compiled but unavailable there, so they do not interfere on iOS 6+ targets.

**Validation performed here.** The shadowing rule itself was verified with a real UIKit analogue on
this toolchain: `UIStackView` (UIKit, iOS 9) shadowed by `@available(iOS, introduced: 7.0, obsoleted:
9.0)` at deployment target 7 resolved to the shim, and the same client at deployment target 9 resolved
to UIKit. The actual `LegacyAutoLayoutIOS5.swift` layer was compiled into the module (iOS 5.0 platform),
the whole module was also compiled with `swiftc -target ...-ios7.0-simulator`, and a client compiled at
deployment target 7 against the built module resolves every constrained name to UIKit (no ambiguity).
Running the iOS 5 branch itself needs a toolchain that accepts deployment target 5; a one-line
`NSLayoutConstraint(...)` snippet compiled at that target is the definitive check.
 Stock Swift toolchains clamp that to their minimum deployment target at build time; the
  shims are compiled but unavailable there, so they do not interfere on iOS 6+ targets (verified by
  compiling a client at deployment target iOS 7 in which every name resolved to UIKit).

## 7. Building and testing (commands)

Package is iOS-only and the main target imports UIKit, so use xcodebuild:

```bash
# compile everything
xcodebuild -scheme UIKitCompatKit -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd-legacy build

# run the test suite (test target is UIKitCompatKitTests)
xcodebuild test -scheme UIKitCompatKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /tmp/dd-legacy
```

Individual tests can be filtered with `-only-testing:UIKitCompatKitTests/CassowarySolverTests` etc.
Parity tests build the *same* constraint set twice — once with real `NSLayoutConstraint` on a real
`UIView` hierarchy and `layoutIfNeeded`, once with `LegacyLayoutEngine` on real `UIView`s (or fake items) —
then compare frames with `XCTAssertEqual(..., accuracy: 0.5)`. Ambiguous layouts (under-constrained)
must not be used as parity cases; every parity case must be fully determined so the comparison is meaningful.
Record UIKit's expected frames as literals in fixtures where useful, so the parity suite is meaningful even
without SwiftUI/UIKit runtime ambiguity.

## 8. Licensing / attribution

RRAutoLayout is MIT (© 2012 Rolandas Razma). Cassowary is the original UW algorithm (Badros & Borning);
reference implementations are BSD-licensed (kiwi © Nucleic Development Team, Modified BSD). Every ported
file keeps the upstream copyright notice in its header. Add a "Third-party notices" section to `README.md`
(Lead-owned) naming both.

## 9. Definition of done

1. `Cassowary` passes the ported solver test suite.
2. `LegacyLayoutEngine` pinned-layout/priority/hugging/compression/autoresizing tests pass; frames match.
3. Parity suite: ≥ 15 fully-determined UIKit-vs-legacy cases match within 0.5 pt (including priorities,
   multipliers, inequalities, autoresizing masks (static and resized), and legal-idiom centering).
4. `LegacyAutoLayout.isRequired == false` and `installIfNeeded() == false` on the modern simulator; no
   system view/constraint is mutated by installing on modern OS.
5. Attribute-pairing validation rejects illegal pairings (location↔size, size↔location, location
   constants, multiplier on location attributes) without crashing valid layouts.
6. Package builds clean in both manifests (`Package.swift` and `Package@swift-5.7.swift`), no new warnings
   in `Sources/Cassowary` and `Sources/LegacyAutoLayout`.
7. README documents usage, gating, architecture, limitations, and third-party notices.
