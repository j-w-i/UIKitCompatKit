//
//  LegacyLayoutEngine.swift
//  LegacyAutoLayout
//
//  The UIKit-decoupled constraint-based layout pass for the RRAutoLayout port.
//
//  RRAutoLayout (MIT, Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>)
//  implemented `layoutSubviews` as an ad-hoc per-view walk that applied
//  `CGRectAddAttribute` arithmetic in whatever order the constraints happened to
//  be in, with the author explicitly noting it "needs rewrite" because the result
//  depended on the view hierarchy and on the order attributes were visited. This
//  engine replaces that rectangle math with a real Cassowary solve (the algorithm
//  Auto Layout itself uses), while keeping RRAutoLayout's call model: collect the
//  subtree and the constraints attached to it, solve, then write frames back.
//
//  Public API is the contract from docs/legacy-autolayout.md §5.
//

import Foundation
import CoreGraphics

/// The direction in which `leading`/`trailing` attributes are resolved.
///
/// UIKit derives this from `UIApplication.userInterfaceLayoutDirection` (or from
/// the view's semantic content attribute); the bridge passes it to the engine.
public enum RRLayoutDirection: Hashable {
    /// `leading` is the left edge, `trailing` the right edge.
    case leftToRight
    /// `leading` is the right edge, `trailing` the left edge.
    case rightToLeft
}

/// A solved frame in terms of the attributes Auto Layout exposed.
///
/// All values are physical (not direction-relative): `leading` is the minimum X
/// and `trailing` the maximum X regardless of the engine direction, matching the
/// `CGRect` the frame is written back as. Kept for tests/debugging; the frame in
/// `LegacyLayoutResult.frames` is authoritative.
public struct LegacyResolvedFrame {
    public var leading: CGFloat
    public var trailing: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var centerX: CGFloat
    public var centerY: CGFloat
    public var firstBaseline: CGFloat
    public var lastBaseline: CGFloat

    public init(leading: CGFloat,
                trailing: CGFloat,
                top: CGFloat,
                bottom: CGFloat,
                width: CGFloat,
                height: CGFloat,
                centerX: CGFloat,
                centerY: CGFloat,
                firstBaseline: CGFloat,
                lastBaseline: CGFloat) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
        self.width = width
        self.height = height
        self.centerX = centerX
        self.centerY = centerY
        self.firstBaseline = firstBaseline
        self.lastBaseline = lastBaseline
    }
}

/// The result of one layout pass.
public struct LegacyLayoutResult {

    /// Final frames keyed by `ObjectIdentifier(item)`. The root's frame is
    /// included unchanged (the root is the container; the engine does not resize
    /// it). These are the frames that were (or, for `solve`, would be) written.
    public var frames: [ObjectIdentifier: CGRect]

    /// Constraints Auto Layout would log as broken: required constraints that
    /// could not be satisfied together with the already-installed system, or
    /// constraints that are structurally invalid (e.g. no first item, a missing
    /// second attribute, a non-finite constant). Optional constraints that lose a
    /// priority fight are *not* broken -- they are simply not satisfied.
    public var brokenConstraints: [RRLayoutConstraint]

    /// Last solved value per item, for debugging/tests. Frames agree with these.
    public var resolvedAttributes: [ObjectIdentifier: LegacyResolvedFrame]

    public init(frames: [ObjectIdentifier: CGRect] = [:],
                brokenConstraints: [RRLayoutConstraint] = [],
                resolvedAttributes: [ObjectIdentifier: LegacyResolvedFrame] = [:]) {
        self.frames = frames
        self.brokenConstraints = brokenConstraints
        self.resolvedAttributes = resolvedAttributes
    }
}

/// The legacy constraint-based layout engine.
///
/// Usage:
///
///     let engine = LegacyLayoutEngine()
///     let result = engine.layout(rootItem)   // solves and writes frames
///     let dryRun = engine.solve(rootItem)    // solves only
///
/// The engine is not tied to UIKit and does not swizzle anything. On modern
/// systems the UIKit bridge never calls it; it exists so the legacy path (and
/// explicit `legacy*` API users) get real Auto Layout behaviour.
///
/// Coordinate space: it solves internally in the root's local coordinate space,
/// but every `CGRect` it writes through `layoutSetFrame` -- and every frame in
/// `LegacyLayoutResult.frames`/`resolvedAttributes` -- is in the item's
/// *superitem* coordinate space, exactly like `UIView.frame`. The root's frame is
/// returned unchanged.
///
/// Documented limitations (not bugs, see `LegacyLayoutSolver` for details):
/// * intrinsic content size is modelled as the two Apple-documented inequalities
///   at the hugging / compression-resistance priorities, not as an edit variable,
///   so a user priority above 750 can out-rank compression resistance in ways
///   real UIKit's private content-size constraint might not;
/// * the Auto Layout Guide's "no nonidentity multiplier with location attributes"
///   rule is not enforced (the probed UIKit SDK does not enforce it either);
/// * under-constrained geometry is kept stable across the per-view passes the
///   bridge drives by solver-internal weak "stay" constraints, mirroring UIKit's
///   per-window engine and its incumbent-solution tie-break.
public final class LegacyLayoutEngine {

    /// The direction used to resolve `leading`/`trailing`. Default `.leftToRight`.
    public var direction: RRLayoutDirection

    public init(direction: RRLayoutDirection = .leftToRight) {
        self.direction = direction
    }

    /// Builds and solves the constraint system for the whole subtree rooted at
    /// `root`, then writes each item's frame (in superitem coordinates) back via
    /// `layoutSetFrame`. The root's frame is fixed and left untouched.
    @discardableResult
    public func layout(_ root: LegacyLayoutItem) -> LegacyLayoutResult {
        let solver = LegacyLayoutSolver(root: root, direction: direction)
        return solver.solve(writingFrames: true)
    }

    /// Same solve as `layout(_:)` but performs no write-back. Used by parity tests
    /// and by callers that need the frames before committing them.
    public func solve(_ root: LegacyLayoutItem) -> LegacyLayoutResult {
        let solver = LegacyLayoutSolver(root: root, direction: direction)
        return solver.solve(writingFrames: false)
    }
}
