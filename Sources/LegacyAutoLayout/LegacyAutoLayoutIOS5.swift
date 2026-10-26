//
//  LegacyAutoLayoutIOS5.swift
//  LegacyAutoLayout
//
//  iOS 5 drop-in names for UIKit's constraint-based layout API.
//
//  ## The problem
//
//  UIKit introduces the constraint-based layout API in iOS 6: `NSLayoutConstraint`,
//  `NSLayoutConstraint.Attribute`, `UIView.constraints`, `-[UIView addConstraint:]`,
//  `translatesAutoresizingMaskIntoConstraints`, anchors, and so on. Code written against
//  those names cannot run on iOS 5 because the *class* does not exist there, and Swift has
//  no `__IPHONE_OS_VERSION_MAX_ALLOWED` conditional with which to rename APIs at compile time.
//
//  ## The mechanism: availability-gated name shadowing
//
//  Swift filters declarations that are unavailable for the **deployment target** during name
//  lookup. That lets a module export a same-named but narrower-availability declaration; the
//  compiler picks whichever candidate is available at the deployment target:
//
//      // UIKit (deployment target iOS 5): unavailable  -> ignored
//      @available(iOS 6.0, *) class NSLayoutConstraint
//
//      // this module (deployment target iOS 5): available -> picked
//      @available(iOS, introduced: 5.0, obsoleted: 6.0)
//      public typealias NSLayoutConstraint = RRLayoutConstraint
//
//  The result is exactly "when compiling for iOS 5, `NSLayoutConstraint` resolves to the
//  Cassowary backport; when compiling for iOS 6+, it resolves to UIKit". The same source
//  compiles for both deployment targets, with no `#if` and no `-D` flag. The trick is the
//  same one UIKitCompatKit already uses for its iOS 8/9 shims (`@available(..., obsoleted:)`).
//
//  Requirements for the shadow to win:
//
//    * The **deployment target must be below iOS 6**. Swift's availability-based name
//      resolution compares against the deployment target, not the runtime OS. If your
//      toolchain keeps the deployment target at iOS 7 to be able to link Swift (even when
//      the binary actually runs on iOS 5), these names keep resolving to UIKit's declaration
//      and a different configuration is required (see docs/legacy-autolayout.md).
//    * `NSLayoutConstraint` may only be imported from one module's point of view; the UIKit
//      declaration is annotated `API_AVAILABLE(ios(6.0))`, which is what makes the filtering
//      work. Some names UIKit ships as unannotated C typedefs (`NSLayoutAttribute`,
//      `NSLayoutRelation`, `UILayoutPriority`) cannot be shadowed this way — modern Swift
//      spells those `NSLayoutConstraint.Attribute` / `.Relation`, which are handled below.
//
//  ## Runtime: install the bridge
//
//  Name resolution is compile-time only. On an iOS 5 device the UIKit layout pass does not
//  exist, so the legacy bridge must still be installed once, e.g. in `main`/the app delegate:
//
//      LegacyAutoLayout.installIfNeeded()
//
//  The UIView shims below also call it lazily on first constraint mutation, so a programmatic
//  app that only uses `addConstraint` starts laying out automatically. On iOS 6+ it is a strict
//  no-op.
//
//  ## What is covered
//
//  * `NSLayoutConstraint` (constraint creation, `priority`, `constant`, `isActive`,
//    `activate(_:)`, `deactivate(_:)`, `identifier`), with `.Attribute` / `.Relation` /
//    `.Axis` nested type names.
//  * `UILayoutPriority` / `Float` priority constants.
//  * `UIView`: `constraints`, `addConstraint(s)`, `removeConstraint(s)`,
//    `translatesAutoresizingMaskIntoConstraints`, `needsUpdateConstraints`,
//    `setNeedsUpdateConstraints`, `updateConstraints`, `updateConstraintsIfNeeded`,
//    `intrinsicContentSize`, `invalidateIntrinsicContentSize`, content hugging /
//    compression-resistance priorities.
//
//  The `Anchor` class and the `isActive`/`activate`/`deactivate` backport are **not duplicated
//  here**: `Sources/UIKitCompatKit/NSLayoutConstraint.swift` is now compiled in every build and its
//  availability range spans iOS 5.0...<9.0, so at deployment target < 6 it operates on
//  `RRLayoutConstraint` (through the alias above) and on UIKit's `NSLayoutConstraint` at iOS 6-8.
//  One implementation, two backends.
//
//  ## Known limits (documented in the README as well)
//
//  * A method declared in an extension cannot be overridden by a subclass: iOS 5 code cannot
//    `override func updateConstraints()` or `override var intrinsicContentSize`. Use the
//    legacy storage (`legacyIntrinsicContentSize`) or the `LegacyLayoutItem`/engine hooks.
//  * Visual Format Language (`NSLayoutConstraint.constraints(withVisualFormat:...)`) is not
//    implemented.
//  * `UILayoutGuide`, layout margins, safe-area and first-baseline anchors are separate
//    backports and are not part of the iOS 5 name layer.
//  * NIB/storyboard constraints still need a class literally named `NSLayoutConstraint` at
//    unarchive time; that requires the Objective-C trampoline described in
//    docs/legacy-autolayout.md (not included in the Swift module).
//

#if canImport(UIKit)
import UIKit

// MARK: - NSLayoutConstraint

/// At deployment targets below iOS 6, UIKit has no `NSLayoutConstraint`; the unqualified name
/// resolves to the Cassowary-backed constraint model instead. At iOS 6+ this alias is obsoleted
/// and the UIKit class is used.
@available(iOS, introduced: 5.0, obsoleted: 6.0)
public typealias NSLayoutConstraint = RRLayoutConstraint

@available(iOS, introduced: 5.0, obsoleted: 6.0)
public extension RRLayoutConstraint {
    /// `NSLayoutConstraint.Attribute` for iOS 5 sources.
    typealias Attribute = RRLayoutAttribute
    /// `NSLayoutConstraint.Relation` for iOS 5 sources.
    typealias Relation = RRLayoutRelation
    /// `NSLayoutConstraint.Axis` for iOS 5 sources.
    typealias Axis = RRLayoutAxis
}

// MARK: - Priorities

/// UIKit's priority constants (`UILayoutPriority.required`, `.defaultHigh`, ...) are iOS 6 API.
/// Provide the same spelling for iOS 5 builds. (`UILayoutPriority` itself is an unannotated C
/// typedef, so the *type* still comes from UIKit; only the constants need backporting.)
@available(iOS, introduced: 5.0, obsoleted: 6.0)
public extension UILayoutPriority {
    static let required = UILayoutPriority(rawValue: RRLayoutPriorityValue.required)
    static let defaultHigh = UILayoutPriority(rawValue: RRLayoutPriorityValue.defaultHigh)
    static let defaultLow = UILayoutPriority(rawValue: RRLayoutPriorityValue.defaultLow)
    static let fittingSizeLevel = UILayoutPriority(rawValue: RRLayoutPriorityValue.fittingSizeLevel)
}

/// `RRLayoutConstraint.priority` is a `Float` (`RRLayoutPriority`); these constants make
/// `.defaultHigh`, `.required`, ... work in iOS 5 sources using the legacy model.
@available(iOS, introduced: 5.0, obsoleted: 6.0)
public extension Float {
    static let required: Float = RRLayoutPriorityValue.required
    static let defaultHigh: Float = RRLayoutPriorityValue.defaultHigh
    static let defaultLow: Float = RRLayoutPriorityValue.defaultLow
    static let fittingSizeLevel: Float = RRLayoutPriorityValue.fittingSizeLevel
}

// MARK: - UIView compatibility API

/// iOS 5 spellings of the iOS 6 constraint-based layout methods on `UIView`.
///
/// These forward to the legacy storage (`legacy*` API) and lazily install the layout bridge so
/// that a programmatic app keeps working without an explicit install call. At iOS 6+ the whole
/// extension is obsoleted and UIKit's own members are used.
@available(iOS, introduced: 5.0, obsoleted: 6.0)
public extension UIView {

    /// Backport of `translatesAutoresizingMaskIntoConstraints`.
    var translatesAutoresizingMaskIntoConstraints: Bool {
        get { legacyTranslatesAutoresizingMaskIntoConstraints }
        set { legacyTranslatesAutoresizingMaskIntoConstraints = newValue }
    }

    /// Backport of `-[UIView constraints]`.
    var constraints: [RRLayoutConstraint] {
        legacyConstraints
    }

    /// Backport of `-[UIView addConstraint:]`.
    func addConstraint(_ constraint: RRLayoutConstraint) {
        legacyAutoInstallIfNeeded()
        legacyAddConstraint(constraint)
    }

    /// Backport of `-[UIView addConstraints:]`.
    func addConstraints(_ constraints: [RRLayoutConstraint]) {
        legacyAutoInstallIfNeeded()
        legacyAddConstraints(constraints)
    }

    /// Backport of `-[UIView removeConstraint:]`.
    func removeConstraint(_ constraint: RRLayoutConstraint) {
        legacyRemoveConstraint(constraint)
    }

    /// Backport of `-[UIView removeConstraints:]`.
    func removeConstraints(_ constraints: [RRLayoutConstraint]) {
        legacyRemoveConstraints(constraints)
    }

    /// Backport of `-[UIView needsUpdateConstraints]`.
    var needsUpdateConstraints: Bool {
        legacyConstraintsAreDirty
    }

    /// Backport of `-[UIView setNeedsUpdateConstraints]`.
    func setNeedsUpdateConstraints() {
        legacyAutoInstallIfNeeded()
        legacySetNeedsUpdateConstraints()
    }

    /// Backport of `-[UIView updateConstraintsIfNeeded]`.
    func updateConstraintsIfNeeded() {
        legacyAutoInstallIfNeeded()
        legacyUpdateConstraintsIfNeeded()
    }

    /// Backport of `-[UIView updateConstraints]`.
    ///
    /// - Note: this is declared in an extension, so subclasses cannot `override` it (Swift does
    ///   not allow overriding extension members). Override `layoutSubviews` or hook the legacy
    ///   update path instead.
    func updateConstraints() {
        legacyUpdateConstraints()
    }

    /// Backport of `-[UIView intrinsicContentSize]`.
    ///
    /// Reads the legacy associated-storage value (`legacyIntrinsicContentSize`), not a subclass
    /// override (subclasses cannot override an extension member). Set
    /// `legacyIntrinsicContentSize` when the content size changes.
    var intrinsicContentSize: CGSize {
        legacyIntrinsicContentSize
    }

    /// Backport of `-[UIView invalidateIntrinsicContentSize]`.
    func invalidateIntrinsicContentSize() {
        legacySetNeedsUpdateConstraints()
        legacySetNeedsLayout()
    }

    /// Backport of `-[UIView contentHuggingPriorityForAxis:]`.
    func contentHuggingPriority(for axis: RRLayoutAxis) -> UILayoutPriority {
        UILayoutPriority(rawValue: legacyContentHuggingPriority(for: axis))
    }

    /// Backport of `-[UIView setContentHuggingPriority:forAxis:]`.
    func setContentHuggingPriority(_ priority: UILayoutPriority, for axis: RRLayoutAxis) {
        legacySetContentHuggingPriority(priority.rawValue, for: axis)
    }

    /// Backport of `-[UIView contentCompressionResistancePriorityForAxis:]`.
    func contentCompressionResistancePriority(for axis: RRLayoutAxis) -> UILayoutPriority {
        UILayoutPriority(rawValue: legacyContentCompressionResistancePriority(for: axis))
    }

    /// Backport of `-[UIView setContentCompressionResistancePriority:forAxis:]`.
    func setContentCompressionResistancePriority(_ priority: UILayoutPriority, for axis: RRLayoutAxis) {
        legacySetContentCompressionResistancePriority(priority.rawValue, for: axis)
    }

    /// Lazily installs the legacy bridge from the iOS 5 name shims.
    ///
    /// This entry point is only reachable from code compiled with a deployment target below iOS 6
    /// (the shims are unavailable otherwise), so it installs even when the *runtime* OS is iOS 6+:
    /// such a binary was compiled against the backport types and must use the backport engine on
    /// every OS it runs on. `LegacyAutoLayout.installIfNeeded()` keeps its runtime gate for the
    /// explicit/public path.
    @available(iOS, introduced: 5.0, obsoleted: 6.0)
    internal func legacyAutoInstallIfNeeded() {
        LegacyAutoLayout.installForLegacyNames()
    }
}

#endif
