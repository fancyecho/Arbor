#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an NSError instead of letting it unwind.
///
/// Swift can't catch NSException. One thrown inside Swift code (above all inside an async task) unwinds
/// straight through Swift's bookkeeping; AppKit then swallows it, and the main thread is left believing
/// it is running a task that no longer exists — which crashes later, somewhere unrelated.
BOOL ArborCatchException(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
