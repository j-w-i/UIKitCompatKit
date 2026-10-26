#import <Foundation/Foundation.h>
#import <objc/runtime.h>

extern void LSDKInstallAutoLayoutIfNeeded(void);

// Retained evidence that this object was linked (checked by the build tests).
const char *LSDKBootstrapMarker = "LSDK-AUTOLAYOUT-BOOTSTRAP";

// Class metadata can be dead-stripped in Release builds; an image initializer
// cannot. Run before main so the missing iOS 5 class and UIView methods exist
// before any Swift or UIKit code can touch them. On iOS 6+ the callee returns
// immediately because UIKit already provides Auto Layout.
__attribute__((constructor)) static void LSDKAutoLayoutBootstrapInit(void) {
    if (objc_getClass("NSLayoutConstraint") == Nil) {
        LSDKInstallAutoLayoutIfNeeded();
    }
}

void LSDKAutoLayoutBootstrapLink(void) {}
