#import "ArborObjC.h"

BOOL ArborCatchException(NS_NOESCAPE void (^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"ExceptionName"] = exception.name;
            *error = [NSError errorWithDomain:@"ArborObjCException" code:1 userInfo:info];
        }
        return NO;
    }
}
