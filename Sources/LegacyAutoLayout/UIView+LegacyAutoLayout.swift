//
//  UIView+LegacyAutoLayout.swift
//  LegacyAutoLayout
//
//  UIView side of the legacy Auto Layout backport: associated-object constraint storage,
//  translatesAutoresizingMask/intrinsic-size/hugging/compression backports and the
//  `LegacyLayoutItem` conformance consumed by `LegacyLayoutEngine`.
//
//  Ported from RRAutoLayout's UIView+RRConstraintBasedLayout (Classes/View) and
//  RRLayoutConstraint (Classes/Module):
//    Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this
//  software and associated documentation files (the "Software"), to deal in the Software
//  without restriction, including without limitation the rights to use, copy, modify,
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//  permit persons to whom the Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be included in all copies
//  or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
//  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
//  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import UIKit
import ObjectiveC

// MARK: - Associated object keys

/// One stable address per piece of associated storage. Taking the address of a Swift `static var`
/// yields a process-wide unique `UnsafeRawPointer`, which is exactly what `objc_getAssociatedObject`
/// wants as its key (the same "unique static key per property" idiom RRAutoLayout got from string
/// literals in ObjC).
private enum LegacyAutoLayoutKeys {
    static var constraints: UInt8 = 0
    static var translatesAutoresizingMaskIntoConstraints: UInt8 = 0
    static var intrinsicContentSize: UInt8 = 0
    static var contentHuggingPriorityHorizontal: UInt8 = 0
    static var contentHuggingPriorityVertical: UInt8 = 0
    static var contentCompressionResistancePriorityHorizontal: UInt8 = 0
    static var contentCompressionResistancePriorityVertical: UInt8 = 0
    static var firstBaselineOffsetFromTop: UInt8 = 0
    static var lastBaselineOffsetFromBottom: UInt8 = 0
    static var constraintsAreClean: UInt8 = 0
    static var needsLayout: UInt8 = 0
    static var translatedAutoresizingConstraints: UInt8 = 0
    static var autoresizingReference: UInt8 = 0
}

/// Default values that exist even when no associated object has ever been stored.
private enum LegacyAutoLayoutDefaults {
    static let translatesAutoresizingMaskIntoConstraints = true
    static let contentHuggingPriority: CGFloat = 250 // RRLayoutPriorityDefaultLow
    static let contentCompressionResistancePriority: CGFloat = 750 // RRLayoutPriorityDefaultHigh
    static let intrinsicContentSize = CGSize(
        width: LegacyLayoutMetrics.noIntrinsicMetric,
        height: LegacyLayoutMetrics.noIntrinsicMetric
    )
    static let baselineOffset: CGFloat = 0
}

// MARK: - Associated storage helpers

/// Boxes `LegacyAutoresizingReference` so it can live in an associated object.
private final class LegacyAutoresizingReferenceBox: NSObject {

    let reference: LegacyAutoresizingReference

    init(_ reference: LegacyAutoresizingReference) {
        self.reference = reference
    }
}

/// Drops the captured autoresizing reference so the next layout pass re-captures the current geometry.
///
/// UIKit regenerates its autoresizing constraints from the view's current frame; the backport captures
/// that geometry once and lets the engine refresh it after a successful pass. Any change that can move
/// the view or change what its autoresizing constraints should be (translates flag flip, added or
/// removed constraints) invalidates the captured reference.
@MainActor
internal func legacyClearAutoresizingReference(_ view: UIView) {
    objc_setAssociatedObject(
        view,
        &LegacyAutoLayoutKeys.autoresizingReference,
        nil,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func legacyConstraintStorage(_ view: UIView) -> NSMutableArray {
    if let storage = objc_getAssociatedObject(view, &LegacyAutoLayoutKeys.constraints) as? NSMutableArray {
        return storage
    }
    let storage = NSMutableArray()
    objc_setAssociatedObject(
        view,
        &LegacyAutoLayoutKeys.constraints,
        storage,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return storage
}

/// Copies the ObjC constraint array into a Swift array without using `NSArray`'s `Sequence`
/// conformance (that conformance is iOS 8+; this package supports deployment targets from iOS 5).
private func legacyConstraintArray(from storage: NSMutableArray) -> [RRLayoutConstraint] {
    var constraints: [RRLayoutConstraint] = []
    constraints.reserveCapacity(storage.count)
    for index in 0..<storage.count {
        if let constraint = storage.object(at: index) as? RRLayoutConstraint {
            constraints.append(constraint)
        }
    }
    return constraints
}

private func legacyCGFloat(forKey key: UnsafeRawPointer, on view: UIView, default defaultValue: CGFloat) -> CGFloat {
    guard let number = objc_getAssociatedObject(view, key) as? NSNumber else { return defaultValue }
    return CGFloat(number.doubleValue)
}

/// The RRAutoLayout-compatible UIView surface plus the `LegacyLayoutItem` mapping.
///
/// Everything here is `@MainActor`: UIKit's own layout APIs are main-actor isolated and the bridge
/// must never run a layout pass off the main thread (docs §6 "Threading").
@MainActor
public extension UIView {

    // MARK: Constraint storage (the `-[UIView constraints]` equivalent)

    /// Constraints owned by this view for the legacy path — the backport equivalent of `-[UIView constraints]`.
    ///
    /// This never reads or writes the system `NSLayoutConstraint` machinery: on iOS 6+ the real
    /// `constraints` array stays untouched by every `legacy*` API.
    var legacyConstraints: [RRLayoutConstraint] {
        legacyConstraintArray(from: legacyConstraintStorage(self))
    }

    /// Adds a constraint to this view's legacy storage, keeping the storage ordered by priority.
    ///
    /// Mirrors RRAutoLayout: the constraint is appended, the array is re-sorted ascending by priority,
    /// then the view (and its container) are marked as needing a constraint update/layout.
    func legacyAddConstraint(_ constraint: RRLayoutConstraint) {
        LegacyAutoLayout.ensureInstalled()
        let storage = legacyConstraintStorage(self)
        var alreadyContainsConstraint = false
        for index in 0..<storage.count {
            if (storage.object(at: index) as AnyObject) === constraint {
                alreadyContainsConstraint = true
                break
            }
        }
        if !alreadyContainsConstraint {
            storage.add(constraint)
        }
        // RRAutoLayout sorts by priority so lower-priority constraints are applied last.
        let sorted = legacyConstraintArray(from: storage).sorted { $0.priority < $1.priority }
        storage.removeAllObjects()
        for sortedConstraint in sorted {
            storage.add(sortedConstraint)
        }
        // Constraint changes can change the solved geometry; force a fresh autoresizing capture.
        legacyClearAutoresizingReference(self)
        legacySetNeedsUpdateConstraints()
    }

    /// Adds several constraints through `legacyAddConstraint(_:)`.
    func legacyAddConstraints(_ constraints: [RRLayoutConstraint]) {
        LegacyAutoLayout.ensureInstalled()
        for constraint in constraints {
            legacyAddConstraint(constraint)
        }
    }

    /// Removes `constraint` from this view's legacy storage (identity comparison, like UIKit).
    func legacyRemoveConstraint(_ constraint: RRLayoutConstraint) {
        let storage = legacyConstraintStorage(self)
        var indexToRemove: Int?
        for index in 0..<storage.count {
            if (storage.object(at: index) as AnyObject) === constraint {
                indexToRemove = index
                break
            }
        }
        guard let index = indexToRemove else { return }
        storage.removeObject(at: index)
        legacyClearAutoresizingReference(self)
        legacySetNeedsUpdateConstraints()
    }

    /// Removes several constraints through `legacyRemoveConstraint(_:)`.
    func legacyRemoveConstraints(_ constraints: [RRLayoutConstraint]) {
        for constraint in constraints {
            legacyRemoveConstraint(constraint)
        }
    }

    // MARK: translatesAutoresizingMaskIntoConstraints

    /// Backport of `translatesAutoresizingMaskIntoConstraints` (associated storage; default `true`).
    ///
    /// Defaulting to `true` is what makes the backport a drop-in replacement: views created in code or
    /// loaded from a nib before Auto Layout existed rely on their autoresizing mask/frame, and the
    /// engine pins their current frame exactly like UIKit's translation step does (docs §5.3).
    var legacyTranslatesAutoresizingMaskIntoConstraints: Bool {
        get {
            guard let number = objc_getAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.translatesAutoresizingMaskIntoConstraints
            ) as? NSNumber else {
                return LegacyAutoLayoutDefaults.translatesAutoresizingMaskIntoConstraints
            }
            return number.boolValue
        }
        set {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.translatesAutoresizingMaskIntoConstraints,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            // A flag flip changes whether (and from which geometry) autoresizing constraints are
            // generated, so the captured reference is stale.
            legacyClearAutoresizingReference(self)
            legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Intrinsic content size

    /// Backport of `intrinsicContentSize` (associated storage; default `UIViewNoIntrinsicMetric`).
    var legacyIntrinsicContentSize: CGSize {
        get {
            guard let value = objc_getAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.intrinsicContentSize
            ) as? NSValue else {
                return LegacyAutoLayoutDefaults.intrinsicContentSize
            }
            return value.cgSizeValue
        }
        set {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.intrinsicContentSize,
                NSValue(cgSize: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Content hugging / compression resistance

    /// Content hugging priority backport. Defaults to `RRLayoutPriorityDefaultLow` (250) on both axes,
    /// matching UIKit.
    func legacyContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        if axis == .horizontal {
            return RRLayoutPriority(legacyCGFloat(
                forKey: &LegacyAutoLayoutKeys.contentHuggingPriorityHorizontal,
                on: self,
                default: LegacyAutoLayoutDefaults.contentHuggingPriority
            ))
        }
        return RRLayoutPriority(legacyCGFloat(
            forKey: &LegacyAutoLayoutKeys.contentHuggingPriorityVertical,
            on: self,
            default: LegacyAutoLayoutDefaults.contentHuggingPriority
        ))
    }

    func legacySetContentHuggingPriority(_ priority: RRLayoutPriority, for axis: RRLayoutAxis) {
        if axis == .horizontal {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.contentHuggingPriorityHorizontal,
                NSNumber(value: priority),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.contentHuggingPriorityVertical,
                NSNumber(value: priority),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        // UIKit treats a hugging-priority change as an intrinsic-size invalidation.
        legacySetNeedsUpdateConstraints()
    }

    /// Content compression resistance priority backport. Defaults to `RRLayoutPriorityDefaultHigh`
    /// (750) on both axes, matching UIKit.
    func legacyContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        if axis == .horizontal {
            return RRLayoutPriority(legacyCGFloat(
                forKey: &LegacyAutoLayoutKeys.contentCompressionResistancePriorityHorizontal,
                on: self,
                default: LegacyAutoLayoutDefaults.contentCompressionResistancePriority
            ))
        }
        return RRLayoutPriority(legacyCGFloat(
            forKey: &LegacyAutoLayoutKeys.contentCompressionResistancePriorityVertical,
            on: self,
            default: LegacyAutoLayoutDefaults.contentCompressionResistancePriority
        ))
    }

    func legacySetContentCompressionResistancePriority(_ priority: RRLayoutPriority, for axis: RRLayoutAxis) {
        if axis == .horizontal {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.contentCompressionResistancePriorityHorizontal,
                NSNumber(value: priority),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.contentCompressionResistancePriorityVertical,
                NSNumber(value: priority),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        legacySetNeedsUpdateConstraints()
    }

    // MARK: Baselines

    /// Backport of `firstBaselineOffsetFromTop` (associated storage; default `0`).
    ///
    /// The value is stored unconditionally, but the `LegacyLayoutItem` conformance reports a baseline
    /// only once a caller has explicitly set one: a plain `UIView` has no cross-view baseline
    /// participation, so "unset" maps to the protocol's `nil` ("no baseline support"), which keeps the
    /// engine from inventing baseline equations for every view.
    var legacyFirstBaselineOffsetFromTop: CGFloat {
        get {
            legacyCGFloat(
                forKey: &LegacyAutoLayoutKeys.firstBaselineOffsetFromTop,
                on: self,
                default: LegacyAutoLayoutDefaults.baselineOffset
            )
        }
        set {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.firstBaselineOffsetFromTop,
                NSNumber(value: Double(newValue)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            legacySetNeedsUpdateConstraints()
        }
    }

    /// Backport of `lastBaselineOffsetFromBottom` (associated storage; default `0`).
    var legacyLastBaselineOffsetFromBottom: CGFloat {
        get {
            legacyCGFloat(
                forKey: &LegacyAutoLayoutKeys.lastBaselineOffsetFromBottom,
                on: self,
                default: LegacyAutoLayoutDefaults.baselineOffset
            )
        }
        set {
            objc_setAssociatedObject(
                self,
                &LegacyAutoLayoutKeys.lastBaselineOffsetFromBottom,
                NSNumber(value: Double(newValue)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Layout / constraint-update driving

    /// Runs the legacy layout pass over this view's subtree.
    ///
    /// This is the explicit opt-in path: it runs the engine even when the ObjC bridge is not
    /// installed (i.e. on iOS 6+, for tests and for library shims that need deterministic layout).
    /// When the bridge *is* installed (iOS < 6), the swizzled `layoutSubviews` pass calls this same
    /// code path. It deliberately does not consult `isActive` — the direct `legacy*` API is documented
    /// as usable on any OS (docs §1, §6).
    func legacyLayoutIfNeeded() {
        LegacyAutoLayout.ensureInstalled()
        legacyUpdateConstraintsIfNeeded()

        let engine = LegacyLayoutEngine(direction: LegacyAutoLayoutSemanticDirection.current)
        // The engine writes frames through `layoutSetFrame(_:)`; flag that so the swizzled
        // setBounds:/setCenter: hooks do not re-dirty the constraint graph for every written frame
        // (that is what would turn an RR-style pass into a layout feedback loop).
        let wasApplyingLayoutFrames = LegacyAutoLayoutRuntime.isApplyingLayoutFrames
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = true
        engine.layout(self)
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = wasApplyingLayoutFrames

        objc_setAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.needsLayout,
            NSNumber(value: false),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Marks this view as needing a layout pass (backport of `setNeedsLayout`).
    func legacySetNeedsLayout() {
        LegacyAutoLayout.ensureInstalled()
        objc_setAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.needsLayout,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        legacySetNeedsUpdateConstraints()
    }

    /// Marks this view (and its container) as needing a constraint update.
    func legacySetNeedsUpdateConstraints() {
        LegacyAutoLayout.ensureInstalled()
        objc_setAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.constraintsAreClean,
            NSNumber(value: false),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        legacyInformContainerThatSubviewsNeedUpdateConstraints()
    }

    /// Runs the pending constraint update for this view and its subviews (backport of
    /// `updateConstraintsIfNeeded`). Mirrors RRAutoLayout's recursive dirty-flag walk.
    func legacyUpdateConstraintsIfNeeded() {
        LegacyAutoLayout.ensureInstalled()
        let constraintsAreClean = (objc_getAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.constraintsAreClean
        ) as? NSNumber)?.boolValue ?? false
        guard !constraintsAreClean else { return }

        legacyUpdateConstraints()
        for subview in subviews {
            subview.legacyUpdateConstraintsIfNeeded()
        }

        objc_setAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.constraintsAreClean,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    // MARK: Internal bridge hooks (used by LegacyAutoLayoutSwizzling)

    /// The body of the backported `-updateConstraints`, mirroring RRAutoLayout's split into a content
    /// size hook and an autoresizing-translation hook. Subclasses cannot override this in Swift (no
    /// ObjC category override), so it is an internal, documented extension point rather than a method
    /// that apps are expected to override.
    internal func legacyUpdateConstraints() {
        legacyUpdateContentSizeConstraints()
        legacyUpdateAutoresizingConstraints()
    }

    /// Content-size hook (the equivalent of RRAutoLayout's `rr_updateContentSizeConstraints`).
    ///
    /// Intrinsic sizes are exposed to the engine through `layoutIntrinsicContentSize` and the hugging/
    /// compression priorities, so no extra constraints are materialised here; the hook exists so the
    /// swizzled `-updateConstraints` call flow is structurally identical to the upstream backport.
    internal func legacyUpdateContentSizeConstraints() {}

    /// Autoresizing hook (the equivalent of RRAutoLayout's `rr_updateAutoresizingConstraints`).
    ///
    /// The real `NSAutoresizingMaskLayoutConstraint` equations are generated by the engine from the
    /// item's mask plus the captured `layoutAutoresizingReference` (docs §5.3 / semantics §3.1); the
    /// bridge only stores that reference (see the `LegacyLayoutItem` conformance below). This hook keeps
    /// the small RRAutoLayout-compatible constraint form in dedicated storage (never mixed into
    /// `legacyConstraints`, which must stay the user-owned list) for the nib/ObjC `addConstraint:`
    /// flow and for tests; it does not feed the engine.
    internal func legacyUpdateAutoresizingConstraints() {
        let translated: [RRLayoutConstraint]
        if legacyTranslatesAutoresizingMaskIntoConstraints {
            translated = LegacyAutoLayoutAutoresizing.framePinningConstraints(for: self)
        } else {
            translated = []
        }
        objc_setAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.translatedAutoresizingConstraints,
            translated as NSArray,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// The constraints the bridge generated from the autoresizing mask/frame (internal diagnostics).
    internal var legacyTranslatedAutoresizingConstraints: [RRLayoutConstraint] {
        (objc_getAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.translatedAutoresizingConstraints
        ) as? [RRLayoutConstraint]) ?? []
    }

    /// Whether this view's backported `constraintsAreClean` flag is clear (internal, for tests).
    internal var legacyConstraintsAreDirty: Bool {
        let constraintsAreClean = (objc_getAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.constraintsAreClean
        ) as? NSNumber)?.boolValue ?? false
        return !constraintsAreClean
    }

    /// RRAutoLayout's `rr_informContainerThatSubviewsNeedUpdateConstraints`: constraint changes on a
    /// subview must schedule a layout of the container, not of the subview in isolation.
    internal func legacyInformContainerThatSubviewsNeedUpdateConstraints() {
        guard let superview = superview else { return }
        LegacyAutoLayoutRuntime.containerLayoutInvalidationCount += 1
        superview.setNeedsLayout()
    }
}

/// The semantic layout direction the legacy engine should resolve `leading`/`trailing` against.
///
/// iOS 6 derived this from the *application's* localization (one process-wide direction; there was no
/// per-view override until `semanticContentAttribute` in iOS 9), and RRAutoLayout had no direction
/// handling at all. `UIApplication.userInterfaceLayoutDirection` is the closest faithful query; it is
/// iOS 9+, so older systems stay left-to-right — which matches the documented iOS 6 behaviour for
/// non-RTL-localized apps (semantics research §2.4).
@MainActor
internal enum LegacyAutoLayoutSemanticDirection {

    internal static var current: RRLayoutDirection {
        if #available(iOS 9.0, *) {
            return UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
                ? .rightToLeft
                : .leftToRight
        }
        return .leftToRight
    }
}

// MARK: - LegacyLayoutItem

/// `UIView` is the only UIKit-backed `LegacyLayoutItem` in the backport (UILayoutGuide-style items are
/// out of scope: constraints that reference a non-UIView item simply have no layout item behind the
/// `Any?` reference and are ignored by the engine, exactly as they are by RRAutoLayout).
///
/// `layoutSetFrame(_:)` writes `bounds` + `center` instead of `frame`, exactly like RRAutoLayout's
/// ad-hoc pass did: `setFrame:` rounds through `setBounds:`/`setCenter:` and would re-enter the
/// swizzled invalidation hooks (and is wrong under a non-identity transform), whereas
/// `bounds`/`center` are the two primitives UIKit itself uses.
extension UIView: @MainActor LegacyLayoutItem {

    public var layoutSuperitem: LegacyLayoutItem? {
        superview
    }

    public var layoutSubitems: [LegacyLayoutItem] {
        subviews
    }

    public var layoutFrame: CGRect {
        frame
    }

    public func layoutSetFrame(_ frame: CGRect) {
        // Defensive: the engine clamps as well, but a negative size must never reach UIKit.
        let size = CGSize(width: max(0, frame.size.width), height: max(0, frame.size.height))
        let targetCenter = CGPoint(
            x: frame.origin.x + size.width / 2,
            y: frame.origin.y + size.height / 2
        )

        // Skip no-op writes: each write can schedule UIKit layout work, so a converged engine pass
        // should not keep dirtying views.
        if abs(bounds.size.width - size.width) < 0.0001,
           abs(bounds.size.height - size.height) < 0.0001,
           abs(center.x - targetCenter.x) < 0.0001,
           abs(center.y - targetCenter.y) < 0.0001 {
            return
        }

        var newBounds = bounds
        newBounds.size = size
        bounds = newBounds
        center = targetCenter
    }

    public var layoutConstraints: [RRLayoutConstraint] {
        legacyConstraints
    }

    public var layoutTranslatesAutoresizingMaskIntoConstraints: Bool {
        legacyTranslatesAutoresizingMaskIntoConstraints
    }

    /// The view's real `autoresizingMask`, mapped into the UIKit-raw-value `RRAutoresizingMask`.
    public var layoutAutoresizingMask: RRAutoresizingMask {
        RRAutoresizingMask(rawValue: autoresizingMask.rawValue)
    }

    /// The geometry the engine last generated this view's autoresizing-mask constraints from.
    ///
    /// Stored as an associated object so it survives layout passes; the engine captures it implicitly
    /// when `nil` and calls `layoutUpdateAutoresizingReference(_:)` after a successful write-back.
    public var layoutAutoresizingReference: LegacyAutoresizingReference? {
        (objc_getAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.autoresizingReference
        ) as? LegacyAutoresizingReferenceBox)?.reference
    }

    /// Records the geometry the engine generated the autoresizing-mask constraints from.
    public func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference) {
        objc_setAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.autoresizingReference,
            LegacyAutoresizingReferenceBox(reference),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    public var layoutIntrinsicContentSize: CGSize {
        legacyIntrinsicContentSize
    }

    public func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        legacyContentHuggingPriority(for: axis)
    }

    public func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        legacyContentCompressionResistancePriority(for: axis)
    }

    public var layoutFirstBaselineOffsetFromTop: CGFloat? {
        guard let number = objc_getAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.firstBaselineOffsetFromTop
        ) as? NSNumber else {
            return nil
        }
        return CGFloat(number.doubleValue)
    }

    public var layoutLastBaselineOffsetFromBottom: CGFloat? {
        guard let number = objc_getAssociatedObject(
            self,
            &LegacyAutoLayoutKeys.lastBaselineOffsetFromBottom
        ) as? NSNumber else {
            return nil
        }
        return CGFloat(number.doubleValue)
    }
}
