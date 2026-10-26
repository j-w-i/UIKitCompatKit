//
//  LegacyAutoLayoutNibDecoding.swift
//  LegacyAutoLayout
//
//  NSCoder decoding for the legacy Auto Layout backport: the nib/NSKeyedArchiver keys that
//  RRAutoLayout decoded in `-[RRLayoutConstraint initWithCoder:]`, the modern `…V2` duplicates, the
//  `NSShouldBeArchived` flag, and the `UIViewAutolayoutConstraints` /
//  `UIViewDoesNotTranslateAutoresizingMaskIntoConstraints` / `UIAutoresizingMask` payloads that
//  `-[UIView initWithCoder:]` used to install constraints and autoresizing flags from a nib.
//
//  Key set verified against /tmp/autolayout-semantics.md §5 (measured with NSKeyedArchiver and
//  `ibtool --compile` on iOS 27 / Xcode 27); see also docs/legacy-autolayout.md §6.
//
//  Ported from RRAutoLayout's Module/RRLayoutConstraint.m and
//  View/UIView+RRConstraintBasedLayout.m:
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

// MARK: - Archive keys

/// The NSCoder keys Apple's `NSLayoutConstraint`/`NSIBLayoutConstraint` archives use, as consumed by
/// RRAutoLayout and re-exported for callers that decode old nib payloads themselves.
///
/// Modern archives write the `…V2` duplicate keys in addition to the historical ones (same values);
/// the decoder prefers `V2` when both are present, since that is the representation current
/// NSKeyedArchiver output treats as authoritative.
public enum LegacyAutoLayoutNibKey {
    public static let firstItem = "NSFirstItem"
    public static let firstItemV2 = "NSFirstItemV2"
    public static let firstAttribute = "NSFirstAttribute"
    public static let firstAttributeV2 = "NSFirstAttributeV2"
    public static let secondItem = "NSSecondItem"
    public static let secondItemV2 = "NSSecondItemV2"
    public static let secondAttribute = "NSSecondAttribute"
    public static let secondAttributeV2 = "NSSecondAttributeV2"
    public static let priority = "NSPriority"
    public static let priorityV2 = "NSPriorityV2"
    public static let constant = "NSConstant"
    public static let constantV2 = "NSConstantV2"
    public static let relation = "NSRelation"
    public static let relationV2 = "NSRelationV2"
    public static let multiplier = "NSMultiplier"
    public static let multiplierV2 = "NSMultiplierV2"

    /// The constraint identifier key. Apple uses `NSLayoutIdentifier` (iOS 7+); RRAutoLayout's
    /// `NSIdentifier` was never a real archive key.
    public static let identifier = "NSLayoutIdentifier"
    public static let identifierV2 = "NSLayoutIdentifierV2"

    /// `-[NSLayoutConstraint shouldBeArchived]` (iOS 6): whether the owning view should archive this
    /// constraint when the view itself is archived.
    public static let shouldBeArchived = "NSShouldBeArchived"

    /// The `UIView` archive key carrying the constraint array decoded by `initWithCoder:`.
    public static let viewAutolayoutConstraints = "UIViewAutolayoutConstraints"

    /// The `UIView` archive key carrying the *negation* of `translatesAutoresizingMaskIntoConstraints`.
    public static let viewDoesNotTranslateAutoresizingMaskIntoConstraints =
        "UIViewDoesNotTranslateAutoresizingMaskIntoConstraints"

    /// The `UIView` archive key carrying the raw `autoresizingMask` value.
    public static let viewAutoresizingMask = "UIAutoresizingMask"

    /// Historical RRAutoLayout key: never emitted by UIKit, but accepted as a fallback so payloads
    /// produced by early versions of this port still decode.
    internal static let legacyIdentifier = "NSIdentifier"
}

// MARK: - RRLayoutConstraint.shouldBeArchived

private enum LegacyNibDecodingKeys {
    static var shouldBeArchived: UInt8 = 0
}

public extension RRLayoutConstraint {

    /// Backport of `-[NSLayoutConstraint shouldBeArchived]` (iOS 6).
    ///
    /// Decoded from `NSShouldBeArchived`; the default is `false` (UIKit's default), as the key is
    /// omitted when the value is `false`.
    var legacyShouldBeArchived: Bool {
        get {
            (objc_getAssociatedObject(self, &LegacyNibDecodingKeys.shouldBeArchived) as? NSNumber)?.boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &LegacyNibDecodingKeys.shouldBeArchived,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

// MARK: - View-level archive flags

/// The view-level autoresizing flags stored in a `UIView` nib archive, when present.
///
/// Both fields are archived conditionally, so they are optional: `nil` means "the archive did not
/// carry this key", which the caller must not confuse with `false`.
public struct LegacyViewArchiveFlags {
    /// Decoded value of `translatesAutoresizingMaskIntoConstraints`, or `nil` when absent.
    public let translatesAutoresizingMaskIntoConstraints: Bool?
    /// Decoded raw `autoresizingMask`, or `nil` when absent.
    public let autoresizingMask: UInt?

    public init(translatesAutoresizingMaskIntoConstraints: Bool?, autoresizingMask: UInt?) {
        self.translatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
        self.autoresizingMask = autoresizingMask
    }
}

// MARK: - Decoding entry points

/// Decoding entry points for nib/xib constraint archives.
///
/// The decoder is deliberately permissive: a missing key means "Apple default" (priority 1000,
/// multiplier 1, relation `equal`, constant 0, attributes `notAnAttribute`) instead of a crash — old
/// nibs are the whole point of the backport and must never take the app down. Unknown or unsupported
/// keys/values are ignored.
public enum LegacyAutoLayoutNibCoding {

    /// Decodes one `RRLayoutConstraint` from an Apple-style constraint archive.
    ///
    /// Modern archives carry both historical and `…V2` copies of several fields; `V2` wins when both
    /// are present. `NSShouldBeArchived` is decoded into `legacyShouldBeArchived`; the identifier is
    /// read from `NSLayoutIdentifier` (with the historical `NSIdentifier` accepted as a fallback).
    ///
    /// - Returns: the decoded constraint, or `nil` when the archived attribute pairing is illegal
    ///   (UIKit's initialiser raises for those; the decoder skips them instead of crashing).
    /// - Note: which of the two `Any?` items ends up as `firstItem`/`secondItem` is exactly what the
    ///   archive says; the engine normalises it per `RRLayoutConstraint` semantics.
    public static func constraint(from decoder: NSCoder) -> RRLayoutConstraint? {
        let fields = decodedFields(from: decoder)

        // UIKit raises NSInvalidArgumentException from `-[NSLayoutConstraint initWithCoder:]` for an
        // archived constraint whose attributes form an illegal pairing. The backport must never crash
        // on legacy nib input, so the invalid entry is skipped (callers can inspect
        // `validationError(from:)` to find out why).
        if let validationError = legacyValidationError(for: fields) {
            _ = validationError
            return nil
        }

        let constraint = RRLayoutConstraint(
            item: fields.firstItem,
            attribute: fields.firstAttribute,
            relatedBy: fields.relation,
            toItem: fields.secondItem,
            attribute: fields.secondAttribute,
            multiplier: fields.multiplier,
            constant: fields.constant
        )
        constraint.priority = fields.priority
        constraint.identifier = fields.identifier
        constraint.legacyShouldBeArchived = fields.shouldBeArchived
        return constraint
    }

    /// The reason the archived constraint at `decoder` would be rejected, or `nil` when it is legal.
    ///
    /// Decoding only: never constructs a constraint and never raises. Useful for diagnostically
    /// logging invalid legacy nib constraints that `constraint(from:)` silently skips.
    public static func validationError(from decoder: NSCoder) -> LegacyLayoutConstraintError? {
        legacyValidationError(for: decodedFields(from: decoder))
    }

    /// Decodes a `UIViewAutolayoutConstraints`-style payload (normally an `NSArray` of
    /// `RRLayoutConstraint`).
    ///
    /// - Returns: the decoded constraints, or `nil` when the archive does not contain that key.
    public static func constraints(from decoder: NSCoder) -> [RRLayoutConstraint]? {
        guard decoder.containsValue(forKey: LegacyAutoLayoutNibKey.viewAutolayoutConstraints) else {
            return nil
        }
        guard let payload = decoder.decodeObject(forKey: LegacyAutoLayoutNibKey.viewAutolayoutConstraints) else {
            return []
        }
        if let constraints = payload as? [RRLayoutConstraint] {
            return constraints
        }
        if let array = payload as? NSArray {
            var constraints: [RRLayoutConstraint] = []
            constraints.reserveCapacity(array.count)
            for index in 0..<array.count {
                if let constraint = array.object(at: index) as? RRLayoutConstraint {
                    constraints.append(constraint)
                }
            }
            return constraints
        }
        // Tolerate a single-constraint payload as well; anything else is unsupported and ignored.
        if let constraint = payload as? RRLayoutConstraint {
            return [constraint]
        }
        return []
    }

    // MARK: Decoded field bundle

    /// All fields decoded from one archived constraint, with Apple's defaults applied.
    private struct LegacyDecodedConstraintFields {
        let firstItem: Any?
        let secondItem: Any?
        let firstAttribute: RRLayoutAttribute
        let secondAttribute: RRLayoutAttribute
        let relation: RRLayoutRelation
        let priority: RRLayoutPriority
        let constant: CGFloat
        let multiplier: CGFloat
        let identifier: String?
        let shouldBeArchived: Bool
    }

    private static func decodedFields(from decoder: NSCoder) -> LegacyDecodedConstraintFields {
        LegacyDecodedConstraintFields(
            firstItem: decodeItem(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.firstItemV2,
                fallbackKey: LegacyAutoLayoutNibKey.firstItem
            ),
            secondItem: decodeItem(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.secondItemV2,
                fallbackKey: LegacyAutoLayoutNibKey.secondItem
            ),
            firstAttribute: decodeAttribute(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.firstAttributeV2,
                fallbackKey: LegacyAutoLayoutNibKey.firstAttribute
            ),
            secondAttribute: decodeAttribute(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.secondAttributeV2,
                fallbackKey: LegacyAutoLayoutNibKey.secondAttribute
            ),
            relation: decodeRelation(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.relationV2,
                fallbackKey: LegacyAutoLayoutNibKey.relation
            ),
            priority: decodePriority(from: decoder),
            constant: decodeCGFloat(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.constantV2,
                fallbackKey: LegacyAutoLayoutNibKey.constant,
                default: 0
            ),
            multiplier: decodeCGFloat(
                decoder,
                preferredKey: LegacyAutoLayoutNibKey.multiplierV2,
                fallbackKey: LegacyAutoLayoutNibKey.multiplier,
                default: 1
            ),
            identifier: decodeIdentifier(from: decoder),
            shouldBeArchived: decodeShouldBeArchived(from: decoder)
        )
    }

    private static func legacyValidationError(
        for fields: LegacyDecodedConstraintFields
    ) -> LegacyLayoutConstraintError? {
        RRLayoutConstraint.validationError(
            item: fields.firstItem,
            attribute: fields.firstAttribute,
            toItem: fields.secondItem,
            attribute: fields.secondAttribute
        )
    }

    /// Decodes the view-level autoresizing flags from a `UIView` nib archive, when present.
    ///
    /// `UIViewDoesNotTranslateAutoresizingMaskIntoConstraints` is the *negation* of
    /// `translatesAutoresizingMaskIntoConstraints` (as archived by UIKit), so it is inverted here.
    public static func viewFlags(from decoder: NSCoder) -> LegacyViewArchiveFlags {
        var translatesAutoresizingMaskIntoConstraints: Bool?
        if decoder.containsValue(
            forKey: LegacyAutoLayoutNibKey.viewDoesNotTranslateAutoresizingMaskIntoConstraints
        ) {
            translatesAutoresizingMaskIntoConstraints = !decoder.decodeBool(
                forKey: LegacyAutoLayoutNibKey.viewDoesNotTranslateAutoresizingMaskIntoConstraints
            )
        }

        var autoresizingMask: UInt?
        if decoder.containsValue(forKey: LegacyAutoLayoutNibKey.viewAutoresizingMask) {
            let rawValue = decoder.decodeInteger(forKey: LegacyAutoLayoutNibKey.viewAutoresizingMask)
            // OptionSet raw values are non-negative; tolerate a signed archive value by truncation.
            autoresizingMask = UInt(truncatingIfNeeded: rawValue)
        }

        return LegacyViewArchiveFlags(
            translatesAutoresizingMaskIntoConstraints: translatesAutoresizingMaskIntoConstraints,
            autoresizingMask: autoresizingMask
        )
    }

    // MARK: Key-by-key tolerant decoding

    /// Picks the `V2` key when the archive has it, otherwise the historical key.
    private static func chosenKey(in decoder: NSCoder, v2Key: String, plainKey: String) -> String? {
        if decoder.containsValue(forKey: v2Key) {
            return v2Key
        }
        if decoder.containsValue(forKey: plainKey) {
            return plainKey
        }
        return nil
    }

    private static func decodeItem(_ decoder: NSCoder, preferredKey: String, fallbackKey: String) -> Any? {
        guard let key = chosenKey(in: decoder, v2Key: preferredKey, plainKey: fallbackKey) else {
            return nil
        }
        let item = decoder.decodeObject(forKey: key)
        // Old archives sometimes encode "no item" as NSNull instead of omitting the key.
        if item is NSNull { return nil }
        return item
    }

    private static func decodeAttribute(
        _ decoder: NSCoder,
        preferredKey: String,
        fallbackKey: String
    ) -> RRLayoutAttribute {
        guard let key = chosenKey(in: decoder, v2Key: preferredKey, plainKey: fallbackKey) else {
            return .notAnAttribute
        }
        let rawValue = decoder.decodeInteger(forKey: key)
        return RRLayoutAttribute(rawValue: rawValue) ?? .notAnAttribute
    }

    private static func decodeRelation(
        _ decoder: NSCoder,
        preferredKey: String,
        fallbackKey: String
    ) -> RRLayoutRelation {
        guard let key = chosenKey(in: decoder, v2Key: preferredKey, plainKey: fallbackKey) else {
            return .equal
        }
        let rawValue = decoder.decodeInteger(forKey: key)
        return RRLayoutRelation(rawValue: rawValue) ?? .equal
    }

    /// Priorities are archived as an integer (`NSPriority = 250` for a `250.5` constraint: the
    /// fractional part is lost by UIKit itself, see semantics §5.1). A number-backed decode is tried
    /// first so hand-built payloads and modern re-encodings decode identically.
    private static func decodePriority(from decoder: NSCoder) -> RRLayoutPriority {
        guard let key = chosenKey(
            in: decoder,
            v2Key: LegacyAutoLayoutNibKey.priorityV2,
            plainKey: LegacyAutoLayoutNibKey.priority
        ) else {
            return RRLayoutPriorityValue.required
        }
        if let number = decoder.decodeObject(forKey: key) as? NSNumber {
            return number.floatValue
        }
        return RRLayoutPriority(decoder.decodeInteger(forKey: key))
    }

    /// CGFloat values are archived as doubles (`<real>`) by modern archives; a number-backed decode is
    /// tried first, then the historical `decodeFloat`.
    private static func decodeCGFloat(
        _ decoder: NSCoder,
        preferredKey: String,
        fallbackKey: String,
        default defaultValue: CGFloat
    ) -> CGFloat {
        guard let key = chosenKey(in: decoder, v2Key: preferredKey, plainKey: fallbackKey) else {
            return defaultValue
        }
        if let number = decoder.decodeObject(forKey: key) as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        return CGFloat(decoder.decodeFloat(forKey: key))
    }

    /// `NSLayoutIdentifier` (iOS 7+), with the historical `NSIdentifier` accepted as a tolerance.
    private static func decodeIdentifier(from decoder: NSCoder) -> String? {
        let preferred = LegacyAutoLayoutNibKey.identifier
        let fallback = LegacyAutoLayoutNibKey.legacyIdentifier
        if decoder.containsValue(forKey: LegacyAutoLayoutNibKey.identifierV2) {
            return decoder.decodeObject(forKey: LegacyAutoLayoutNibKey.identifierV2) as? String
        }
        if decoder.containsValue(forKey: preferred) {
            return decoder.decodeObject(forKey: preferred) as? String
        }
        if decoder.containsValue(forKey: fallback) {
            return decoder.decodeObject(forKey: fallback) as? String
        }
        return nil
    }

    private static func decodeShouldBeArchived(from decoder: NSCoder) -> Bool {
        guard decoder.containsValue(forKey: LegacyAutoLayoutNibKey.shouldBeArchived) else {
            // UIKit omits the key when the value is its default (false).
            return false
        }
        return decoder.decodeBool(forKey: LegacyAutoLayoutNibKey.shouldBeArchived)
    }
}

public extension RRLayoutConstraint {

    /// `RRLayoutConstraint.init(decoder:)`-style factory for Apple's nib constraint archive keys.
    ///
    /// Mirrors RRAutoLayout's `-[RRLayoutConstraint initWithCoder:]` without making
    /// `RRLayoutConstraint` an `NSCoding` class: decoding lives in the UIKit bridge (docs §4), and the
    /// factory only needs the public initialiser plus the settable `priority`/`identifier`.
    ///
    /// - Returns: the decoded constraint, or `nil` when the archive describes an illegal attribute
    ///   pairing (which UIKit's initialiser would reject by raising).
    static func from(decoder: NSCoder) -> RRLayoutConstraint? {
        LegacyAutoLayoutNibCoding.constraint(from: decoder)
    }
}

@MainActor
public extension UIView {

    /// Decodes the `UIViewAutolayoutConstraints` payload from a nib decoder into this view's legacy
    /// constraint storage, without touching the view-level autoresizing flags.
    ///
    /// - Returns: the number of constraints that were installed.
    @discardableResult
    func legacyDecodeAutolayoutConstraints(from decoder: NSCoder) -> Int {
        guard let constraints = LegacyAutoLayoutNibCoding.constraints(from: decoder) else {
            return 0
        }
        legacyAddConstraints(constraints)
        return constraints.count
    }

    /// Decodes and applies the view-level nib archive flags: the archived
    /// `translatesAutoresizingMaskIntoConstraints` (stored inverted as
    /// `UIViewDoesNotTranslateAutoresizingMaskIntoConstraints`) and the raw `UIAutoresizingMask`.
    ///
    /// - Returns: `true` when either key was present and applied.
    @discardableResult
    func legacyDecodeAutoresizingArchiveFlags(from decoder: NSCoder) -> Bool {
        let flags = LegacyAutoLayoutNibCoding.viewFlags(from: decoder)
        var decodedAnything = false
        if let translatesAutoresizingMaskIntoConstraints = flags.translatesAutoresizingMaskIntoConstraints {
            legacyTranslatesAutoresizingMaskIntoConstraints = translatesAutoresizingMaskIntoConstraints
            decodedAnything = true
        }
        if let rawAutoresizingMask = flags.autoresizingMask {
            autoresizingMask = UIView.AutoresizingMask(rawValue: rawAutoresizingMask)
            // A different mask means different autoresizing constraints: re-capture the geometry.
            legacyClearAutoresizingReference(self)
            decodedAnything = true
        }
        return decodedAnything
    }

    /// Decodes the complete legacy `UIView` nib payload: view-level autoresizing flags first, then the
    /// owned constraints.
    ///
    /// This is what the swizzled `initWithCoder:` calls on iOS < 6. It is also usable directly so a
    /// caller can decode legacy nibs deterministically on modern OSes for tests/compat shims.
    ///
    /// - Returns: the number of constraints that were installed.
    @discardableResult
    func legacyDecodeAutolayoutArchive(from decoder: NSCoder) -> Int {
        legacyDecodeAutoresizingArchiveFlags(from: decoder)
        return legacyDecodeAutolayoutConstraints(from: decoder)
    }
}
