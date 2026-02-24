#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const FlutterAria2NativeErrorDomain;

typedef void (^FlutterAria2DownloadEventHandler)(NSInteger event, NSString* gid);

@interface FlutterAria2Native : NSObject

@property(nonatomic, copy, nullable) FlutterAria2DownloadEventHandler onDownloadEvent;

- (void)invokeMethod:(NSString*)method
           arguments:(NSDictionary<NSString*, id>* _Nullable)arguments
          completion:(void (^)(id _Nullable value, NSError* _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
