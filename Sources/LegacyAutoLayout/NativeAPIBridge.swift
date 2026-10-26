import UIKit
import ObjectiveC

// Kept for source compatibility with older package revisions that linked a
// separate bootstrap object; registration now happens from Swift.
internal func retainNativeAPIBootstrap() {}

// Registered as NSLayoutConstraint only when UIKit does not provide the class.
// The template itself has a distinct ObjC name and is inert on native systems.
@MainActor
private final class LegacyConstraintTemplate: NSObject {
    private var model: RRLayoutConstraint {
        get { objc_getAssociatedObject(self, &nativeConstraintModelKey) as! RRLayoutConstraint }
        set { objc_setAssociatedObject(self, &nativeConstraintModelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @objc(initWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:)
    dynamic func initialize(_ first: AnyObject, attribute: Int, relation: Int,
                            second: AnyObject?, secondAttribute: Int,
                            multiplier: CGFloat, constant: CGFloat) -> AnyObject {
        model = RRLayoutConstraint(item: first, attribute: RRLayoutAttribute(rawValue: attribute)!,
            relatedBy: RRLayoutRelation(rawValue: relation)!, toItem: second,
            attribute: RRLayoutAttribute(rawValue: secondAttribute)!, multiplier: multiplier, constant: constant)
        return self
    }
    @objc dynamic var firstItem: AnyObject? { model.firstItem as AnyObject? }
    @objc dynamic var secondItem: AnyObject? { model.secondItem as AnyObject? }
    @objc dynamic var firstAttribute: Int { model.firstAttribute.rawValue }
    @objc dynamic var secondAttribute: Int { model.secondAttribute.rawValue }
    @objc dynamic var relation: Int { model.relation.rawValue }
    @objc dynamic var multiplier: CGFloat { model.multiplier }
    @objc dynamic var constant: CGFloat {
        get { model.constant }
        set { model.constant = newValue; (model.firstItem as? UIView)?.legacySetNeedsUpdateConstraints() }
    }
    @objc dynamic var priority: Float {
        get { model.priority }
        set { model.priority = newValue; (model.firstItem as? UIView)?.legacySetNeedsUpdateConstraints() }
    }
    @objc dynamic var identifier: String? {
        get { model.identifier }
        set { model.identifier = newValue }
    }
    @objc(setActive:)
    dynamic func setActive(_ value: Bool) { isActive = value }

    @objc dynamic var isActive: Bool {
        get { model.legacyIsActive }
        set {
            model.legacyIsActive = newValue
            guard let view = model.firstItem as? UIView else { return }
            if newValue { view.legacyAddConstraint(model) }
            else { view.legacyRemoveConstraint(model) }
        }
    }
}
private var nativeConstraintModelKey: UInt8 = 0
internal var nativeConstraintOwnersKey: UInt8 = 0

internal func legacyModel(for object: AnyObject) -> RRLayoutConstraint? {
    if let model = object as? RRLayoutConstraint { return model }
    return objc_getAssociatedObject(object, &nativeConstraintModelKey) as? RRLayoutConstraint
}

/// Registers a class named `NSLayoutConstraint` when UIKit has no Auto Layout,
/// then installs the UIView bridge. Pure Swift, so Link Time Optimization cannot
/// drop it. Returns immediately on iOS 6+ where UIKit owns the class.
internal nonisolated func registerNativeAutoLayoutAPI() {
    guard LegacyAutoLayout.isRequired else { return }
    if NSClassFromString("NSLayoutConstraint") == nil,
       let cls = objc_allocateClassPair(NSObject.self, "NSLayoutConstraint", 0) {
        var count: UInt32 = 0
        if let methods = class_copyMethodList(LegacyConstraintTemplate.self, &count) {
            defer { free(methods) }
            for index in 0..<Int(count) {
                let method = methods[index]
                class_addMethod(cls, method_getName(method), method_getImplementation(method),
                                method_getTypeEncoding(method))
            }
        }
        objc_registerClassPair(cls)
    }
}
