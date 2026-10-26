// Swift shims for the iOS 5 spellings of UIView's constraint API.
//
// The legacy importer hides UIKit's declarations from iOS 5 compilations, so
// these shims are the only candidates there. They are obsoleted at iOS 9 where
// UIKit's own members take over.
//
// IMPORTANT: name binding happens at compile time, but the binary can run on a
// newer OS. Every entry point therefore dispatches at *runtime*:
//
//   - iOS 5: the legacy engine (installed on first use, which also registers the
//     NSLayoutConstraint class the OS lacks).
//   - iOS 6+: exactly UIKit's implementation, reached by selector because the
//     declarations are not visible to an iOS 5 compilation.
//
// Without that second branch an iOS 5-built binary running on iOS 6 would write
// only to legacy storage, so UIKit would keep translating autoresizing masks and
// the constraints would never become active.
#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Implementation of an existing UIView method, or nil when this OS lacks it.
private func legacyShimImplementation(_ object: AnyObject, _ selector: String) -> IMP? {
    let name = NSSelectorFromString(selector)
    guard let method = class_getInstanceMethod(type(of: object), name) else { return nil }
    return method_getImplementation(method)
}

@MainActor
public extension UIView {

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var translatesAutoresizingMaskIntoConstraints: Bool {
        get {
            if #available(iOS 6.0, *) {
                typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                let selector = "translatesAutoresizingMaskIntoConstraints"
                if let implementation = legacyShimImplementation(self, selector) {
                    return unsafeBitCast(implementation, to: Getter.self)(self, NSSelectorFromString(selector))
                }
            }
            LegacyAutoLayout.ensureInstalled()
            return legacyTranslatesAutoresizingMaskIntoConstraints
        }
        set {
            if #available(iOS 6.0, *) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                let selector = "setTranslatesAutoresizingMaskIntoConstraints:"
                if let implementation = legacyShimImplementation(self, selector) {
                    unsafeBitCast(implementation, to: Setter.self)(self, NSSelectorFromString(selector), newValue)
                    return
                }
            }
            LegacyAutoLayout.ensureInstalled()
            legacyTranslatesAutoresizingMaskIntoConstraints = newValue
        }
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var constraints: [RRLayoutConstraint] {
        LegacyAutoLayout.ensureInstalled()
        return legacyConstraints
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func addConstraint(_ constraint: RRLayoutConstraint) {
        if #available(iOS 6.0, *) {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let selector = "addConstraint:"
            if let implementation = legacyShimImplementation(self, selector) {
                unsafeBitCast(implementation, to: Function.self)(self, NSSelectorFromString(selector), constraint)
                return
            }
        }
        legacyAddConstraint(constraint)
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func addConstraints(_ constraints: [RRLayoutConstraint]) {
        legacyAddConstraints(constraints)
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func removeConstraint(_ constraint: RRLayoutConstraint) {
        if #available(iOS 6.0, *) {
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let selector = "removeConstraint:"
            if let implementation = legacyShimImplementation(self, selector) {
                unsafeBitCast(implementation, to: Function.self)(self, NSSelectorFromString(selector), constraint)
                return
            }
        }
        legacyRemoveConstraint(constraint)
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func removeConstraints(_ constraints: [RRLayoutConstraint]) {
        legacyRemoveConstraints(constraints)
    }
}
#endif
