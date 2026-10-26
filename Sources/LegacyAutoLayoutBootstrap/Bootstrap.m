#import <Foundation/Foundation.h>
#import <objc/runtime.h>
extern void LSDKInstallAutoLayoutIfNeeded(void);
@interface LSDKAutoLayoutBootstrap : NSObject @end
@implementation LSDKAutoLayoutBootstrap
+ (void)load {
    if (objc_getClass("NSLayoutConstraint") == Nil) LSDKInstallAutoLayoutIfNeeded();
}
@end
void LSDKAutoLayoutBootstrapLink(void) {}
