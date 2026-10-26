// Same-name iOS 5 Auto Layout support.
//
// This file intentionally declares no public API. UIKit's own declarations are
// used at every deployment target; the legacy importer makes the iOS 6
// constraint API visible for iOS 5 builds, and the runtime supplies the
// missing Objective-C class and UIView methods only when UIKit does not
// provide them (see NativeAPIBridge.swift and LegacyAutoLayoutSwizzling.swift).
//
// iOS 6+ compilation and behavior are unchanged: nothing here is compiled into
// a fallback, no UIKit declarations are shadowed, and the installer refuses to
// run whenever UIKit already provides Auto Layout.
