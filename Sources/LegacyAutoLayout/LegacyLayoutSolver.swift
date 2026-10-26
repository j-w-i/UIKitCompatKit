//
//  LegacyLayoutSolver.swift
//  LegacyAutoLayout
//
//  Translates the legacy item tree + `RRLayoutConstraint`s into a Cassowary
//  system, solves it, and extracts frames/attribute values.
//
//  This is the piece that replaces RRAutoLayout's ad-hoc `CGRectAddAttribute`
//  rectangle math (see `UIView (RRConstraintBasedLayout)` in the upstream
//  sources: "This needs rewrite ... need some approach to gather all constraints
//  affecting constraint"). Auto Layout's documented model is a linear constraint
//  system, so we build exactly that:
//
//      maxX   = minX + width
//      maxY   = minY + height
//      centerX = minX + width / 2
//      centerY = minY + height / 2
//
//  and for every `RRLayoutConstraint`:
//
//      firstAttribute <relation> multiplier * secondAttribute + constant
//
//  where each attribute is mapped onto the expression for the item's edge, size
//  or center on the corresponding axis. Shared variable expressions are what make
//  the system global instead of order-dependent, which is the whole point of
//  using Cassowary here.
//
//  Attribute expansion, not special cases
//  --------------------------------------
//  Attributes are expanded algebraically: `centerX` is its own variable bound to
//  `minX + width/2`, `maxX` is bound to `minX + width`, etc. Half-own-size terms
//  therefore appear exactly where the algebra puts them (left side for the first
//  item, multiplied by `multiplier` for the second item). There is deliberately
//  **no position x size "centering" rule**: UIKit rejects such pairings at
//  constraint-creation time with `NSInvalidArgumentException`, so they never
//  reach a solver (/tmp/autolayout-semantics.md §2.1). See
//  `RRLayoutConstraint.validationError` for the legal-pairing validation.
//
//  `leading`/`trailing` map to `minX`/`maxX` in LTR and swap in RTL, per
//  /tmp/autolayout-semantics.md §2.4 (iOS 6 resolves direction application-wide).
//  `left`/`right`/`centerX` are absolute (they never swap). In RTL the constraint
//  CONSTANT is also mirrored (negated) whenever either side uses leading/trailing:
//  the directional attribute values increase towards the trailing (leftward) edge.
//  This rule was probed against UIKit on the iOS 27 simulator (parity report) for
//  pure and mixed pairings:
//
//      a.leading == c.leading + 10    ->  RTL: a.right   = c.right - 10
//      a.trailing == c.trailing - 20  ->  RTL: a.left    = c.left  + 20
//      a.leading == c.trailing + 10   ->  RTL: a.right   = c.left  - 10
//      a.leading == b.centerX + 10    ->  RTL: a.right   = b.centerX - 10
//      a.centerX == b.leading + 10    ->  RTL: a.centerX = b.right - 10
//      centerX/left/right pairings    ->  unchanged
//
//  Required/optional INEQUALITIES whose sides use leading/trailing are mirrored
//  the same way, which also reverses the relation (verified against UIKit):
//
//      RTL: a.leading >= c.leading + 40   <=>   a.maxX <= c.maxX - 40
//
//  so <= becomes >= (and vice versa) together with the constant negation;
//  equalities keep their relation.
//
//  (A "mirror around M = 2*rootMinX + rootWidth" formulation was considered; it
//  agrees with the empirical results for pure directional pairs but NOT for
//  mixed directional/centerX pairs, so the verified rule above is used.)
//
//  Coordinate space
//  ----------------
//  The solver works in the ROOT's local coordinate space: the root's origin
//  variables are pinned to (0, 0) and its size to its bounds. `layoutFrame` is,
//  however, expressed in the item's superitem coordinate space, so result
//  extraction subtracts the superitem's solved absolute origin before calling
//  `layoutSetFrame`. This matters for nested trees (a subview of a subview must
//  not inherit its parent's absolute offset) and for the frames returned in
//  `LegacyLayoutResult`, which are superitem-relative (the root's frame is
//  returned unchanged). Autoresizing-mask position equations, which UIKit
//  expresses in the superview's coordinate space, are translated accordingly
//  (they subtract the superitem's origin variables).
//
//  Stays (stability across subtree passes)
//  ---------------------------------------
//  UIKit's engine is per-window and a constraint is owned by the closest common
//  ancestor, so an ancestor-owned constraint is not part of a later pass rooted at
//  an intermediate view. Without extra information, Cassowary would leave such
//  under-constrained variables at 0 and collapse geometry that a previous pass had
//  already solved. The engine therefore adds solver-internal WEAK stay constraints
//  pinning every non-root item's position and size to its CURRENT frame (previous
//  pass result). `.weak` (weight 1) is strictly below every user priority (50 maps
//  to 50000) and below intrinsic constraints, so fully determined layouts are
//  unaffected; under-constrained ones keep their incumbent geometry, matching
//  UIKit's documented "keep the incumbent solution" behaviour. Stays are a
//  deliberate deviation from a pure "solve only the subtree" model: real UIKit has
//  a per-window engine, so ancestor-owned constraints survive later per-view
//  passes; the stays reproduce that without collecting constraints outside the
//  subtree.
//
//  Known limitations (documented, not accidental)
//  ----------------------------------------------
//  * Intrinsic content size is modelled as the two inequalities Apple documents
//    (`width >= intrinsic @ compression resistance`,
//    `width <= intrinsic @ hugging`) rather than as an edit variable. A user
//    priority between the default compression resistance (750) and 1000 can
//    therefore out-rank compression here in ways real UIKit's private
//    NSContentSizeLayoutConstraint might not; no parity fixture has shown it.
//  * The Auto Layout Guide says "you cannot use a nonidentity multiplier with
//    location attributes"; UIKit on the probed SDK does NOT enforce that
//    (leading == 2*leading, centerX == 0.5*centerX and top == 1.5*top are all
//    accepted), so neither does this engine or its validator. It is solved
//    algebraically.
//
//  Baselines
//  ---------
//  A baseline is a position attribute derived from the item's content, not from
//  its geometry: `baseline = minY + layoutFirstBaselineOffsetFromTop` for the
//  first baseline and `minY + height - layoutLastBaselineOffsetFromBottom` for the
//  last one. The implicit equation is only added when the item provides an
//  offset; an item without a baseline provider (plain `UIView`) makes baseline
//  constraints unsupported, and those constraints are recorded as broken rather
//  than being given an invented top/bottom value (spec §2.5).
//
//  Solved-vs-broken semantics (matching Auto Layout)
//  -------------------------------------------------
//    * Required constraints (priority >= 1000) are added first, one by one. If one
//      cannot be satisfied the solver throws; it is recorded in
//      `brokenConstraints` and then **re-added at the "broken" strength**
//      `Strength.clip(required.value - 1)` -- the internal level Apple documents:
//      "not required, but higher priority than anything you can externally
//      specify", so the broken constraint is the first thing the next solve tries
//      to satisfy while the rest of the layout proceeds (spec §1.4/§4.1).
//    * Optional constraints are added at their mapped strength. They never throw;
//      a conflicting optional constraint is simply not satisfied (Auto Layout does
//      not log those as broken).
//    * Structurally invalid constraints that somehow bypass creation-time
//      validation (deallocated items, non-finite multiplier/constant, a baseline
//      attribute on an item without baseline metrics) are recorded as broken and
//      skipped instead of trapping: the legacy path must never crash on legacy
//      app input.
//    * Constraints that reference an item outside the solved subtree are skipped
//      silently: that is the parent's layout pass, exactly how UIKit attaches a
//      constraint to the closest common ancestor and only solves it there.
//
//  Autoresizing-mask translation (spec §3.1)
//  ------------------------------------------
//  For an item with `layoutTranslatesAutoresizingMaskIntoConstraints` the engine
//  generates the same four required constraints UIKit's
//  `NSAutoresizingMaskLayoutConstraint` does, driven by the item's
//  `layoutAutoresizingMask` and by `layoutAutoresizingReference` (the frame and
//  superview size the constraints were last generated from). When the current
//  superview size differs from the reference size, the equations are regenerated
//  from the *reference* geometry -- that is `-_resizeWithOldSuperviewSize:` --
//  and after a successful pass `layoutUpdateAutoresizingReference` stores the
//  solved frame + current superview size. Because they are required and are
//  installed before user constraints, a conflicting explicit required constraint
//  loses to the autoresizing constraint, which is what UIKit does (verified on the
//  simulator: autoresizing width == 200 beats explicit width == 300).
//
//  Inputs of `RRLayoutConstraint` are read once per pass. A fresh `Solver` is
//  created per pass: the pass count is low enough that rebuilding is simpler than
//  edit-variable bookkeeping and cannot carry stale state.
//
//  This file is new in the Swift port; it has no upstream counterpart.
//

import Foundation
import CoreGraphics
import Cassowary

// `Foundation.Expression` (the iOS 18 Predicate type) collides with the
// Cassowary linear-expression type of the same name. Pin the solver names at
// file scope so the translation code below reads like the constraint algebra.
private typealias Expression = Cassowary.Expression
private typealias Constraint = Cassowary.Constraint
private typealias RelationalOperator = Cassowary.RelationalOperator

/// Builds and solves the constraint system for one root item.
internal final class LegacyLayoutSolver {

    // MARK: Item variables

    /// The ten variables Auto Layout keeps per item.
    private struct ItemVariables {
        let item: LegacyLayoutItem
        let isRoot: Bool
        let minX: Variable
        let maxX: Variable
        let minY: Variable
        let maxY: Variable
        let width: Variable
        let height: Variable
        let centerX: Variable
        let centerY: Variable
        let firstBaseline: Variable
        let lastBaseline: Variable
    }

    /// A constraint translated into solver form.
    private struct CompiledConstraint {
        let source: RRLayoutConstraint
        let expression: Expression
        let `operator`: RelationalOperator
        let strength: Strength
        let name: String?

        var isRequired: Bool {
            return strength == Strength.required
        }
    }

    /// The documented "broken constraint" strength: not required, but above every
    /// externally specifiable priority (spec §1.4). Apple lowers a member of an
    /// unsatisfiable required set to this level instead of dropping it.
    private static let brokenStrength = Strength.clip(Strength.required.value - 1)

    // MARK: State

    private let root: LegacyLayoutItem
    private let direction: RRLayoutDirection
    private let solver = Solver()

    private var items: [LegacyLayoutItem] = []
    private var itemIdentifiers: Set<ObjectIdentifier> = []
    private var variables: [ObjectIdentifier: ItemVariables] = [:]
    private var brokenConstraints: [RRLayoutConstraint] = []

    // MARK: Init

    internal init(root: LegacyLayoutItem, direction: RRLayoutDirection) {
        self.root = root
        self.direction = direction
    }

    // MARK: Entry point

    /// Solves the tree. When `writingFrames` is `true` every non-root item's frame
    /// is written back through `layoutSetFrame` and the autoresizing references are
    /// advanced; the returned frames are identical either way.
    internal func solve(writingFrames: Bool) -> LegacyLayoutResult {
        collectItems()
        createVariables()
        installImplicitConstraints()
        installAutoresizingConstraints()
        installStays()
        installUserConstraints()
        solver.updateVariables()
        return extractResult(writingFrames: writingFrames)
    }

    // MARK: Collection

    /// Pre-order walk of the subtree. Cycles (a malformed tree) are tolerated by
    /// the visited set; each item is laid out once.
    private func collectItems() {
        var visited: Set<ObjectIdentifier> = []
        var stack: [LegacyLayoutItem] = [root]
        while let item = stack.popLast() {
            let identifier = ObjectIdentifier(item as AnyObject)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)
            items.append(item)
            let subitems = item.layoutSubitems
            var index = subitems.count - 1
            while index >= 0 {
                stack.append(subitems[index])
                index -= 1
            }
        }
        itemIdentifiers = visited
    }

    private func createVariables() {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        for (index, item) in items.enumerated() {
            let identifier = ObjectIdentifier(item as AnyObject)
            let prefix = "\(index)"
            variables[identifier] = ItemVariables(
                item: item,
                isRoot: identifier == rootIdentifier,
                minX: Variable("\(prefix).minX"),
                maxX: Variable("\(prefix).maxX"),
                minY: Variable("\(prefix).minY"),
                maxY: Variable("\(prefix).maxY"),
                width: Variable("\(prefix).width"),
                height: Variable("\(prefix).height"),
                centerX: Variable("\(prefix).centerX"),
                centerY: Variable("\(prefix).centerY"),
                firstBaseline: Variable("\(prefix).firstBaseline"),
                lastBaseline: Variable("\(prefix).lastBaseline")
            )
        }
    }

    // MARK: Implicit (system) constraints

    private func installImplicitConstraints() {
        // 1. The geometry relationships that define the attribute expressions.
        for item in items {
            guard let vars = variables[ObjectIdentifier(item as AnyObject)] else {
                continue
            }
            installRequired(
                Expression(vars.maxX)
                    .minus(Expression(vars.minX))
                    .minus(Expression(vars.width)),
                .equal,
                name: "\(vars.item): maxX = minX + width"
            )
            installRequired(
                Expression(vars.maxY)
                    .minus(Expression(vars.minY))
                    .minus(Expression(vars.height)),
                .equal,
                name: "\(vars.item): maxY = minY + height"
            )
            installRequired(
                Expression(vars.centerX)
                    .minus(Expression(vars.minX))
                    .minus(Expression(vars.width).times(0.5)),
                .equal,
                name: "\(vars.item): centerX = minX + width / 2"
            )
            installRequired(
                Expression(vars.centerY)
                    .minus(Expression(vars.minY))
                    .minus(Expression(vars.height).times(0.5)),
                .equal,
                name: "\(vars.item): centerY = minY + height / 2"
            )

            // Baselines are only defined for items that provide baseline metrics;
            // plain UIView has none, so no equation is invented for it (spec §2.5).
            if let firstOffset = finite(item.layoutFirstBaselineOffsetFromTop) {
                installRequired(
                    Expression(vars.firstBaseline)
                        .minus(Expression(vars.minY))
                        .minus(Expression(constant: firstOffset)),
                    .equal,
                    name: "\(vars.item): firstBaseline = minY + offset"
                )
            }
            if let lastOffset = finite(item.layoutLastBaselineOffsetFromBottom) {
                installRequired(
                    Expression(vars.lastBaseline)
                        .minus(Expression(vars.maxY))
                        .plus(Expression(constant: lastOffset)),
                    .equal,
                    name: "\(vars.item): lastBaseline = maxY - offset"
                )
            }
        }

        // 2. Sizes can never be negative (documented UIKit behaviour, engine-level
        //    inequality rather than an NSLayoutConstraint; spec §3.3).
        for item in items {
            guard let vars = variables[ObjectIdentifier(item as AnyObject)], !vars.isRoot else {
                continue
            }
            installRequired(Expression(vars.width), .greaterThanOrEqual, name: "width >= 0")
            installRequired(Expression(vars.height), .greaterThanOrEqual, name: "height >= 0")
        }

        // 3. The root is the container: fix its geometry. The solver works in the
        //    root's LOCAL coordinate space (origin 0,0 + the root's bounds size),
        //    because a subitem's `layoutFrame` is relative to its superitem. If the
        //    root's origin were pinned to its frame origin instead, every constraint
        //    inside a moved container would be offset by that origin.
        if let rootVariables = variables[ObjectIdentifier(root as AnyObject)] {
            let frame = root.layoutFrame
            installRequired(Expression(rootVariables.minX), .equal, name: "root: minX = 0")
            installRequired(Expression(rootVariables.minY), .equal, name: "root: minY = 0")
            if frame.width.isFinite {
                installRequired(Expression(rootVariables.width).minus(Expression(constant: Double(frame.width))),
                                .equal, name: "root: width = frame.width")
            }
            if frame.height.isFinite {
                installRequired(Expression(rootVariables.height).minus(Expression(constant: Double(frame.height))),
                                .equal, name: "root: height = frame.height")
            }
        }
    }

    // MARK: Autoresizing-mask translation

    /// Generates UIKit's autoresizing-mask constraints (spec §3.1). Runs before the
    /// user constraints so a conflicting explicit required constraint is the one
    /// that gets broken, matching UIKit.
    private func installAutoresizingConstraints() {
        let fallbackSuperviewSize = root.layoutFrame.size
        for item in items {
            guard let vars = variables[ObjectIdentifier(item as AnyObject)], !vars.isRoot else {
                continue
            }
            guard item.layoutTranslatesAutoresizingMaskIntoConstraints else {
                continue
            }
            let currentFrame = item.layoutFrame
            let currentSuperviewSize = superviewSize(of: item, fallback: fallbackSuperviewSize)
            let reference: LegacyAutoresizingReference
            if let stored = item.layoutAutoresizingReference,
               isFinite(stored.frame), isFinite(stored.superviewSize) {
                reference = stored
            } else {
                // First pass (or corrupt storage): generate from the current
                // geometry; this is also where UIKit lazily creates them.
                reference = LegacyAutoresizingReference(frame: currentFrame,
                                                        superviewSize: currentSuperviewSize)
            }
            guard isFinite(reference.frame), isFinite(reference.superviewSize) else {
                // Unusable geometry: fall back to pinning the current frame.
                pinFrame(vars, frame: currentFrame)
                continue
            }
            installHorizontalAutoresizingConstraints(vars: vars,
                                                     reference: reference,
                                                     superviewSize: reference.superviewSize)
            installVerticalAutoresizingConstraints(vars: vars,
                                                   reference: reference,
                                                   superviewSize: reference.superviewSize)
        }
    }

    /// Horizontal axis of the autoresizing translation.
    ///
    /// From the measured UIKit constraints (spec §3.1), with `(x0, w0)` the
    /// reference frame and `W0` the reference superview width:
    ///
    ///     .flexibleWidth:                      minX == x0
    ///                                          superview.width == maxX + (W0 - (x0 + w0))
    ///     .flexibleLeftMargin + rightMargin:   width == w0
    ///                                          minX == r * superview.width - r * w0   (r = x0 / (W0 - w0))
    ///     .flexibleLeftMargin only:            width == w0
    ///                                          superview.width == maxX + (W0 - (x0 + w0))
    ///     otherwise (right margin flexible/[]): width == w0; minX == x0
    private func installHorizontalAutoresizingConstraints(vars: ItemVariables,
                                                          reference: LegacyAutoresizingReference,
                                                          superviewSize: CGSize) {
        let frame = reference.frame
        let x0 = frame.minX
        let w0 = frame.width
        let superviewWidth = superviewSize.width
        let rightGap = superviewWidth - (x0 + w0)
        let mask = vars.item.layoutAutoresizingMask
        let superviewWidthExpression = widthExpression(ofSuperviewOf: vars)
            ?? Expression(constant: Double(superviewWidth))
        // The measured UIKit constraints are expressed in the superview's
        // coordinate space (`child.minX == x0`); this engine solves in absolute
        // root-local coordinates, so absolute-position equations subtract the
        // superview's origin variable.
        let superviewMinXExpression = minXExpression(ofSuperviewOf: vars) ?? Expression(constant: 0)
        let frameMinX = Expression(vars.minX).minus(superviewMinXExpression)

        if mask.contains(.flexibleWidth) {
            installRequired(frameMinX.minus(Expression(constant: Double(x0))),
                            .equal, name: "autoresizing: minX = x0")
            // superview.width == child.maxX(frame-relative) + right gap
            installRequired(superviewWidthExpression
                                .minus(Expression(vars.maxX))
                                .plus(superviewMinXExpression)
                                .minus(Expression(constant: Double(rightGap))),
                            .equal, name: "autoresizing: superview.width = maxX + right gap")
        } else if mask.contains(.flexibleLeftMargin) && mask.contains(.flexibleRightMargin) {
            let denominator = superviewWidth - w0
            let ratio = denominator != 0 ? x0 / denominator : 0
            installRequired(Expression(vars.width).minus(Expression(constant: Double(w0))),
                            .equal, name: "autoresizing: width = w0")
            // minX(frame-relative) == ratio * superview.width - ratio * w0
            installRequired(frameMinX
                                .minus(superviewWidthExpression.times(Double(ratio)))
                                .plus(Expression(constant: Double(ratio * w0))),
                            .equal, name: "autoresizing: proportional minX")
        } else if mask.contains(.flexibleLeftMargin) {
            installRequired(Expression(vars.width).minus(Expression(constant: Double(w0))),
                            .equal, name: "autoresizing: width = w0")
            installRequired(superviewWidthExpression
                                .minus(Expression(vars.maxX))
                                .plus(superviewMinXExpression)
                                .minus(Expression(constant: Double(rightGap))),
                            .equal, name: "autoresizing: superview.width = maxX + right gap")
        } else {
            installRequired(Expression(vars.width).minus(Expression(constant: Double(w0))),
                            .equal, name: "autoresizing: width = w0")
            installRequired(frameMinX.minus(Expression(constant: Double(x0))),
                            .equal, name: "autoresizing: minX = x0")
        }
    }

    /// Vertical axis of the autoresizing translation; symmetric to the horizontal
    /// one with `y`, `height`, `topMargin` and `bottomMargin`.
    private func installVerticalAutoresizingConstraints(vars: ItemVariables,
                                                        reference: LegacyAutoresizingReference,
                                                        superviewSize: CGSize) {
        let frame = reference.frame
        let y0 = frame.minY
        let h0 = frame.height
        let superviewHeight = superviewSize.height
        let bottomGap = superviewHeight - (y0 + h0)
        let mask = vars.item.layoutAutoresizingMask
        let superviewHeightExpression = heightExpression(ofSuperviewOf: vars)
            ?? Expression(constant: Double(superviewHeight))
        let superviewMinYExpression = minYExpression(ofSuperviewOf: vars) ?? Expression(constant: 0)
        let frameMinY = Expression(vars.minY).minus(superviewMinYExpression)

        if mask.contains(.flexibleHeight) {
            installRequired(frameMinY.minus(Expression(constant: Double(y0))),
                            .equal, name: "autoresizing: minY = y0")
            installRequired(superviewHeightExpression
                                .minus(Expression(vars.maxY))
                                .plus(superviewMinYExpression)
                                .minus(Expression(constant: Double(bottomGap))),
                            .equal, name: "autoresizing: superview.height = maxY + bottom gap")
        } else if mask.contains(.flexibleTopMargin) && mask.contains(.flexibleBottomMargin) {
            let denominator = superviewHeight - h0
            let ratio = denominator != 0 ? y0 / denominator : 0
            installRequired(Expression(vars.height).minus(Expression(constant: Double(h0))),
                            .equal, name: "autoresizing: height = h0")
            installRequired(frameMinY
                                .minus(superviewHeightExpression.times(Double(ratio)))
                                .plus(Expression(constant: Double(ratio * h0))),
                            .equal, name: "autoresizing: proportional minY")
        } else if mask.contains(.flexibleTopMargin) {
            installRequired(Expression(vars.height).minus(Expression(constant: Double(h0))),
                            .equal, name: "autoresizing: height = h0")
            installRequired(superviewHeightExpression
                                .minus(Expression(vars.maxY))
                                .plus(superviewMinYExpression)
                                .minus(Expression(constant: Double(bottomGap))),
                            .equal, name: "autoresizing: superview.height = maxY + bottom gap")
        } else {
            installRequired(Expression(vars.height).minus(Expression(constant: Double(h0))),
                            .equal, name: "autoresizing: height = h0")
            installRequired(frameMinY.minus(Expression(constant: Double(y0))),
                            .equal, name: "autoresizing: minY = y0")
        }
    }

    /// Pins all four attributes to `frame` (the degenerate fallback when the
    /// autoresizing geometry is unusable).
    private func pinFrame(_ vars: ItemVariables, frame: CGRect) {
        if frame.minX.isFinite {
            installRequired(Expression(vars.minX).minus(Expression(constant: Double(frame.minX))),
                            .equal, name: "fallback: minX")
        }
        if frame.minY.isFinite {
            installRequired(Expression(vars.minY).minus(Expression(constant: Double(frame.minY))),
                            .equal, name: "fallback: minY")
        }
        if frame.width.isFinite {
            installRequired(Expression(vars.width).minus(Expression(constant: Double(max(0, frame.width)))),
                            .equal, name: "fallback: width")
        }
        if frame.height.isFinite {
            installRequired(Expression(vars.height).minus(Expression(constant: Double(max(0, frame.height)))),
                            .equal, name: "fallback: height")
        }
    }

    /// The current size of an item's superview, used for autoresizing equations
    /// and for advancing the reference after a pass.
    private func superviewSize(of item: LegacyLayoutItem, fallback: CGSize) -> CGSize {
        guard let superitem = item.layoutSuperitem else {
            return fallback
        }
        let frame = superitem.layoutFrame
        if frame.width.isFinite, frame.height.isFinite {
            return frame.size
        }
        return fallback
    }

    private func minXExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superitem = vars.item.layoutSuperitem else {
            return nil
        }
        guard let superVariables = variables[ObjectIdentifier(superitem as AnyObject)] else {
            return nil
        }
        return Expression(superVariables.minX)
    }

    private func minYExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superitem = vars.item.layoutSuperitem else {
            return nil
        }
        guard let superVariables = variables[ObjectIdentifier(superitem as AnyObject)] else {
            return nil
        }
        return Expression(superVariables.minY)
    }

    private func widthExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superitem = vars.item.layoutSuperitem else {
            return nil
        }
        guard let superVariables = variables[ObjectIdentifier(superitem as AnyObject)] else {
            return nil
        }
        return Expression(superVariables.width)
    }

    private func heightExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superitem = vars.item.layoutSuperitem else {
            return nil
        }
        guard let superVariables = variables[ObjectIdentifier(superitem as AnyObject)] else {
            return nil
        }
        return Expression(superVariables.height)
    }

    // MARK: Stays

    /// Weak stay constraints pinning each non-root item's absolute position and
    /// size to its current geometry (root-local coordinates). See the header
    /// comment: this keeps ancestor-derived geometry stable across the per-view
    /// layout passes the UIKit bridge drives. Fully determined layouts are
    /// unaffected because `.weak` is below every user priority.
    private func installStays() {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        let stayStrength = Strength.create(0, 0, 1)
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier {
                absoluteOrigins[identifier] = CGPoint(x: 0, y: 0)
                continue
            }
            let currentFrame = item.layoutFrame
            let parentAbsolute = parentAbsoluteOrigin(of: item, absoluteOrigins: absoluteOrigins)
            let absoluteX = parentAbsolute.x + (currentFrame.minX.isFinite ? currentFrame.minX : 0)
            let absoluteY = parentAbsolute.y + (currentFrame.minY.isFinite ? currentFrame.minY : 0)
            absoluteOrigins[identifier] = CGPoint(x: absoluteX, y: absoluteY)
            guard let vars = variables[identifier] else {
                continue
            }
            if currentFrame.minX.isFinite {
                install(Expression(vars.minX).minus(Expression(constant: Double(absoluteX))),
                        .equal, strength: stayStrength, name: "stay: minX")
            }
            if currentFrame.minY.isFinite {
                install(Expression(vars.minY).minus(Expression(constant: Double(absoluteY))),
                        .equal, strength: stayStrength, name: "stay: minY")
            }
            if currentFrame.width.isFinite {
                install(Expression(vars.width).minus(Expression(constant: Double(max(0, currentFrame.width)))),
                        .equal, strength: stayStrength, name: "stay: width")
            }
            if currentFrame.height.isFinite {
                install(Expression(vars.height).minus(Expression(constant: Double(max(0, currentFrame.height)))),
                        .equal, strength: stayStrength, name: "stay: height")
            }
        }
    }

    // MARK: User constraints

    private func installUserConstraints() {
        let constraints = collectConstraints()
        var required: [CompiledConstraint] = []
        var optional: [CompiledConstraint] = []
        for constraint in constraints {
            guard let compiled = compile(constraint) else {
                continue
            }
            if compiled.isRequired {
                required.append(compiled)
            } else {
                optional.append(compiled)
            }
        }

        // Required first. A required constraint that cannot be satisfied is
        // recorded as broken and re-added at the documented "broken" strength so
        // it still influences the solve as the first thing to satisfy.
        for compiled in required {
            if install(compiled.expression, compiled.operator, strength: compiled.strength, name: compiled.name) {
                continue
            }
            brokenConstraints.append(compiled.source)
            // Use a distinct Expression instance for the retry so the solver never
            // sees the same row object twice.
            let relaxedExpression = compiled.expression.plus(Expression(constant: 0))
            _ = install(relaxedExpression, compiled.operator,
                        strength: LegacyLayoutSolver.brokenStrength,
                        name: compiled.name)
        }

        // Intrinsic content size constraints are optional; they rank with the
        // item's hugging / compression-resistance priorities.
        installIntrinsicContentConstraints()

        // Then the user's optional constraints, at their mapped strengths.
        for compiled in optional {
            _ = install(compiled.expression, compiled.operator, strength: compiled.strength, name: compiled.name)
        }
    }

    /// Constraints owned by any item of the subtree, plus activated constraints
    /// that reference a subtree item, de-duplicated by object identity.
    private func collectConstraints() -> [RRLayoutConstraint] {
        var seen: Set<ObjectIdentifier> = []
        var result: [RRLayoutConstraint] = []
        for item in items {
            for constraint in item.layoutConstraints {
                let identifier = ObjectIdentifier(constraint)
                if seen.insert(identifier).inserted {
                    result.append(constraint)
                }
            }
        }
        for constraint in LegacyActiveConstraintRegistry.shared.activeConstraints() {
            let identifier = ObjectIdentifier(constraint)
            if seen.contains(identifier) {
                continue
            }
            if constraintReferencesSubtreeItem(constraint) {
                seen.insert(identifier)
                result.append(constraint)
            }
        }
        return result
    }

    private func constraintReferencesSubtreeItem(_ constraint: RRLayoutConstraint) -> Bool {
        if let firstObject = constraint.firstItem as AnyObject?,
           itemIdentifiers.contains(ObjectIdentifier(firstObject)) {
            return true
        }
        if let secondObject = constraint.secondItem as AnyObject?,
           itemIdentifiers.contains(ObjectIdentifier(secondObject)) {
            return true
        }
        return false
    }

    // MARK: Constraint translation

    /// Translates one `RRLayoutConstraint`. Returns `nil` when the constraint must
    /// be skipped (outside the subtree, deallocated item, unsupported attribute);
    /// unsupported/malformed constraints are additionally recorded as broken.
    private func compile(_ constraint: RRLayoutConstraint) -> CompiledConstraint? {
        guard constraint.firstAttribute != .notAnAttribute else {
            // Creation-time validation makes this unreachable for constraints made
            // through the public initializer; keep the guard for decoded/old data.
            brokenConstraints.append(constraint)
            return nil
        }
        guard constraint.multiplier.isFinite, constraint.constant.isFinite else {
            brokenConstraints.append(constraint)
            return nil
        }
        guard let firstObject = constraint.firstItem as AnyObject?,
              let firstVariables = variables[ObjectIdentifier(firstObject)] else {
            // nil / deallocated first item or item outside the solved subtree.
            return nil
        }
        guard let firstExpression = expression(for: firstVariables, attribute: constraint.firstAttribute) else {
            brokenConstraints.append(constraint)
            return nil
        }

        let multiplier = Double(constraint.multiplier)
        let constant = Double(constraint.constant)

        var rhs = Expression(constant: 0)

        if let secondObject = constraint.secondItem as AnyObject? {
            guard constraint.secondAttribute != .notAnAttribute else {
                // A second item with notAnAttribute is not a valid pair.
                brokenConstraints.append(constraint)
                return nil
            }
            guard let secondVariables = variables[ObjectIdentifier(secondObject)] else {
                // The constraint belongs to an ancestor's layout pass.
                return nil
            }
            guard let secondExpression = expression(for: secondVariables,
                                                    attribute: constraint.secondAttribute) else {
                brokenConstraints.append(constraint)
                return nil
            }
            // Algebra only: firstAttribute <rel> multiplier * secondAttribute + constant.
            rhs = secondExpression.times(multiplier)
        } else {
            // Constant constraint (`secondItem == nil`, secondAttribute must be
            // notAnAttribute). UIKit ignores the multiplier here (spec §2.2/§2.3),
            // so the RHS stays 0 and only the constant contributes.
            guard constraint.secondAttribute == .notAnAttribute else {
                brokenConstraints.append(constraint)
                return nil
            }
        }

        // RTL: the directional attributes increase towards the trailing (leftward)
        // edge, so the constant is mirrored whenever either side uses
        // leading/trailing. The edge mapping itself already swapped leading and
        // trailing; only the constant needs the sign flip. See the header for the
        // simulator-verified table. Relation and multiplier are unchanged.
        var signedConstant = constant
        var resolvedOperator = relationalOperator(for: constraint.relation)
        if direction == .rightToLeft,
           isDirectional(constraint.firstAttribute) || isDirectional(constraint.secondAttribute) {
            signedConstant = -constant
            // Mirroring a directional inequality reverses it:
            //   a.leading >= c.leading + 40  <=>  (M-a.maxX) >= (M-c.maxX)+40
            //                                <=>  a.maxX <= c.maxX - 40
            if constraint.relation != .equal {
                resolvedOperator = (resolvedOperator == .lessThanOrEqual)
                    ? .greaterThanOrEqual
                    : .lessThanOrEqual
            }
        }

        // firstExpr - multiplier * secondExpr - constant <op> 0
        let expression = firstExpression.minus(rhs)
        expression.constant -= signedConstant

        return CompiledConstraint(source: constraint,
                                  expression: expression,
                                  operator: resolvedOperator,
                                  strength: RRLayoutPriorityMapping.strength(for: constraint.priority),
                                  name: constraint.identifier)
    }

    /// The expression for an attribute on an item, or `nil` when the item cannot
    /// provide that attribute (unsupported baseline).
    private func expression(for variables: ItemVariables, attribute: RRLayoutAttribute) -> Expression? {
        switch attribute {
        case .notAnAttribute:
            return nil
        case .left:
            return Expression(variables.minX)
        case .right:
            return Expression(variables.maxX)
        case .leading:
            if direction == .leftToRight {
                return Expression(variables.minX)
            }
            return Expression(variables.maxX)
        case .trailing:
            if direction == .leftToRight {
                return Expression(variables.maxX)
            }
            return Expression(variables.minX)
        case .top:
            return Expression(variables.minY)
        case .bottom:
            return Expression(variables.maxY)
        case .width:
            return Expression(variables.width)
        case .height:
            return Expression(variables.height)
        case .centerX:
            return Expression(variables.centerX)
        case .centerY:
            return Expression(variables.centerY)
        case .firstBaseline:
            // Only supported when the item exposes baseline metrics; a plain view
            // has no baseline and no equation was installed for its variable.
            guard finite(variables.item.layoutFirstBaselineOffsetFromTop) != nil else {
                return nil
            }
            return Expression(variables.firstBaseline)
        case .lastBaseline:
            guard finite(variables.item.layoutLastBaselineOffsetFromBottom) != nil else {
                return nil
            }
            return Expression(variables.lastBaseline)
        }
    }

    private func isDirectional(_ attribute: RRLayoutAttribute) -> Bool {
        return attribute == .leading || attribute == .trailing
    }

    private func relationalOperator(for relation: RRLayoutRelation) -> RelationalOperator {
        switch relation {
        case .lessThanOrEqual:
            return .lessThanOrEqual
        case .equal:
            return .equal
        case .greaterThanOrEqual:
            return .greaterThanOrEqual
        }
    }

    // MARK: Intrinsic content size

    /// Adds the implicit intrinsic-size constraints at the item's content hugging
    /// and compression-resistance priorities:
    ///
    ///     width  >= intrinsicWidth  @ compression resistance (horizontal)
    ///     width  <= intrinsicWidth  @ hugging (horizontal)
    ///     height >= intrinsicHeight @ compression resistance (vertical)
    ///     height <= intrinsicHeight @ hugging (vertical)
    ///
    /// `UIViewNoIntrinsicMetric` (`-1`) means "no intrinsic size on this axis".
    private func installIntrinsicContentConstraints() {
        for item in items {
            guard let vars = variables[ObjectIdentifier(item as AnyObject)], !vars.isRoot else {
                continue
            }
            let intrinsicSize = item.layoutIntrinsicContentSize
            if intrinsicSize.width >= 0 && intrinsicSize.width.isFinite {
                let value = Double(intrinsicSize.width)
                let compression = item.layoutContentCompressionResistancePriority(for: .horizontal)
                install(Expression(vars.width).minus(Expression(constant: value)),
                        .greaterThanOrEqual,
                        strength: RRLayoutPriorityMapping.strength(for: compression),
                        name: "intrinsic width >= \(value)")
                let hugging = item.layoutContentHuggingPriority(for: .horizontal)
                install(Expression(vars.width).minus(Expression(constant: value)),
                        .lessThanOrEqual,
                        strength: RRLayoutPriorityMapping.strength(for: hugging),
                        name: "intrinsic width <= \(value)")
            }
            if intrinsicSize.height >= 0 && intrinsicSize.height.isFinite {
                let value = Double(intrinsicSize.height)
                let compression = item.layoutContentCompressionResistancePriority(for: .vertical)
                install(Expression(vars.height).minus(Expression(constant: value)),
                        .greaterThanOrEqual,
                        strength: RRLayoutPriorityMapping.strength(for: compression),
                        name: "intrinsic height >= \(value)")
                let hugging = item.layoutContentHuggingPriority(for: .vertical)
                install(Expression(vars.height).minus(Expression(constant: value)),
                        .lessThanOrEqual,
                        strength: RRLayoutPriorityMapping.strength(for: hugging),
                        name: "intrinsic height <= \(value)")
            }
        }
    }

    // MARK: Solver helpers

    /// Installs a constraint that the solver must not sacrifice (implicit /
    /// system-generated). Failures are ignored: they can only happen when the
    /// system equations are violated, which the engine handles by continuing.
    @discardableResult
    private func installRequired(_ expression: Expression,
                                 _ op: RelationalOperator,
                                 name: String?) -> Bool {
        return install(expression, op, strength: .required, name: name)
    }

    /// Installs one constraint. Returns `false` if the solver rejected it
    /// (unsatisfiable required constraint or solver error); the engine then skips
    /// it and keeps going.
    @discardableResult
    private func install(_ expression: Expression,
                         _ op: RelationalOperator,
                         strength: Strength,
                         name: String?) -> Bool {
        let constraint = Constraint(expression, op, strength: strength, name: name)
        do {
            try solver.addConstraint(constraint)
            return true
        } catch {
            return false
        }
    }

    // MARK: Result extraction

    private func extractResult(writingFrames: Bool) -> LegacyLayoutResult {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)

        // Absolute (solver / root-local) origins and solved sizes per item.
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        var solvedSizes: [ObjectIdentifier: CGSize] = [:]
        var currentFrames: [ObjectIdentifier: CGRect] = [:]

        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier {
                let rootFrame = item.layoutFrame
                absoluteOrigins[identifier] = CGPoint(x: 0, y: 0)
                solvedSizes[identifier] = CGSize(width: rootFrame.width.isFinite ? rootFrame.width : 0,
                                                 height: rootFrame.height.isFinite ? rootFrame.height : 0)
                // The root's frame is returned (and kept) unchanged: it is the
                // container and Auto Layout does not resize it in this pass.
                currentFrames[identifier] = rootFrame
                continue
            }
            guard let vars = variables[identifier] else {
                currentFrames[identifier] = item.layoutFrame
                continue
            }
            let minX = solver.value(of: vars.minX)
            let minY = solver.value(of: vars.minY)
            let width = solver.value(of: vars.width)
            let height = solver.value(of: vars.height)
            let parentAbsolute = parentAbsoluteOrigin(of: item, absoluteOrigins: absoluteOrigins)
            if minX.isFinite && minY.isFinite && width.isFinite && height.isFinite {
                // Clamp tiny negative sizes produced by floating-point error;
                // widths/heights are also required >= 0 in the system.
                let clampedWidth = max(0, width)
                let clampedHeight = max(0, height)
                absoluteOrigins[identifier] = CGPoint(x: minX, y: minY)
                solvedSizes[identifier] = CGSize(width: clampedWidth, height: clampedHeight)
                // layoutFrame is in superitem coordinates: subtract the parent's
                // solved absolute origin.
                currentFrames[identifier] = CGRect(x: minX - parentAbsolute.x,
                                                   y: minY - parentAbsolute.y,
                                                   width: clampedWidth,
                                                   height: clampedHeight)
            } else {
                // Non-finite solution: keep the current frame for this item.
                let fallback = item.layoutFrame
                absoluteOrigins[identifier] = CGPoint(x: parentAbsolute.x + fallback.minX,
                                                      y: parentAbsolute.y + fallback.minY)
                solvedSizes[identifier] = fallback.size
                currentFrames[identifier] = fallback
            }
        }

        // Write frames back (root untouched) and advance autoresizing references.
        // Both only happen for a real layout pass, not for `solve`.
        if writingFrames {
            for item in items {
                let identifier = ObjectIdentifier(item as AnyObject)
                if identifier == rootIdentifier {
                    continue
                }
                guard let frame = currentFrames[identifier], frame.minX.isFinite,
                      frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else {
                    continue
                }
                item.layoutSetFrame(frame)
            }
            for item in items {
                let identifier = ObjectIdentifier(item as AnyObject)
                if identifier == rootIdentifier {
                    continue
                }
                guard item.layoutTranslatesAutoresizingMaskIntoConstraints,
                      let frame = currentFrames[identifier] else {
                    continue
                }
                let superviewSize = solvedSuperviewSize(of: item,
                                                        frames: currentFrames,
                                                        sizes: solvedSizes)
                item.layoutUpdateAutoresizingReference(LegacyAutoresizingReference(frame: frame,
                                                                                   superviewSize: superviewSize))
            }
        }

        var frames: [ObjectIdentifier: CGRect] = [:]
        var resolved: [ObjectIdentifier: LegacyResolvedFrame] = [:]
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard let frame = currentFrames[identifier] else {
                continue
            }
            frames[identifier] = frame
            resolved[identifier] = resolvedFrame(from: frame, item: item)
        }

        return LegacyLayoutResult(frames: frames,
                                  brokenConstraints: brokenConstraints,
                                  resolvedAttributes: resolved)
    }

    /// The item's superitem origin in root-local coordinates.
    private func parentAbsoluteOrigin(of item: LegacyLayoutItem,
                                      absoluteOrigins: [ObjectIdentifier: CGPoint]) -> CGPoint {
        guard let superitem = item.layoutSuperitem else {
            return CGPoint(x: 0, y: 0)
        }
        let identifier = ObjectIdentifier(superitem as AnyObject)
        return absoluteOrigins[identifier] ?? CGPoint(x: 0, y: 0)
    }

    /// The superview size after the pass: the solved superview size when the
    /// superview was part of the subtree, else the current frame size.
    private func solvedSuperviewSize(of item: LegacyLayoutItem,
                                     frames: [ObjectIdentifier: CGRect],
                                     sizes: [ObjectIdentifier: CGSize]) -> CGSize {
        guard let superitem = item.layoutSuperitem else {
            return root.layoutFrame.size
        }
        let identifier = ObjectIdentifier(superitem as AnyObject)
        if let size = sizes[identifier], size.width.isFinite, size.height.isFinite {
            return size
        }
        let current = superitem.layoutFrame.size
        if current.width.isFinite, current.height.isFinite {
            return current
        }
        return root.layoutFrame.size
    }

    private func resolvedFrame(from frame: CGRect, item: LegacyLayoutItem) -> LegacyResolvedFrame {
        // Baselines are positions, not stored geometry; derive them from the
        // written frame and the item's content metrics (a missing provider falls
        // back to the top/bottom edge for this debug struct only -- baseline
        // CONSTRAINTS on such an item are recorded as broken and never solved).
        let firstBaseline = frame.minY + (finite(item.layoutFirstBaselineOffsetFromTop) ?? 0)
        let lastBaseline = frame.maxY - (finite(item.layoutLastBaselineOffsetFromBottom) ?? 0)
        return LegacyResolvedFrame(
            leading: frame.minX,
            trailing: frame.maxX,
            top: frame.minY,
            bottom: frame.maxY,
            width: frame.width,
            height: frame.height,
            centerX: frame.midX,
            centerY: frame.midY,
            firstBaseline: firstBaseline,
            lastBaseline: lastBaseline
        )
    }

    // MARK: Numeric helpers

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value = value, value.isFinite else {
            return nil
        }
        return value
    }

    private func isFinite(_ frame: CGRect) -> Bool {
        return frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    private func isFinite(_ size: CGSize) -> Bool {
        return size.width.isFinite && size.height.isFinite
    }
}
