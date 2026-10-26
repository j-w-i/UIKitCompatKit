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

public func legacyLayoutModel(for object: AnyObject) -> RRLayoutConstraint? {
    legacyModel(for: object)
}

internal func legacyModel(for object: AnyObject) -> RRLayoutConstraint? {
    if let model = object as? RRLayoutConstraint { return model }
    return objc_getAssociatedObject(object, &nativeConstraintModelKey) as? RRLayoutConstraint
}

/// Makes `NSLayoutConstraint` usable on iOS 5, then installs the UIView bridge.
///
/// UIKit may already expose a class by that name on an OS without Auto Layout (a
/// stub), so never assume the class is absent: add the constraint surface to
/// whatever class carries the name, and create it only when there is none.
/// Swift resolves the initializer by selector, so a class lacking
/// `initWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:`
/// raises doesNotRecognizeSelector inside the caller's `init` call.
internal nonisolated func registerNativeAutoLayoutAPI() {
    guard LegacyAutoLayout.isRequired else { return }

    let existing = NSClassFromString("NSLayoutConstraint")
    let cls: AnyClass
    if let existing = existing {
        cls = existing
    } else {
        guard let created = objc_allocateClassPair(NSObject.self, "NSLayoutConstraint", 0) else { return }
        cls = created
    }

    var count: UInt32 = 0
    if let methods = class_copyMethodList(LegacyConstraintTemplate.self, &count) {
        defer { free(methods) }
        for index in 0..<Int(count) {
            let method = methods[index]
            let selector = method_getName(method)
            // Never replace an implementation the OS already provides.
            guard class_getInstanceMethod(cls, selector) == nil else { continue }
            class_addMethod(cls, selector, method_getImplementation(method),
                            method_getTypeEncoding(method))
        }
    }

    if existing == nil { objc_registerClassPair(cls) }
}
