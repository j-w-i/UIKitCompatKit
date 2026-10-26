#if !targetEnvironment(macCatalyst)
#if compiler(<6.0)
#if !MODERN_BUILD
import UIKit
import LegacyAutoLayout
// Preserve native UIKit names; missing ObjC APIs are installed only on iOS 5.

/// Builds the constraint for an anchor pair.
///
/// On iOS 6+ this is UIKit's own initializer. On iOS 5 that class does not exist,
/// so constructing through it raised doesNotRecognizeSelector during viewDidLoad;
/// build the legacy model instead and hand back the runtime constraint object.
@MainActor
private func anchorConstraint(item: UIView?, attribute: NSLayoutConstraint.Attribute,
                              relatedBy: NSLayoutConstraint.Relation,
                              toItem: UIView?, secondAttribute: NSLayoutConstraint.Attribute,
                              multiplier: CGFloat, constant: CGFloat) -> NSLayoutConstraint {
    if #available(iOS 6.0, *) {
        return NSLayoutConstraint(item: item as Any, attribute: attribute, relatedBy: relatedBy,
                                  toItem: toItem, attribute: secondAttribute,
                                  multiplier: multiplier, constant: constant)
    }
    let model = legacyConstraint(item: item,
                                 attribute: RRLayoutAttribute(rawValue: attribute.rawValue)!,
                                 relatedBy: RRLayoutRelation(rawValue: relatedBy.rawValue)!,
                                 toItem: toItem,
                                 attribute: RRLayoutAttribute(rawValue: secondAttribute.rawValue)!,
                                 multiplier: multiplier, constant: constant)!
    if let bridged = legacyAttach(model: model) { return bridged }
    preconditionFailure("The iOS 5 Auto Layout bridge could not create NSLayoutConstraint.")
}

/// Expressive Anchor backport class, aiming to provide the fluid API of the more modern, iOS 9+ based constraint system. It should function nearly identically
@MainActor
@available(iOS, introduced: 5.0, obsoleted: 9.0)
public class Anchor {
    weak var view: UIView?
    let attribute: NSLayoutConstraint.Attribute

    public init(view: UIView, attribute: NSLayoutConstraint.Attribute) {
        self.view = view
        self.attribute = attribute
    }

    public func constraint(equalTo other: Anchor,
                           multiplier: CGFloat = 1.0,
                           constant: CGFloat = 0) -> NSLayoutConstraint {
        let constraint = anchorConstraint(item: view, attribute: attribute, relatedBy: .equal,
                                          toItem: other.view, secondAttribute: other.attribute,
                                          multiplier: multiplier, constant: constant)
        constraint.legacyFirstAnchor = self
        constraint.legacySecondAnchor = other
        return constraint
    }

    public func constraint(lessThanOrEqualTo other: Anchor,
                           multiplier: CGFloat = 1.0,
                           constant: CGFloat = 0) -> NSLayoutConstraint {
        let constraint = anchorConstraint(item: view, attribute: attribute, relatedBy: .lessThanOrEqual,
                                          toItem: other.view, secondAttribute: other.attribute,
                                          multiplier: multiplier, constant: constant)
        constraint.legacyFirstAnchor = self
        constraint.legacySecondAnchor = other
        return constraint
    }

    public func constraint(greaterThanOrEqualTo other: Anchor,
                           multiplier: CGFloat = 1.0,
                           constant: CGFloat = 0) -> NSLayoutConstraint {
        let constraint = anchorConstraint(item: view, attribute: attribute, relatedBy: .greaterThanOrEqual,
                                          toItem: other.view, secondAttribute: other.attribute,
                                          multiplier: multiplier, constant: constant)
        constraint.legacyFirstAnchor = self
        constraint.legacySecondAnchor = other
        return constraint
    }

    public func constraint(equalToConstant constant: CGFloat) -> NSLayoutConstraint {
        let constraint = anchorConstraint(item: view, attribute: attribute, relatedBy: .equal,
                                          toItem: nil, secondAttribute: .notAnAttribute,
                                          multiplier: 1, constant: constant)
        constraint.legacyFirstAnchor = self
        constraint.legacySecondAnchor = nil
        return constraint
    }

    public func constraint(greaterThanOrEqualToConstant constant: CGFloat) -> NSLayoutConstraint {
        let constraint = anchorConstraint(item: view, attribute: attribute, relatedBy: .greaterThanOrEqual,
                                          toItem: nil, secondAttribute: .notAnAttribute,
                                          multiplier: 1, constant: constant)
        constraint.legacyFirstAnchor = self
        constraint.legacySecondAnchor = nil
        return constraint
    }

    public func constraint(lessThanOrEqualToConstant constant: CGFloat) -> NSLayoutConstraint {
        let constraint = anchorConstraint(item: view, attribute: attribute, relatedBy: .lessThanOrEqual,
                                          toItem: nil, secondAttribute: .notAnAttribute,
                                          multiplier: 1, constant: constant)
        constraint.legacyFirstAnchor = self
        constraint.legacySecondAnchor = nil
        return constraint
    }
}

// MARK: - UIView extension using safe internal anchors
@MainActor
public extension UIView {
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var leadingAnchor: Anchor { Anchor(view: self, attribute: .leading) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var trailingAnchor: Anchor { Anchor(view: self, attribute: .trailing) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var topAnchor: Anchor { Anchor(view: self, attribute: .top) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var bottomAnchor: Anchor { Anchor(view: self, attribute: .bottom) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var widthAnchor: Anchor { Anchor(view: self, attribute: .width) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var heightAnchor: Anchor { Anchor(view: self, attribute: .height) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var centerXAnchor: Anchor { Anchor(view: self, attribute: .centerX) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var centerYAnchor: Anchor { Anchor(view: self, attribute: .centerY) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var leftAnchor: Anchor { Anchor(view: self, attribute: .left) }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var rightAnchor: Anchor { Anchor(view: self, attribute: .right) }
    
    var cookywookywoo: String {
        "dingdongbingbong, bingbongdingdong"
    }
}

// MARK: - NSLayoutConstraint isActive Backport
private var firstAnchorKey: UInt8 = 0
private var secondAnchorKey: UInt8 = 0
// Store activation state on the constraint itself. Unlike NSHashTable, associated
// objects are available on iOS 5 and do not require a global weak collection.
private var activeConstraintKey: UInt8 = 0

@MainActor
@available(iOS, introduced: 5.0, obsoleted: 9.0)
public extension NSLayoutConstraint {
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    var legacyFirstAnchor: Anchor? {
        get { objc_getAssociatedObject(self, &firstAnchorKey) as? Anchor }
        set { objc_setAssociatedObject(self, &firstAnchorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    var legacySecondAnchor: Anchor? {
        get { objc_getAssociatedObject(self, &secondAnchorKey) as? Anchor }
        set { objc_setAssociatedObject(self, &secondAnchorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var isActive: Bool {
        get { (objc_getAssociatedObject(self, &activeConstraintKey) as? NSNumber)?.boolValue ?? false }
        set {
            guard let firstView = firstItem as? UIView else { return }
            firstView.translatesAutoresizingMaskIntoConstraints = false

            // iOS 5: this instance is the runtime bridge's model; drive the engine.
            if let model = legacyLayoutModel(for: self) {
                if newValue { firstView.legacyAddConstraint(model) }
                else { firstView.legacyRemoveConstraint(model) }
                objc_setAssociatedObject(self, &activeConstraintKey,
                                         newValue ? NSNumber(value: true) : nil,
                                         .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return
            }

            // iOS 6-8: UIKit owns the constraint. The declarations are hidden when
            // this file is compiled for iOS 5, so send the same selectors directly.
            let owner: UIView
            if secondItem == nil { owner = firstView }
            else if let superview = firstView.superview { owner = superview }
            else { return }
            let selector = NSSelectorFromString(newValue ? "addConstraint:" : "removeConstraint:")
            if owner.responds(to: selector) { _ = owner.perform(selector, with: self) }
            objc_setAssociatedObject(self, &activeConstraintKey,
                                     newValue ? NSNumber(value: true) : nil,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    // MARK: - Correct signatures (match UIKit)
    
    @available(iOS, introduced: 5.0, obsoleted: 8.0)
    @_disfavoredOverload
    class func activate(_ constraints: [NSLayoutConstraint]) {
        for c in constraints { c.isActive = true }
    }
    
    class func activateCompat(_ constraints: [NSLayoutConstraint]) {
        for c in constraints { c.isActive = true }
    }
    
    @available(iOS, introduced: 5.0, obsoleted: 8.0)
    @_disfavoredOverload
    class func deactivate(_ constraints: [NSLayoutConstraint]) {
        for c in constraints { c.isActive = false }
    }
}

#endif
#endif
#endif
