//
//  LegacyAutoLayoutSwizzling.swift
//  LegacyAutoLayout
//
//  Objective-C runtime installation of the UIKit bridge. This is the only file in the module that
//  touches the ObjC runtime, and it refuses to run on any OS that already has constraint-based
//  layout (iOS 6+), mirroring RRAutoLayout's `+load` guard
//  (`![[UIView class] respondsToSelector:@selector(requiresConstraintBasedLayout)]`).
//
//  Ported from RRAutoLayout's View/UIView+RRConstraintBasedLayout.m:
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

// MARK: - Runtime state

/// Installed-state shared by the gate, the UIView hooks and the swizzled methods.
@MainActor
internal enum LegacyAutoLayoutRuntime {

    /// Counts constraint-change invalidations that were propagated to a container's `setNeedsLayout`.
    ///
    /// `UIView` has no public `needsLayout` getter, so this is the deterministic observation point for
    /// the "constraint change schedules the container" behaviour (used by the bridge integration tests).
    internal static var containerLayoutInvalidationCount = 0

    /// True while `LegacyLayoutEngine` is writing frames back.
    ///
    /// The engine writes through `bounds` + `center`, and the backport swizzles `setBounds:` /
    /// `setCenter:` to invalidate constraints. Without this flag every written frame would immediately
    /// re-dirty the graph (the feedback loop RRAutoLayout's layout pass implicitly had). The explicit
    /// `legacy*` pass clears it around the engine call; the swizzled layout pass does the same.
    internal static var isApplyingLayoutFrames = false
}

// MARK: - Swizzled/hooked implementations

/// Holder for the IMPs that get installed on `UIView`.
///
/// The methods live on a private `NSObject` subclass rather than in a `UIView` extension so that
/// nothing (`constraints`, `addConstraint:`, ...) is added to `UIView` at load time on modern OSes;
/// on iOS < 6 the installer adds/exchanges them via the ObjC runtime. When one of these runs, `self`
/// is really a `UIView` instance (the IMP was installed on `UIView`), hence the documented
/// `Unmanaged` round-trip instead of an unsafe downcast.
@MainActor
private final class LegacyUIViewRuntimeHooks: NSObject {

    /// Re-types the Objective-C `self` of a hook (statically this class) as the `UIView` it really is,
    /// without changing ARC ownership.
    private func bridgedView(_ object: AnyObject) -> UIView {
        Unmanaged<UIView>.fromOpaque(Unmanaged.passUnretained(object).toOpaque()).takeUnretainedValue()
    }

    // MARK: Exchanged UIView methods

    /// RRAutoLayout `rr_r_layoutSubviews`: run the legacy layout pass, then the original UIKit pass.
    @objc dynamic func rr_r_layoutSubviews() {
        let view = bridgedView(self)
        if LegacyAutoLayout.isActive {
            view.legacyLayoutIfNeeded()
        }
        LegacyAutoLayoutInstaller.callOriginalVoid(
            selector: NSSelectorFromString("layoutSubviews"),
            receiver: view
        )
    }

    /// RRAutoLayout `rr_r_layoutSublayersOfLayer:`: resolve pending constraint updates first, then
    /// let UIKit do its layer layout.
    @objc dynamic func rr_r_layoutSublayersOfLayer(_ layer: CALayer) {
        let view = bridgedView(self)
        view.legacyUpdateConstraintsIfNeeded()
        LegacyAutoLayoutInstaller.callOriginalVoidObject(
            selector: NSSelectorFromString("layoutSublayersOfLayer:"),
            receiver: view,
            argument: layer
        )
    }

    /// RRAutoLayout `rr_r_initWithCoder:`: decode `UIViewAutolayoutConstraints` after the original
    /// initialiser ran, install them through the legacy storage, then return the original result.
    ///
    /// - Note: this is the one hook with `init`-family Objective-C ABI semantics. It only ever runs
    ///   below iOS 6, where it mirrors upstream; Swift cannot actually deploy to iOS 5, so this path
    ///   is a structural port rather than exercised code on modern OSes.
    @objc dynamic func rr_r_initWithCoder(_ decoder: NSCoder) -> AnyObject {
        let initialized = LegacyAutoLayoutInstaller.callOriginalInitWithCoder(
            receiver: self,
            coder: decoder
        )
        if LegacyAutoLayout.isActive {
            let view = bridgedView(initialized)
            // View-level flags (UIViewDoesNotTranslateAutoresizingMaskIntoConstraints /
            // UIAutoresizingMask) plus the owned constraint array.
            view.legacyDecodeAutolayoutArchive(from: decoder)
        }
        return initialized
    }

    /// RRAutoLayout `rr_r_setBounds:`: apply the value, then invalidate constraints.
    @objc dynamic func rr_r_setBounds(_ bounds: CGRect) {
        let view = bridgedView(self)
        LegacyAutoLayoutInstaller.callOriginalVoidRect(
            selector: NSSelectorFromString("setBounds:"),
            receiver: view,
            argument: bounds
        )
        if !LegacyAutoLayoutRuntime.isApplyingLayoutFrames {
            view.legacySetNeedsUpdateConstraints()
        }
    }

    /// RRAutoLayout `rr_r_setCenter:`: apply the value, then invalidate constraints.
    @objc dynamic func rr_r_setCenter(_ center: CGPoint) {
        let view = bridgedView(self)
        LegacyAutoLayoutInstaller.callOriginalVoidPoint(
            selector: NSSelectorFromString("setCenter:"),
            receiver: view,
            argument: center
        )
        if !LegacyAutoLayoutRuntime.isApplyingLayoutFrames {
            view.legacySetNeedsUpdateConstraints()
        }
    }

    /// RRAutoLayout `rr_r_setTransform:`: apply the value, then invalidate constraints.
    @objc dynamic func rr_r_setTransform(_ transform: CGAffineTransform) {
        let view = bridgedView(self)
        LegacyAutoLayoutInstaller.callOriginalVoidTransform(
            selector: NSSelectorFromString("setTransform:"),
            receiver: view,
            argument: transform
        )
        if !LegacyAutoLayoutRuntime.isApplyingLayoutFrames {
            view.legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Methods added to UIView below iOS 6

    /// `-[UIView constraints]` replacement.
    @objc dynamic func rr_a_constraints() -> [RRLayoutConstraint] {
        bridgedView(self).legacyConstraints
    }

    /// `-[UIView addConstraint:]` replacement.
    @objc dynamic func rr_a_addConstraint(_ constraint: RRLayoutConstraint) {
        bridgedView(self).legacyAddConstraint(constraint)
    }

    /// `-[UIView addConstraints:]` replacement.
    @objc dynamic func rr_a_addConstraints(_ constraints: [RRLayoutConstraint]) {
        bridgedView(self).legacyAddConstraints(constraints)
    }

    /// `-[UIView updateConstraints]` replacement: RRAutoLayout's content-size + autoresizing hooks.
    @objc dynamic func rr_a_updateConstraints() {
        bridgedView(self).legacyUpdateConstraints()
    }

    /// `-[UIView updateConstraintsIfNeeded]` replacement: recursive dirty-flag walk.
    @objc dynamic func rr_a_updateConstraintsIfNeeded() {
        bridgedView(self).legacyUpdateConstraintsIfNeeded()
    }

    /// `-[UIView setNeedsUpdateConstraints]` replacement.
    @objc dynamic func rr_a_setNeedsUpdateConstraints() {
        bridgedView(self).legacySetNeedsUpdateConstraints()
    }

    /// `-[UIView setNeedsLayout]` replacement. RRAutoLayout did not replace this method (it is not in
    /// its `+load` list); the hook is kept here for completeness of the bridge's invalidation surface
    /// and is only installed if a caller explicitly asks for it. The default installer leaves UIKit's
    /// `setNeedsLayout` untouched.
    @objc dynamic func rr_a_setNeedsLayout() {
        bridgedView(self).legacySetNeedsLayout()
    }
}

// MARK: - Installer

/// Installs the ObjC bridge, exactly once, and only when `LegacyAutoLayout.isRequired`.
///
/// This type is deliberately `nonisolated`: installation only manipulates the Objective-C runtime
/// (`class_addMethod` / `method_exchangeImplementations`), and letting it be called from the
/// nonisolated constraint-activation path is what makes lazy auto-installation possible. The
/// *swizzled hook bodies* (`LegacyUIViewRuntimeHooks`) remain `@MainActor` because they touch UIKit.
internal enum LegacyAutoLayoutInstaller {

    private static var installed = false
    private static var exchanges: [(original: Selector, replacement: Selector)] = []
    private static var originalImplementations: [Selector: IMP] = [:]
    private static var addedSelectors: [Selector] = []

    internal static var isInstalled: Bool {
        installed
    }

    // MARK: Public (module-internal) entry points

    internal static func install() {
        guard !installed else { return }
        guard LegacyAutoLayout.isRequired else { return }
        // Belt and braces on top of the availability gate: if UIKit already answers the constraint-
        // based-layout questions, the system machinery is authoritative and the backport must not
        // install anything (RRAutoLayout's check, expressed as "does the system have Auto Layout?").
        // There is intentionally no force-install path on iOS 6+.
        guard !systemHasConstraintBasedLayout() else { return }

        // 1. Exchange the lifecycle that drives the legacy pass.
        exchangeIfPresent(
            original: NSSelectorFromString("layoutSubviews"),
            replacement: #selector(LegacyUIViewRuntimeHooks.rr_r_layoutSubviews)
        )
        exchangeIfPresent(
            original: NSSelectorFromString("layoutSublayersOfLayer:"),
            replacement: #selector(LegacyUIViewRuntimeHooks.rr_r_layoutSublayersOfLayer(_:))
        )
        exchangeIfPresent(
            original: NSSelectorFromString("initWithCoder:"),
            replacement: #selector(LegacyUIViewRuntimeHooks.rr_r_initWithCoder(_:))
        )
        exchangeIfPresent(
            original: NSSelectorFromString("setBounds:"),
            replacement: #selector(LegacyUIViewRuntimeHooks.rr_r_setBounds(_:))
        )
        exchangeIfPresent(
            original: NSSelectorFromString("setCenter:"),
            replacement: #selector(LegacyUIViewRuntimeHooks.rr_r_setCenter(_:))
        )
        exchangeIfPresent(
            original: NSSelectorFromString("setTransform:"),
            replacement: #selector(LegacyUIViewRuntimeHooks.rr_r_setTransform(_:))
        )

        // 2. Provide the Auto Layout API surface that iOS 5 does not have.
        addMethodIfAbsent(
            selector: NSSelectorFromString("constraints"),
            implementation: #selector(LegacyUIViewRuntimeHooks.rr_a_constraints)
        )
        addMethodIfAbsent(
            selector: NSSelectorFromString("addConstraint:"),
            implementation: #selector(LegacyUIViewRuntimeHooks.rr_a_addConstraint(_:))
        )
        addMethodIfAbsent(
            selector: NSSelectorFromString("addConstraints:"),
            implementation: #selector(LegacyUIViewRuntimeHooks.rr_a_addConstraints(_:))
        )
        addMethodIfAbsent(
            selector: NSSelectorFromString("updateConstraints"),
            implementation: #selector(LegacyUIViewRuntimeHooks.rr_a_updateConstraints)
        )
        addMethodIfAbsent(
            selector: NSSelectorFromString("updateConstraintsIfNeeded"),
            implementation: #selector(LegacyUIViewRuntimeHooks.rr_a_updateConstraintsIfNeeded)
        )
        addMethodIfAbsent(
            selector: NSSelectorFromString("setNeedsUpdateConstraints"),
            implementation: #selector(LegacyUIViewRuntimeHooks.rr_a_setNeedsUpdateConstraints)
        )

        installed = true
    }

    // MARK: Original IMP forwarding

    internal static func callOriginalVoid(selector: Selector, receiver: AnyObject) {
        guard let implementation = originalImplementations[selector] else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(implementation, to: Function.self)(receiver, selector)
    }

    internal static func callOriginalVoidObject(selector: Selector, receiver: AnyObject, argument: AnyObject) {
        guard let implementation = originalImplementations[selector] else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(implementation, to: Function.self)(receiver, selector, argument)
    }

    internal static func callOriginalVoidRect(selector: Selector, receiver: AnyObject, argument: CGRect) {
        guard let implementation = originalImplementations[selector] else { return }
        typealias Function = @convention(c) (AnyObject, Selector, CGRect) -> Void
        unsafeBitCast(implementation, to: Function.self)(receiver, selector, argument)
    }

    internal static func callOriginalVoidPoint(selector: Selector, receiver: AnyObject, argument: CGPoint) {
        guard let implementation = originalImplementations[selector] else { return }
        typealias Function = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        unsafeBitCast(implementation, to: Function.self)(receiver, selector, argument)
    }

    internal static func callOriginalVoidTransform(selector: Selector, receiver: AnyObject, argument: CGAffineTransform) {
        guard let implementation = originalImplementations[selector] else { return }
        typealias Function = @convention(c) (AnyObject, Selector, CGAffineTransform) -> Void
        unsafeBitCast(implementation, to: Function.self)(receiver, selector, argument)
    }

    internal static func callOriginalInitWithCoder(receiver: AnyObject, coder: NSCoder) -> AnyObject {
        let selector = NSSelectorFromString("initWithCoder:")
        guard let implementation = originalImplementations[selector] else { return receiver }
        typealias Function = @convention(c) (AnyObject, Selector, NSCoder) -> AnyObject
        return unsafeBitCast(implementation, to: Function.self)(receiver, selector, coder)
    }

    // MARK: Uninstall (tests only)

    @discardableResult
    internal static func uninstall() -> Bool {
        guard installed else { return false }
        for pair in exchanges {
            guard let originalMethod = class_getInstanceMethod(UIView.self, pair.original),
                  let replacementMethod = class_getInstanceMethod(LegacyUIViewRuntimeHooks.self, pair.replacement) else {
                continue
            }
            // The second exchange restores both IMPs; the hook class method is throw-away either way.
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
        exchanges.removeAll()
        originalImplementations.removeAll()
        // Methods injected with class_addMethod cannot be removed safely; they are inert unless the
        // bridge is active, and `installed == false` makes every entry point a no-op.
        addedSelectors.removeAll()
        installed = false
        return true
    }

    // MARK: Runtime plumbing

    private static func systemHasConstraintBasedLayout() -> Bool {
        let requiresSelector = NSSelectorFromString("requiresConstraintBasedLayout")
        let constraintsSelector = NSSelectorFromString("constraints")
        if class_getClassMethod(UIView.self, requiresSelector) != nil {
            return true
        }
        if class_getInstanceMethod(UIView.self, constraintsSelector) != nil {
            return true
        }
        return false
    }

    private static func exchangeIfPresent(original: Selector, replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIView.self, original),
              let replacementMethod = class_getInstanceMethod(LegacyUIViewRuntimeHooks.self, replacement) else {
            return
        }
        originalImplementations[original] = method_getImplementation(originalMethod)
        method_exchangeImplementations(originalMethod, replacementMethod)
        exchanges.append((original: original, replacement: replacement))
    }

    private static func addMethodIfAbsent(selector: Selector, implementation: Selector) {
        guard class_getInstanceMethod(UIView.self, selector) == nil,
              let hookMethod = class_getInstanceMethod(LegacyUIViewRuntimeHooks.self, implementation) else {
            return
        }
        let typeEncoding = method_getTypeEncoding(hookMethod)
        if class_addMethod(UIView.self, selector, method_getImplementation(hookMethod), typeEncoding) {
            addedSelectors.append(selector)
        }
    }
}
