// Auto Layout has different concrete types on iOS 5 and iOS 6+. Availability
// annotations do not provide conditional name lookup, so never shadow UIKit's
// NSLayoutConstraint or UIView members here. CompatLayout provides explicit,
// runtime-routed entry points without modifying native UIKit on iOS 6+.
#if canImport(UIKit)
import UIKit

@MainActor
public enum CompatLayout {
    public static func setTranslatesAutoresizingMaskIntoConstraints(_ value: Bool, on view: UIView) {
        if #available(iOS 6.0, *) {
            view.translatesAutoresizingMaskIntoConstraints = value
        } else {
            view.legacyTranslatesAutoresizingMaskIntoConstraints = value
        }
    }

    public static func anchor(_ view: UIView, _ attribute: RRLayoutAttribute) -> CompatLayoutAnchor {
        CompatLayoutAnchor(view: view, attribute: attribute)
    }

    public static func activate(_ constraints: [CompatLayoutConstraint]) {
        for constraint in constraints { constraint.isActive = true }
    }

    public static func deactivate(_ constraints: [CompatLayoutConstraint]) {
        for constraint in constraints { constraint.isActive = false }
    }
}

@MainActor
public struct CompatLayoutAnchor {
    private let view: UIView
    private let attribute: RRLayoutAttribute

    internal init(view: UIView, attribute: RRLayoutAttribute) {
        self.view = view
        self.attribute = attribute
    }

    public func constraint(equalTo other: CompatLayoutAnchor, multiplier: CGFloat = 1, constant: CGFloat = 0) -> CompatLayoutConstraint {
        CompatLayoutConstraint(first: view, attribute: attribute, relation: .equal,
                               second: other.view, secondAttribute: other.attribute,
                               multiplier: multiplier, constant: constant)
    }

    public func constraint(equalToConstant constant: CGFloat) -> CompatLayoutConstraint {
        CompatLayoutConstraint(first: view, attribute: attribute, relation: .equal,
                               second: nil, secondAttribute: .notAnAttribute,
                               multiplier: 1, constant: constant)
    }
}

/// One explicit compatibility handle. Its native backend is stored erased so
/// merely loading the module on iOS 5 does not instantiate a missing UIKit class.
@MainActor
public final class CompatLayoutConstraint {
    private let native: AnyObject?
    private let legacy: RRLayoutConstraint?
    private weak var nativeOwner: UIView?
    private var active = false

    public var usesNativeBackend: Bool { native != nil }

    internal init(first: UIView, attribute: RRLayoutAttribute, relation: RRLayoutRelation,
                  second: UIView?, secondAttribute: RRLayoutAttribute,
                  multiplier: CGFloat, constant: CGFloat) {
        if #available(iOS 6.0, *) {
            native = UIKit.NSLayoutConstraint(item: first,
                attribute: UIKit.NSLayoutConstraint.Attribute(rawValue: attribute.rawValue)!,
                relatedBy: UIKit.NSLayoutConstraint.Relation(rawValue: relation.rawValue)!,
                toItem: second,
                attribute: UIKit.NSLayoutConstraint.Attribute(rawValue: secondAttribute.rawValue)!,
                multiplier: multiplier, constant: constant)
            legacy = nil
        } else {
            native = nil
            legacy = RRLayoutConstraint(item: first, attribute: attribute, relatedBy: relation,
                toItem: second, attribute: secondAttribute, multiplier: multiplier, constant: constant)
        }
    }

    public var constant: CGFloat {
        get {
            if #available(iOS 6.0, *), let constraint = native as? UIKit.NSLayoutConstraint { return constraint.constant }
            return legacy!.constant
        }
        set {
            if #available(iOS 6.0, *), let constraint = native as? UIKit.NSLayoutConstraint { constraint.constant = newValue }
            else { legacy!.constant = newValue }
        }
    }

    public var isActive: Bool {
        get { active }
        set {
            guard active != newValue else { return }
            if #available(iOS 6.0, *), let constraint = native as? UIKit.NSLayoutConstraint {
                if #available(iOS 8.0, *) {
                    constraint.isActive = newValue
                } else if newValue {
                    guard let first = constraint.firstItem as? UIView else { return }
                    let second = constraint.secondItem as? UIView
                    var owner: UIView? = first
                    if let second = second {
                        while let candidate = owner, candidate !== second && !second.isDescendant(of: candidate) {
                            owner = candidate.superview
                        }
                    }
                    guard let common = owner else { preconditionFailure("Constraint items must have a common ancestor") }
                    common.addConstraint(constraint)
                    nativeOwner = common
                } else {
                    nativeOwner?.removeConstraint(constraint)
                    nativeOwner = nil
                }
            } else {
                legacy!.legacyIsActive = newValue
                // Keep activated constraints alive through their owning view,
                // just as UIKit does; the engine's registry is deliberately weak.
                if let first = legacy!.firstItem as? UIView {
                    if newValue { first.legacyAddConstraint(legacy!) }
                    else { first.legacyRemoveConstraint(legacy!) }
                }
            }
            active = newValue
        }
    }
}
#endif
