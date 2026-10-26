//
//  LegacyAutoLayout.swift
//  LegacyAutoLayout
//
//  Runtime availability gate + public entry points for the legacy (pre-iOS 6) Auto Layout
//  backport. This is a Swift port of RRAutoLayout's UIView+RRConstraintBasedLayout/Module
//  bridge, backed by the Cassowary solver instead of ad-hoc rectangle math.
//
//  Portions ported from RRAutoLayout (https://github.com/RolandasRazma/RRAutoLayout):
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

import Foundation

/// Runtime gate + entry points for the legacy Auto Layout backport.
///
/// ## Why this is gated at *runtime* and not at *compile time*
///
/// RRAutoLayout gated itself with `+[UIView respondsToSelector:@selector(requiresConstraintBasedLayout)]`:
/// on iOS 6 and later UIKit already ships the real `NSLayoutConstraint` machinery, so installing the
/// backport would fight the system. A Swift package cannot reproduce RRAutoLayout's `+load` timing and
/// cannot check `__IPHONE_OS_VERSION_MAX_ALLOWED` — Swift has no such build configuration — and a
/// Swift binary on iOS 5 needs a back-deployed Swift runtime, which this package does not provide.
/// The port is therefore a *semantic* backport: the engine is compiled in every configuration, stays
/// completely inert on iOS 6+, and only the explicit `legacy*` entry points make it reachable on
/// modern OSes (that is how the engine is tested and how older `UIKitCompatKit` shims opt in
/// deterministically).
///
/// Name-level drop-in for iOS 5 sources (`NSLayoutConstraint` etc. resolving to this module's types
/// when the deployment target is below iOS 6) is handled by availability-gated shadowing in
/// `LegacyAutoLayoutIOS5.swift`; that layer is compile-time only and does not affect this gate.
///
/// `isRequired` is `true` only when `#available(iOS 6.0, *)` is false. On iOS 6+ nothing is ever
/// swizzled, no method is added to `UIView`, and no UIKit behaviour changes.
@MainActor
public enum LegacyAutoLayout {

    /// True only when running on an OS without the constraint-based layout system (iOS < 6).
    ///
    /// This is the single source of truth for the runtime gate: every installation path funnels
    /// through it and nothing may swizzle UIKit unless it returns `true`.
    public nonisolated static var isRequired: Bool {
        if #available(iOS 6.0, *) {
            // UIKit owns constraint-based layout on iOS 6+. The backport must stay inert.
            return false
        } else {
            // iOS 5.x: no -[UIView requiresConstraintBasedLayout], no NSLayoutConstraint.
            return true
        }
    }

    /// True only when the legacy ObjC bridge has actually been installed. Always false on iOS 6+.
    public static var isActive: Bool {
        LegacyAutoLayoutInstaller.isInstalled
    }

    /// Installs the UIView bridge if and only if `isRequired`. Returns true when the bridge is active.
    ///
    /// Idempotent: repeated calls never install twice, and on iOS 6+ this is a strict no-op that
    /// returns `false` (no swizzling, no `class_addMethod`, no `setNeedsUpdateConstraints`).
    @discardableResult
    public static func installIfNeeded() -> Bool {
        guard isRequired else {
            // Belt and braces: never touch the ObjC runtime on a system that has Auto Layout.
            return false
        }
        LegacyAutoLayoutInstaller.install()
        return isActive
    }

    /// Installs the bridge lazily from a nonisolated path (constraint activation, legacy add).
    ///
    /// Swift has no `+load`, so the bridge cannot install itself at process start. Instead the
    /// constraint-facing entry points call this on first use; it is idempotent and a strict no-op
    /// on iOS 6+. If a non-main thread triggers it, installation is hopped to the main queue so the
    /// runtime mutation happens on the thread UIKit actually uses.
    internal nonisolated static func ensureInstalled() {
        guard !LegacyAutoLayoutInstaller.isInstalled else { return }
        if Thread.isMainThread {
            registerNativeAutoLayoutAPI()
            LegacyAutoLayoutInstaller.install()
        } else {
            DispatchQueue.main.sync {
                registerNativeAutoLayoutAPI()
                LegacyAutoLayoutInstaller.install()
            }
        }
    }

    /// Installs the bridge for binaries that were compiled against the iOS 5 name shims.
    ///
    /// The shims are only available when the deployment target is below iOS 6, so reaching this
    /// path means the binary was built against the backport types: it must run the backport engine
    /// even on an iOS 6+ device (name binding is decided at compile time, not at runtime). The
    /// public `installIfNeeded()` keeps its runtime gate for the explicit path.
    internal nonisolated static func installForLegacyNames() {
        ensureInstalled()
    }

    /// Reverts the runtime installation, for tests of the installer itself.
    ///
    /// The exchanged `UIView` implementations are restored. Methods injected with `class_addMethod`
    /// (`constraints`, `addConstraint:`, ...) stay on the class because the ObjC runtime cannot safely
    /// remove them once UIKit may have cached their dispatch; they are inert unless the bridge is
    /// installed, which cannot happen on iOS 6+ anyway.
    ///
    /// - Returns: `true` if an installed bridge was reverted, `false` if there was nothing to revert.
    @discardableResult
    public static func uninstallForTesting() -> Bool {
        LegacyAutoLayoutInstaller.uninstall()
    }
}
