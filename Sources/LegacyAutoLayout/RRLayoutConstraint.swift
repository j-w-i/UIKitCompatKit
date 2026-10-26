//
//  RRLayoutConstraint.swift
//  LegacyAutoLayout
//
//  Swift port of `RRLayoutConstraint` from RRAutoLayout, aligned with
//  `NSLayoutConstraint`'s public API so that code and nib archives written for
//  the system class keep working.
//
//  RRAutoLayout
//  Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Ownership / memory semantics
//  ----------------------------
//  Upstream RRAutoLayout stored the two items in `__unsafe_unretained` ivars
//  because Apple's Auto Layout never lets a constraint keep its views alive (and
//  a strong reference would create retain cycles through the constraint arrays
//  the views own). This port keeps that behaviour with Swift `weak` storage: a
//  constraint does not retain its items; if an item is deallocated,
//  `firstItem`/`secondItem` read as `nil` and the engine treats the constraint as
//  unsupported (it is skipped, never crashes).
//
//  Constraint validation
//  ---------------------
//  UIKit validates a constraint when it is created and raises
//  `NSInvalidArgumentException` for illegal attribute pairings. That behaviour is
//  part of what apps observe, so it is reproduced here (docs/legacy-autolayout.md
//  §4; /tmp/autolayout-semantics.md §2.1-§2.3):
//
//    * a location attribute cannot be paired with a size attribute;
//    * size attributes pair with size attributes in any combination, including
//      width <-> height (aspect-ratio constraints such as width == 2 * height);
//    * vertical attributes cannot be paired with horizontal attributes;
//    * `leading`/`trailing` cannot be paired with `left`/`right`;
//    * a constant constraint (`secondItem == nil`, `notAnAttribute`) is only
//      legal for `width`/`height`, and its multiplier is ignored;
//    * `firstAttribute == .notAnAttribute` is never legal.
//
//  The validation is exposed as the non-throwing
//  `RRLayoutConstraint.validationError(...)` (used by the NIB decoder and by
//  tests); the public initializer raises like UIKit does. Note that the
//  documented "no nonidentity multiplier with location attributes" rule is *not*
//  enforced: the same Apple guide demonstrates the `centerX == 0.5 *
//  trailing` idiom, and the engine expands attributes algebraically so the
//  equation is well-defined either way.
//
//  `isActive`
//  ----------
//  `NSLayoutConstraint.isActive` (iOS 8) is a backport here. The engine discovers
//  constraints in two ways: (1) `layoutConstraints` of every item in the solved
//  subtree, and (2) the module-internal registry of activated constraints. The
//  registry lets `RRLayoutConstraint.activate([...])` work for any
//  `LegacyLayoutItem` without requiring the item protocol to expose a mutable
//  constraint storage API. Constraints are held weakly by the registry, so an
//  activated constraint that nothing else retains does not leak (or outlive the
//  caller).
//

import Foundation
import CoreGraphics

// MARK: - Validation errors

/// Why a constraint is illegal.
///
/// Mirrors the situations in which UIKit raises `NSInvalidArgumentException` from
/// `+[NSLayoutConstraint constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:]`.
/// The `failureReason` strings follow Apple's wording closely enough to be useful
/// in logs; the exact private text is not API.
public enum LegacyLayoutConstraintError: Error, Equatable, CustomStringConvertible {

    /// `firstAttribute == .notAnAttribute`; a constraint must refer to a real
    /// attribute of the first item.
    case firstAttributeNotAnAttribute

    /// A location attribute was used with no second item ("location equal to a
    /// constant" is illegal; location attributes must be specified in pairs).
    case locationEqualToConstant(attribute: RRLayoutAttribute)

    /// The two attributes form an illegal pairing (position x size,
    /// horizontal x vertical, leading/trailing x left/right, ...).
    case invalidPairing(first: RRLayoutAttribute, second: RRLayoutAttribute)

    /// A second item was supplied together with `.notAnAttribute`, or an attribute
    /// was supplied without a second item.
    case invalidSecondAttribute(first: RRLayoutAttribute, second: RRLayoutAttribute)

    /// The reason string, in Apple's style.
    public var failureReason: String {
        switch self {
        case .firstAttributeNotAnAttribute:
            return "NSLayoutConstraint: Invalid pairing of layout attributes. A constraint cannot use notAnAttribute as its first attribute."
        case .locationEqualToConstant:
            return "A multiplier of 0 or a nil second item together with a location for the first attribute creates an illegal constraint of a location equal to a constant. Location attributes must be specified in pairs."
        case .invalidPairing(let first, let second):
            return "NSLayoutConstraint: Invalid pairing of layout attributes (\(first) and \(second))."
        case .invalidSecondAttribute(let first, let second):
            return "NSLayoutConstraint: Invalid pairing of layout attributes (\(first) and \(second)); the second item and second attribute must both be present or both absent."
        }
    }

    public var description: String {
        return "LegacyLayoutConstraintError: \(failureReason)"
    }
}

// MARK: - Constraint

/// A single Auto Layout constraint.
///
/// The constraint equation is the same as `NSLayoutConstraint`'s:
///
///     firstItem.firstAttribute  <relation>  multiplier * secondItem.secondAttribute + constant
///
/// Attribute and relation raw values are identical to UIKit's, which is required
/// for decoding archived (NIB) constraints.
public final class RRLayoutConstraint: NSObject {

    // MARK: Items (weak, like Apple's unowned references)

    private weak var _firstItem: AnyObject?
    private weak var _secondItem: AnyObject?

    // MARK: Immutable configuration

    private let _firstAttribute: RRLayoutAttribute
    private let _relation: RRLayoutRelation
    private let _secondAttribute: RRLayoutAttribute
    private let _multiplier: CGFloat

    // MARK: Mutable configuration

    /// The priority of the constraint. Defaults to `.required`.
    ///
    /// Values `>= 1000` behave as required. A priority of `0` means "do not
    /// enforce" and is mapped to the weakest strength (see `RRLayoutPriority.swift`);
    /// modern UIKit rejects priorities `<= 0` at creation, but this backport stays
    /// tolerant so corrupt archives cannot crash the layout pass.
    public var priority: RRLayoutPriority = RRLayoutPriorityValue.required

    /// The constant term of the constraint equation. Settable, like Apple's.
    public var constant: CGFloat

    /// An optional identifier for debugging. Settable, like Apple's.
    public var identifier: String?

    private var _isActive: Bool = false

    // MARK: Init

    /// Creates an unchecked constraint. The public initializers validate first;
    /// this one is the designated initializer and skips validation so the
    /// convenience initializer can validate before constructing.
    internal init(uncheckedItem firstItem: Any?,
                  attribute firstAttribute: RRLayoutAttribute,
                  relatedBy relation: RRLayoutRelation,
                  toItem secondItem: Any?,
                  attribute secondAttribute: RRLayoutAttribute,
                  multiplier: CGFloat,
                  constant: CGFloat) {
        self._firstItem = firstItem as AnyObject?
        self._firstAttribute = firstAttribute
        self._relation = relation
        self._secondItem = secondItem as AnyObject?
        self._secondAttribute = secondAttribute
        self._multiplier = multiplier
        self.constant = constant
        super.init()
    }

    /// Creates a constraint, validating it the way UIKit does.
    ///
    /// - Note: Raises `NSInvalidArgumentException` (like `NSLayoutConstraint`)
    ///   when the attributes form an illegal pairing. Use
    ///   `RRLayoutConstraint.validationError(...)` first if a non-throwing check
    ///   is needed (e.g. when decoding an archive from an old nib).
    public convenience init(item firstItem: Any?,
                            attribute firstAttribute: RRLayoutAttribute,
                            relatedBy relation: RRLayoutRelation,
                            toItem secondItem: Any?,
                            attribute secondAttribute: RRLayoutAttribute,
                            multiplier: CGFloat,
                            constant: CGFloat) {
        if let error = RRLayoutConstraint.validationError(item: firstItem,
                                                          attribute: firstAttribute,
                                                          toItem: secondItem,
                                                          attribute: secondAttribute) {
            NSException(name: NSExceptionName.invalidArgumentException,
                        reason: error.failureReason,
                        userInfo: nil).raise()
        }
        self.init(uncheckedItem: firstItem,
                  attribute: firstAttribute,
                  relatedBy: relation,
                  toItem: secondItem,
                  attribute: secondAttribute,
                  multiplier: multiplier,
                  constant: constant)
    }

    /// Backport of `+[NSLayoutConstraint constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:]`,
    /// as declared by RRAutoLayout.
    public class func constraint(item: Any?,
                                 attribute: RRLayoutAttribute,
                                 relatedBy: RRLayoutRelation,
                                 toItem: Any?,
                                 attribute secondAttribute: RRLayoutAttribute,
                                 multiplier: CGFloat,
                                 constant: CGFloat) -> RRLayoutConstraint {
        return RRLayoutConstraint(item: item,
                                  attribute: attribute,
                                  relatedBy: relatedBy,
                                  toItem: toItem,
                                  attribute: secondAttribute,
                                  multiplier: multiplier,
                                  constant: constant)
    }

    // MARK: Validation

    /// Returns `nil` when the attribute/attribute combination is legal, or the
    /// reason it is not. Never throws and never mutates anything, so it can be
    /// used by decoders and tests.
    ///
    /// Rules (from Apple's *Auto Layout Guide*, "Constraints Express Relationships
    /// Between Views" / "Anatomy of a Constraint"; reproduced on the iOS 27
    /// simulator in /tmp/autolayout-semantics.md §2):
    ///
    /// * constant constraint (`secondItem == nil`): only `width`/`height` are
    ///   legal; the multiplier is ignored;
    /// * location x location is legal only on the same axis and within the same
    ///   family: `left`/`right` pair with each other and with `centerX`,
    ///   `leading`/`trailing` pair with each other and with `centerX`, but
    ///   `leading`/`trailing` cannot pair with `left`/`right`;
    /// * vertical location attributes (`top`, `bottom`, `centerY`, `baseline`)
    ///   pair among themselves; `firstBaseline` only pairs with `firstBaseline`;
    /// * size attributes pair with size attributes in any combination
    ///   (`width`/`height`, so aspect-ratio constraints are legal);
    /// * horizontal and vertical attributes cannot be paired.
    public class func validationError(item firstItem: Any?,
                                      attribute firstAttribute: RRLayoutAttribute,
                                      toItem secondItem: Any?,
                                      attribute secondAttribute: RRLayoutAttribute) -> LegacyLayoutConstraintError? {
        guard firstAttribute != .notAnAttribute else {
            return .firstAttributeNotAnAttribute
        }
        // Constant constraint form.
        if secondItem == nil && secondAttribute == .notAnAttribute {
            guard firstAttribute.isSizeAttribute else {
                return .locationEqualToConstant(attribute: firstAttribute)
            }
            return nil
        }
        // Exactly one of (secondItem, secondAttribute) present: not a valid pair.
        if secondItem == nil || secondAttribute == .notAnAttribute {
            return .invalidSecondAttribute(first: firstAttribute, second: secondAttribute)
        }
        guard RRLayoutConstraint.isLegalPairing(first: firstAttribute, second: secondAttribute) else {
            return .invalidPairing(first: firstAttribute, second: secondAttribute)
        }
        return nil
    }

    /// Whether two real attributes may be constrained to each other.
    public class func isLegalPairing(first: RRLayoutAttribute, second: RRLayoutAttribute) -> Bool {
        guard first != .notAnAttribute, second != .notAnAttribute else {
            return false
        }
        // Sizes pair with sizes in any combination (width <-> height included:
        // that is the aspect-ratio constraint).
        if first.isSizeAttribute && second.isSizeAttribute {
            return true
        }
        if first.isSizeAttribute != second.isSizeAttribute {
            return false
        }
        // Both are location attributes: they must share an axis.
        guard let firstAxis = first.axis, let secondAxis = second.axis, firstAxis == secondAxis else {
            return false
        }
        if firstAxis == .horizontal {
            return RRLayoutConstraint.isLegalHorizontalPairing(first: first, second: second)
        }
        return RRLayoutConstraint.isLegalVerticalPairing(first: first, second: second)
    }

    private class func isLegalHorizontalPairing(first: RRLayoutAttribute,
                                                second: RRLayoutAttribute) -> Bool {
        // centerX pairs with every horizontal location attribute.
        if first == .centerX || second == .centerX {
            return true
        }
        let absolute: Set<RRLayoutAttribute> = [.left, .right]
        let directional: Set<RRLayoutAttribute> = [.leading, .trailing]
        if absolute.contains(first) && absolute.contains(second) {
            return true
        }
        if directional.contains(first) && directional.contains(second) {
            return true
        }
        // leading/trailing may not be paired with left/right.
        return false
    }

    private class func isLegalVerticalPairing(first: RRLayoutAttribute,
                                              second: RRLayoutAttribute) -> Bool {
        // firstBaseline (iOS 8+) is only legal against firstBaseline.
        if first == .firstBaseline || second == .firstBaseline {
            return first == second
        }
        // top, bottom, centerY and baseline (lastBaseline) pair among themselves.
        return true
    }

    // MARK: Configuration

    /// The first item of the constraint. Weak; `nil` once the item is deallocated.
    public var firstItem: Any? {
        return _firstItem
    }

    /// The attribute of the first item.
    public var firstAttribute: RRLayoutAttribute {
        return _firstAttribute
    }

    /// The relational operator.
    public var relation: RRLayoutRelation {
        return _relation
    }

    /// The second item of the constraint. Weak; `nil` once the item is deallocated.
    public var secondItem: Any? {
        return _secondItem
    }

    /// The attribute of the second item.
    public var secondAttribute: RRLayoutAttribute {
        return _secondAttribute
    }

    /// The multiplier applied to the second item's attribute expression.
    public var multiplier: CGFloat {
        return _multiplier
    }

    // MARK: Activation

    /// The legacy engine's activation flag. Defaults to `false`.
    ///
    /// This is the engine-facing activation API (`legacyActivate`/`legacyDeactivate`): it registers
    /// the constraint with the engine's active-constraint registry. The Apple-compatible public
    /// `isActive`/`activate(_:)`/`deactivate(_:)` backport lives in
    /// `UIKitCompatKit/NSLayoutConstraint.swift` and, below iOS 6, operates on this class.
    public var legacyIsActive: Bool {
        get {
            return _isActive
        }
        set {
            if newValue == _isActive {
                return
            }
            _isActive = newValue
            if newValue {
                // Drop-in path: activating a constraint must be enough to start the engine on iOS 5.
                LegacyAutoLayout.ensureInstalled()
                LegacyActiveConstraintRegistry.shared.register(self)
            } else {
                LegacyActiveConstraintRegistry.shared.unregister(self)
            }
        }
    }

    /// Engine-facing activation (see `legacyIsActive`).
    public class func legacyActivate(_ constraints: [RRLayoutConstraint]) {
        for constraint in constraints {
            constraint.legacyIsActive = true
        }
    }

    /// Engine-facing deactivation (see `legacyIsActive`).
    public class func legacyDeactivate(_ constraints: [RRLayoutConstraint]) {
        for constraint in constraints {
            constraint.legacyIsActive = false
        }
    }

    // MARK: Debugging

    public override var description: String {
        let relationText: String
        switch _relation {
        case .lessThanOrEqual: relationText = "<="
        case .equal: relationText = "=="
        case .greaterThanOrEqual: relationText = ">="
        }
        let firstText = RRLayoutConstraint.describeItem(_firstItem, attribute: _firstAttribute)
        let secondText: String
        if let secondItem = _secondItem {
            secondText = RRLayoutConstraint.describeItem(secondItem, attribute: _secondAttribute)
        } else {
            secondText = "nil"
        }
        var text = "<RRLayoutConstraint \(firstText) \(relationText) \(_multiplier) * \(secondText) + \(constant)"
        if priority != RRLayoutPriorityValue.required {
            text += " @\(priority)"
        }
        if let identifier = identifier {
            text += " '\(identifier)'"
        }
        if _isActive {
            text += " active"
        }
        text += ">"
        return text
    }

    private static func describeItem(_ item: AnyObject?, attribute: RRLayoutAttribute) -> String {
        guard let item = item else {
            return "nil.\(attribute)"
        }
        return "\(type(of: item)).\(attribute)"
    }
}

// MARK: - Active constraint registry

/// Registry of constraints whose `isActive` flag is `true`.
///
/// The engine unions these with the constraints owned by the items of the subtree
/// being solved (de-duplicated by object identity). Items are not retained, so a
/// deallocated item turns the constraint into a no-op at solve time.
internal final class LegacyActiveConstraintRegistry {

    internal static let shared = LegacyActiveConstraintRegistry()

    private final class Entry {
        weak var constraint: RRLayoutConstraint?
        init(constraint: RRLayoutConstraint) {
            self.constraint = constraint
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    private init() {}

    internal func register(_ constraint: RRLayoutConstraint) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        for entry in entries {
            if entry.constraint === constraint {
                return
            }
        }
        entries.append(Entry(constraint: constraint))
    }

    internal func unregister(_ constraint: RRLayoutConstraint) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { entry in
            entry.constraint === constraint || entry.constraint == nil
        }
    }

    /// A snapshot of all live activated constraints, in activation order.
    internal func activeConstraints() -> [RRLayoutConstraint] {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        var result: [RRLayoutConstraint] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            if let constraint = entry.constraint {
                result.append(constraint)
            }
        }
        return result
    }

    private func pruneLocked() {
        entries.removeAll { $0.constraint == nil }
    }
}
