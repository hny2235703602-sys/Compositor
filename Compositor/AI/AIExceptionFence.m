#import "AIExceptionFence.h"

NSString *AICatchException(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        if (exception.reason.length > 0) return exception.reason;
        return exception.name;
    }
}
