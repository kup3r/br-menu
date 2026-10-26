#import <Foundation/Foundation.h>
#import <objc/message.h>

// No UIKit work is performed synchronously inside dyld's initialization path.
__attribute__((constructor))
static void BRMenuLoad(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class entry = NSClassFromString(@"BRMenuEntry");
        SEL selector = NSSelectorFromString(@"start");
        if (entry && [entry respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)((id)entry, selector);
        } else {
            NSLog(@"[BRMenu] entry class unavailable");
        }
    });
}
