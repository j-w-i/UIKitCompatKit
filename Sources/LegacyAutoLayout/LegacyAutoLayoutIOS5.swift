// Swift shims for the iOS 5 spellings of UIView's constraint API.
//
// The legacy importer marks UIKit's declarations unavailable below iOS 6 so
// these are the only candidates (no ambiguity), and they are obsoleted at iOS 9
// where UIKit's own members are used instead. Each entry point installs the
// legacy bridge on first use, which also registers the NSLayoutConstraint class
// the iOS 5 runtime lacks.
#if canImport(UIKit)
import UIKit

@MainActor
public extension UIView {

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var translatesAutoresizingMaskIntoConstraints: Bool {
        get {
            LegacyAutoLayout.ensureInstalled()
            return legacyTranslatesAutoresizingMaskIntoConstraints
        }
        set {
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
        legacyRemoveConstraint(constraint)
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func removeConstraints(_ constraints: [RRLayoutConstraint]) {
        legacyRemoveConstraints(constraints)
    }
}
#endif
