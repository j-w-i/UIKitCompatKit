//
//  LegacyLayoutItem.swift
//  LegacyAutoLayout
//
//  The UIKit-decoupled view abstraction that the legacy layout engine solves.
//
//  The protocol mirrors the subset of `UIView` that RRAutoLayout (MIT,
//  Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>) used in its
//  `UIView (RRConstraintBasedLayout)` category: the view tree (`superview`,
//  `subviews`, `frame`, `bounds`, `center`), the constraint storage
//  (`constraints`, `addConstraint:`), intrinsic content size and content
//  hugging / compression-resistance priorities. Keeping it UIKit-free means the
//  engine (and its tests) can run on fake item trees and on macOS, while the
//  UIKit bridge supplies a `UIView` conformance.
//
//  Baselines: UIKit only exposes baseline anchors; this protocol asks for the two
//  offsets that define them, relative to the item's own edges. `firstBaseline` is
//  `y + layoutFirstBaselineOffsetFromTop`; `lastBaseline` is
//  `y + height - layoutLastBaselineOffsetFromBottom`. Returning `nil` means "this
//  item has no baseline provider" (plain `UIView` has none); constraints that
//  reference a baseline attribute of such an item are recorded as broken instead
//  of being given an invented value (/tmp/autolayout-semantics.md §2.5).
//  On iOS 6 there is only `.baseline` (= `lastBaseline`); `firstBaseline` is
//  iOS 8+ and kept here for archive/API compatibility.
//
//  Autoresizing: UIKit translates `autoresizingMask` into required constraints
//  owned by the superview and regenerates them from the *old* superview size when
//  the superview resizes (`-[UIView _resizeWithOldSuperviewSize:]` →
//  `_autoresizingConstraintsAreUpdated`). The engine reproduces that by asking the
//  item for a `LegacyAutoresizingReference` (the frame and superview size at the
//  time the constraints were last generated) and updating it after each pass.
//  See /tmp/autolayout-semantics.md §3.1 for the exact equations.
//
//  This file is new in the Swift port; it is not a line-by-line port of an
//  upstream file.
//

import Foundation
import CoreGraphics

/// The axis along which content hugging / compression-resistance priorities are
/// queried.
public enum RRLayoutAxis: Hashable {
    case horizontal
    case vertical
}

/// The autoresizing mask of an item, with raw values identical to
/// `UIViewAutoresizing` so the UIKit bridge can forward `view.autoresizingMask`.
public struct RRAutoresizingMask: OptionSet, Hashable {

    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The left margin is flexible (`UIViewAutoresizingFlexibleLeftMargin = 1`).
    public static let flexibleLeftMargin = RRAutoresizingMask(rawValue: 1 << 0)
    /// The width is flexible (`UIViewAutoresizingFlexibleWidth = 2`).
    public static let flexibleWidth = RRAutoresizingMask(rawValue: 1 << 1)
    /// The right margin is flexible (`UIViewAutoresizingFlexibleRightMargin = 4`).
    public static let flexibleRightMargin = RRAutoresizingMask(rawValue: 1 << 2)
    /// The top margin is flexible (`UIViewAutoresizingFlexibleTopMargin = 8`).
    public static let flexibleTopMargin = RRAutoresizingMask(rawValue: 1 << 3)
    /// The height is flexible (`UIViewAutoresizingFlexibleHeight = 16`).
    public static let flexibleHeight = RRAutoresizingMask(rawValue: 1 << 4)
    /// The bottom margin is flexible (`UIViewAutoresizingFlexibleBottomMargin = 32`).
    public static let flexibleBottomMargin = RRAutoresizingMask(rawValue: 1 << 5)

    /// No flexible component: the item keeps its frame (UIKit's default).
    public static let none: RRAutoresizingMask = []

    /// All margins and both dimensions flexible.
    public static let flexible = RRAutoresizingMask(rawValue: 0b11_1111)
}

/// The geometry an item's autoresizing-mask constraints were last generated from.
///
/// UIKit keeps the frame and superview size the constraints were created with and
/// regenerates them when the superview's bounds change
/// (`-[UIView(Geometry) _resizeWithOldSuperviewSize:]`). The engine mirrors that:
/// `frame` and `superviewSize` are the *old* geometry, while the solve happens
/// against the item's *current* superview size.
public struct LegacyAutoresizingReference {

    /// The item's frame (in superview coordinates) when the reference was taken.
    public let frame: CGRect

    /// The superview's size when the reference was taken.
    public let superviewSize: CGSize

    public init(frame: CGRect, superviewSize: CGSize) {
        self.frame = frame
        self.superviewSize = superviewSize
    }
}

/// An item in the legacy layout tree (the stand-in for `UIView`).
///
/// All frames are in the coordinate space of `layoutSuperitem`, exactly like
/// `UIView.frame`. The protocol is class-bound because items have identity: the
/// engine keys its variables and results by `ObjectIdentifier(item)`.
public protocol LegacyLayoutItem: AnyObject {

    /// The parent item, or `nil` for the root of a tree.
    var layoutSuperitem: LegacyLayoutItem? { get }

    /// The direct children, in subview order.
    var layoutSubitems: [LegacyLayoutItem] { get }

    /// The item's frame in its superitem's coordinate space.
    var layoutFrame: CGRect { get }

    /// Moves the item. Implementations translate into `bounds`/`center` changes
    /// the way RRAutoLayout's UIKit bridge did (to avoid layout loops).
    func layoutSetFrame(_ frame: CGRect)

    /// Constraints owned by this item, the equivalent of `-[UIView constraints]`.
    ///
    /// Constraints owned by descendants are collected by the engine when the
    /// descendant is part of the solved subtree, not by this property.
    var layoutConstraints: [RRLayoutConstraint] { get }

    /// Whether autoresizing-mask translation constraints should be generated.
    /// UIKit's default is `true`.
    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool { get }

    /// The item's autoresizing mask, used to generate the translation constraints
    /// when `layoutTranslatesAutoresizingMaskIntoConstraints` is `true`.
    var layoutAutoresizingMask: RRAutoresizingMask { get }

    /// The geometry the autoresizing-mask constraints were last generated from,
    /// or `nil` when they have not been generated yet.
    var layoutAutoresizingReference: LegacyAutoresizingReference? { get }

    /// Records the geometry the autoresizing-mask constraints were generated
    /// from. The engine calls this after a successful layout pass.
    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference)

    /// The intrinsic content size. `UIViewNoIntrinsicMetric` (`-1`) in either
    /// dimension means the item has no intrinsic size on that axis.
    var layoutIntrinsicContentSize: CGSize { get }

    /// Content hugging priority for an axis (default `RRLayoutPriorityValue.defaultLow`, 250).
    func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority

    /// Content compression-resistance priority for an axis
    /// (default `RRLayoutPriorityValue.defaultHigh`, 750).
    func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority

    /// Distance from the item's top edge to its first baseline, or `nil` when the
    /// item has no first baseline.
    var layoutFirstBaselineOffsetFromTop: CGFloat? { get }

    /// Distance from the item's last baseline down to its bottom edge, or `nil`
    /// when the item has no last baseline.
    var layoutLastBaselineOffsetFromBottom: CGFloat? { get }
}

// MARK: - Defaults

/// UIKit-like default implementations so fake items (and minimal bridges) only
/// have to implement the tree shape and constraint storage.
public extension LegacyLayoutItem {

    /// UIKit's `translatesAutoresizingMaskIntoConstraints` defaults to `true`;
    /// RRAutoLayout translated the autoresizing mask into edge constraints.
    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool {
        return true
    }

    /// UIKit's default autoresizing mask is `.none` (fixed frame).
    var layoutAutoresizingMask: RRAutoresizingMask {
        return .none
    }

    /// No autoresizing reference has been captured yet.
    var layoutAutoresizingReference: LegacyAutoresizingReference? {
        return nil
    }

    /// No-op default; the engine only calls this for items that translate their
    /// autoresizing mask.
    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference) {
        _ = reference
    }

    /// `UIViewNoIntrinsicMetric` on both axes: no intrinsic size.
    var layoutIntrinsicContentSize: CGSize {
        return CGSize(width: LegacyLayoutMetrics.noIntrinsicMetric,
                      height: LegacyLayoutMetrics.noIntrinsicMetric)
    }

    /// UIKit's default content hugging priority: 250 (`defaultLow`).
    func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        _ = axis
        return RRLayoutPriorityValue.defaultLow
    }

    /// UIKit's default content compression-resistance priority: 750 (`defaultHigh`).
    func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        _ = axis
        return RRLayoutPriorityValue.defaultHigh
    }

    /// No first baseline provider.
    var layoutFirstBaselineOffsetFromTop: CGFloat? {
        return nil
    }

    /// No last baseline provider.
    var layoutLastBaselineOffsetFromBottom: CGFloat? {
        return nil
    }
}

/// Constants used by the legacy layout engine.
public enum LegacyLayoutMetrics {

    /// The value UIKit uses for "this axis has no intrinsic metric".
    /// (`UIViewNoIntrinsicMetric`, `-1`.)
    public static let noIntrinsicMetric: CGFloat = -1
}
