#import <Foundation/Foundation.h>

/// Runs `block` and, if AppKit raises, returns the exception's reason instead of letting it out.
/// A fatal error or a segfault still ends the process; those paths stay in the helper process.
NSString * _Nullable AICatchException(NS_NOESCAPE void (^ _Nonnull block)(void));
